"""inbox | backfill | sync | status | categorize | review | reparse | retention.

Reference: docs/CLI.md. Design rationale: docs/EXPENSE_TRACKER_PLAN.md
section 6.1.

`sync` is the unattended run and resolves its own window from the watermark
(section 6.2). `inbox` and `backfill` exist because that default is wrong for
every interactive case -- a first backfill, a re-pull after fixing a parser, a
laptop that has been off for months -- and because "how much mail is there?"
deserves an answer that doesn't cost a full download to get.
"""

from __future__ import annotations

import contextlib
import email
import email.policy
import email.utils
import fcntl
import logging
import re
import sys
import time
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Optional

import typer

from expense_tracker.config import load_config
from expense_tracker.ingest import archive
from expense_tracker.ingest.esewa_statement_file import (
    read_statement_rows,
    whole_file_raw_message_fields,
)
from expense_tracker.ingest.imap import ImapSource
from expense_tracker.ingest.source import NetworkUnavailable
from expense_tracker.ingest.window import PRESETS, InvalidWindow, describe, parse_window
from expense_tracker.parsers.registry import route
from expense_tracker.pipeline.categorize import categorize_and_record, recategorize_all
from expense_tracker.pipeline.retention import RETENTION_DAYS, run_retention
from expense_tracker.pipeline.sync import SyncResult, run_sync, upsert_by_account
from expense_tracker.store.base import StoreUnavailable
from expense_tracker.store.supabase import PostgresStore

app = typer.Typer()

logger = logging.getLogger("expense_tracker")

# Both legs of a run can be transiently unreachable, and section 6.4 treats
# that as routine rather than as a failure. The two are handled identically
# everywhere below, so keep them as one tuple.
UNAVAILABLE = (NetworkUnavailable, StoreUnavailable)

# launchd fires a missed StartCalendarInterval job the moment the machine
# wakes, which is reliably before wifi has associated and DNS answers. One
# attempt at that instant fails every time and forfeits the whole day, so
# wait the network out briefly before taking the quiet-skip path.
STARTUP_ATTEMPTS = 3
STARTUP_BACKOFF_SECONDS = 30


@app.callback()
def _configure(verbose: bool = typer.Option(False, "--verbose", help="Log debug detail")) -> None:
    """Timestamp every log line.

    These commands run unattended under launchd/systemd with stdout and
    stderr redirected to a file that is never rotated and never truncated,
    so the log is append-only and undated. Without a timestamp on each line
    there is no way to tell from the log whether a given day's run happened
    at all -- the file's mtime is the only clue, and it answers for the last
    run only.
    """
    logging.basicConfig(
        level=logging.DEBUG if verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S%z",
        stream=sys.stderr,
    )


@contextlib.contextmanager
def _lock(home: Path):
    """Refuse to run twice concurrently. Section 6.1 step 1."""
    home.mkdir(parents=True, exist_ok=True)
    lock_path = home / "sync.lock"
    with lock_path.open("w") as f:
        try:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            typer.echo("another sync is already running", err=True)
            raise typer.Exit(code=1) from None
        try:
            yield
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)


@app.command()
def sync(
    since: Optional[str] = typer.Option(
        None, help="ISO date to backfill from, overriding the resolved watermark"
    ),
    last: Optional[str] = typer.Option(
        None,
        "--last",
        help="How far back to fetch, as a duration: 7d, 2w, 3m, 1y, or 'all'. "
        "Same thing as --since, said the short way.",
    ),
    max_emails: Optional[int] = typer.Option(
        None,
        "--max-emails",
        help="Stop after downloading this many emails (newest first). "
        "Use it to take a long backfill in bites.",
    ),
    use_ollama: bool = typer.Option(
        True, "--use-ollama/--no-ollama", help="Fall back to a local Ollama model for rows no rule matches"
    ),
) -> None:
    """Fetch, parse, categorize, and push. The unattended daily run.

    With no window flags it resolves its own start date from the last
    successful run (section 6.2) -- that's the scheduled behaviour and it
    should stay the default. --since/--last override it for a one-off
    backfill; `backfill` is the interactive way to pick the same window.
    """
    from expense_tracker.config import DEFAULT_HOME

    config = load_config()
    if since and last:
        typer.echo("--since and --last both set a window; pick one", err=True)
        raise typer.Exit(code=1)
    if max_emails is not None and max_emails < 1:
        typer.echo("--max-emails must be at least 1", err=True)
        raise typer.Exit(code=1)

    if last:
        since_override = _resolve_window(last, config.account_start)
    elif since:
        since_override = datetime.combine(
            date.fromisoformat(since), datetime.min.time(), tzinfo=timezone.utc
        )
    else:
        since_override = None

    with _lock(DEFAULT_HOME):
        result = _sync_once_network_permitting(
            config, since_override, use_ollama, max_emails=max_emails
        )

    if result is None:
        # Section 6.4: unreachable IMAP or DB isn't a failure worth alerting
        # on -- the next scheduled run picks up the gap. Any other
        # unhandled exception still propagates and exits non-zero.
        raise typer.Exit(code=0)

    typer.echo(
        f"at={datetime.now(timezone.utc).isoformat()} "
        f"since={result.since.isoformat()} fetched={result.fetched} "
        f"parsed={result.parsed} failed={result.failed} ignored={result.ignored} "
        f"txns_inserted={result.txns_inserted} transfers_matched={result.transfers_matched} "
        f"new_ledger_gaps={result.new_ledger_gaps} resolved_ledger_gaps={result.resolved_ledger_gaps} "
        f"categorized_by_rule={result.categorized_by_rule} "
        f"categorized_by_llm={result.categorized_by_llm} still_review={result.still_review}"
    )
    if result.truncated_by_cap:
        typer.echo(
            f"note: stopped at the --max-emails cap of {max_emails}, so this window "
            f"still has older mail in it. Re-run with --since {result.since:%Y-%m-%d} "
            f"to continue -- a plain `sync` will not, because the watermark has moved on."
        )


def _sync_once_network_permitting(
    config,
    since_override: datetime | None,
    use_ollama: bool,
    max_emails: int | None = None,
) -> Optional[SyncResult]:
    """Run the sync, retrying while the network is still coming up.

    Returns None if every attempt found IMAP or the database unreachable --
    the quiet-skip case. Retrying the whole run is safe because the pipeline
    is idempotent by DB constraint (invariant 5), and because an
    unavailability is raised before any message is processed.
    """
    for attempt in range(1, STARTUP_ATTEMPTS + 1):
        logger.info("sync attempt %d/%d starting", attempt, STARTUP_ATTEMPTS)
        store = None
        try:
            store = PostgresStore(config.db_url)
            result = run_sync(
                store=store,
                mail_source=ImapSource(config.imap_host, config.imap_username, config.imap_password),
                archive_dir=config.archive_dir,
                user_id=config.user_id,
                machine=config.machine,
                senders=[config.esewa_sender, config.nabil_sender],
                account_start=config.account_start,
                since_override=since_override,
                max_emails=max_emails,
                use_ollama=use_ollama,
            )
        except UNAVAILABLE as exc:
            if attempt == STARTUP_ATTEMPTS:
                logger.warning("unreachable after %d attempts, skipping this run: %s",
                               STARTUP_ATTEMPTS, exc)
                return None
            logger.warning("unreachable (%s), retrying in %ds", exc, STARTUP_BACKOFF_SECONDS)
            time.sleep(STARTUP_BACKOFF_SECONDS)
        except Exception:
            logger.exception("sync failed")
            raise
        else:
            logger.info(
                "sync finished: fetched=%d parsed=%d failed=%d txns_inserted=%d",
                result.fetched, result.parsed, result.failed, result.txns_inserted,
            )
            return result
        finally:
            if store is not None:
                store.close()
    return None


def _open_store(config) -> PostgresStore:
    """Connect for the interactive commands.

    `sync` runs unattended and treats an unreachable database as routine
    (section 6.4), but these are typed at a prompt: a one-line "database
    unreachable" and a non-zero exit is what the user wants, not a
    forty-line psycopg traceback, and not the silent exit 0 `sync` takes.
    """
    try:
        return PostgresStore(config.db_url)
    except StoreUnavailable as exc:
        typer.echo(f"database unreachable: {exc}", err=True)
        raise typer.Exit(code=1) from None



def _resolve_window(spec: str, account_start: datetime) -> datetime:
    """parse_window, with the error turned into a clean non-zero exit.

    InvalidWindow's message is already written for a human, so it is passed
    through verbatim rather than wrapped in a traceback.
    """
    try:
        return parse_window(spec, account_start=account_start)
    except InvalidWindow as exc:
        typer.echo(str(exc), err=True)
        raise typer.Exit(code=1) from None


def _count_mail(config, since: datetime):
    """Ask IMAP how big a window is. Returns None if it can't be reached."""
    source = ImapSource(config.imap_host, config.imap_username, config.imap_password)
    senders = [config.esewa_sender, config.nabil_sender]
    try:
        return source.count_since(since, senders)
    except NetworkUnavailable as exc:
        typer.echo(f"mail server unreachable: {exc}", err=True)
        return None


@app.command()
def inbox(
    last: str = typer.Option(
        "30d",
        "--last",
        help="Window to measure: a duration (7d, 2w, 3m, 1y), an ISO date, or 'all'",
    ),
) -> None:
    """How much mail is waiting, without downloading any of it.

    Answers "how much data would a backfill actually pull?" before you commit
    to pulling it. This is a SEARCH, not a fetch: it costs one round trip per
    sender no matter how wide the window, touches no bodies, writes nothing,
    and needs no database. Run it before `backfill` when you have no idea
    whether a year of mail means 40 messages or 4,000.
    """
    config = load_config()
    since = _resolve_window(last, config.account_start)

    counts = _count_mail(config, since)
    if counts is None:
        raise typer.Exit(code=1)

    typer.echo(f"window: since {describe(since)}")
    for sender, count in counts.by_sender.items():
        typer.echo(f"  {sender:<24} {count:>6} message(s)")
    typer.echo(f"  {'total':<24} {counts.total:>6} message(s)")
    if counts.total == 0:
        typer.echo(
            "\nNothing in that window. Widen it (--last 1y), or check that "
            "[senders] in config.toml matches who your bank actually mails from."
        )
    else:
        typer.echo(
            f"\nTo ingest these: expense-tracker backfill --last {last}"
            f"\n(already-seen messages are deduped, so overlapping runs are free)"
        )


@app.command()
def backfill(
    last: Optional[str] = typer.Option(
        None,
        "--last",
        help="Skip the menu and use this window directly: 7d, 2w, 3m, 1y, an ISO date, or 'all'",
    ),
    max_emails: Optional[int] = typer.Option(
        None, "--max-emails", help="Cap how many emails this run downloads (newest first)"
    ),
    yes: bool = typer.Option(
        False, "--yes", "-y", help="Don't ask for confirmation before fetching"
    ),
    use_ollama: bool = typer.Option(
        True, "--use-ollama/--no-ollama", help="Fall back to a local Ollama model for rows no rule matches"
    ),
) -> None:
    """Pick how far back to pull email from, then run a sync over that window.

    `sync` decides its own window from the last successful run, which is what
    you want every day and never what you want on day one -- or after finding
    a parser bug, or after six months on a different laptop. This asks
    instead, shows you what the answer costs in messages before fetching any,
    and only then runs.

    Everything it does is idempotent (invariant 5): choosing too wide a
    window re-fetches mail you already have and inserts nothing new, so when
    in doubt, choose the wider one.
    """
    from expense_tracker.config import DEFAULT_HOME

    config = load_config()
    spec = last or _prompt_for_window()
    since = _resolve_window(spec, config.account_start)

    typer.echo(f"\nWindow: since {describe(since)}")
    counts = _count_mail(config, since)
    if counts is None:
        raise typer.Exit(code=1)

    for sender, count in counts.by_sender.items():
        typer.echo(f"  {sender:<24} {count:>6} message(s)")
    typer.echo(f"  {'total':<24} {counts.total:>6} message(s)")

    if counts.total == 0:
        typer.echo("\nNothing to fetch in that window.")
        raise typer.Exit(code=0)

    planned = counts.total if max_emails is None else min(counts.total, max_emails)
    if planned < counts.total:
        typer.echo(f"\nCapped at {planned} (newest first) by --max-emails.")

    if not yes:
        typer.echo("")
        if not typer.confirm(f"Download and parse {planned} message(s)?", default=True):
            typer.echo("nothing fetched")
            raise typer.Exit(code=0)

    typer.echo("")
    with _lock(DEFAULT_HOME):
        result = _sync_once_network_permitting(
            config, since, use_ollama, max_emails=max_emails
        )

    if result is None:
        typer.echo("mail server or database went away mid-run -- nothing was left half-done "
                   "(every step is idempotent); just run this again.", err=True)
        raise typer.Exit(code=1)

    typer.echo(
        f"fetched={result.fetched} parsed={result.parsed} failed={result.failed} "
        f"ignored={result.ignored} txns_inserted={result.txns_inserted} "
        f"still_review={result.still_review}"
    )
    if result.failed:
        typer.echo(
            f"{result.failed} message(s) didn't parse and are recorded as FAILED "
            f"(invariant 6 -- nothing is silently dropped). See `expense-tracker status`."
        )
    if result.truncated_by_cap:
        typer.echo(
            f"Stopped at the cap, so older mail in this window is still unfetched. "
            f"Run `expense-tracker backfill --last {spec} --max-emails {max_emails}` "
            f"again to take the next bite."
        )
    if result.still_review:
        typer.echo(f"{result.still_review} transaction(s) need a category: expense-tracker review")


def _prompt_for_window() -> str:
    """The menu. Returns a window spec for parse_window, not a datetime."""
    typer.echo("How far back should I fetch email from?\n")
    for preset in PRESETS:
        typer.echo(f"  {preset.key}) {preset.label}")
    typer.echo("  c) Custom -- a duration (e.g. 45d, 8w) or an ISO date (2026-01-01)")

    while True:
        choice = typer.prompt("\nChoice", default="2").strip().lower()
        for preset in PRESETS:
            if choice == preset.key:
                return preset.spec
        if choice == "c":
            return typer.prompt("Duration or ISO date")
        # Typing "3m" straight past the menu is a reasonable thing to do.
        try:
            parse_window(choice, account_start=datetime.now(timezone.utc))
        except InvalidWindow:
            typer.echo("  not one of the options -- pick a number, or 'c' for custom")
        else:
            return choice


@app.command()
def status() -> None:
    """Last run (whatever its outcome), unparsed-email count, and open
    ledger gaps. Section 6.1.
    """
    config = load_config()
    store = _open_store(config)
    try:
        last_run = store.fetch_last_sync_run(config.user_id)
        failed_emails = store.count_failed_emails(config.user_id)
        open_gaps = store.count_open_ledger_gaps(config.user_id)
    finally:
        store.close()

    if last_run is None:
        typer.echo("last sync: never")
    else:
        ok = last_run.completed_at is not None and last_run.error is None
        when = last_run.completed_at or last_run.started_at
        typer.echo(
            f"last sync ({last_run.machine}, {'OK' if ok else 'FAILED'}): {when.isoformat()} "
            f"fetched={last_run.fetched} parsed={last_run.parsed} "
            f"failed={last_run.failed} inserted={last_run.txns_inserted}"
        )
        if last_run.error:
            typer.echo(f"    error: {last_run.error}")

    typer.echo(f"unparsed emails (FAILED): {failed_emails}")
    typer.echo(f"open ledger gaps: {open_gaps}")


@app.command()
def categorize(
    use_ollama: bool = typer.Option(
        True, "--use-ollama/--no-ollama", help="Fall back to a local Ollama model for rows no rule matches"
    ),
    limit: int = typer.Option(500, help="Max NEEDS_REVIEW transactions to process"),
    all_transactions: bool = typer.Option(
        False, "--all", help="Re-run the model over every transaction, not just NEEDS_REVIEW"
    ),
) -> None:
    """Run categorization over existing NEEDS_REVIEW rows, without a sync.
    Same rules-then-Ollama pipeline sync uses (section 10), just runnable on
    its own against whatever's already in the DB.

    --all is for after the category list changes: the model re-files every
    transaction, keeping categories you picked yourself (see
    pipeline/categorize.py's recategorize_all).
    """
    config = load_config()
    if all_transactions and not use_ollama:
        typer.echo("--all re-runs the model, so it can't be combined with --no-ollama", err=True)
        raise typer.Exit(code=1)
    store = _open_store(config)
    try:
        if all_transactions:
            counts = recategorize_all(store, config.user_id)
        else:
            counts = categorize_and_record(store, config.user_id, use_ollama=use_ollama, limit=limit)
    finally:
        store.close()
    typer.echo(" ".join(f"{key}={value}" for key, value in counts.items()))


@app.command()
def retention() -> None:
    """Delete raw .eml files older than section 11.3's retention window
    whose transactions are all CONFIRMED. Safe to run any time -- it never
    touches the database, only the local raw/ cache.
    """
    config = load_config()
    store = _open_store(config)
    try:
        deleted = run_retention(store, config.user_id, config.archive_dir)
    finally:
        store.close()
    typer.echo(f"deleted {deleted} raw file(s) older than {RETENTION_DAYS} days, all-CONFIRMED")


@app.command()
def reparse(
    template: Optional[str] = typer.Option(
        None, help="Only reparse fixtures/messages whose template_key matches this"
    ),
) -> None:
    """Re-run current parsers over the local raw/ archive. Entirely offline
    except for the DB upserts -- no IMAP fetch. Section 6.1.
    """
    config = load_config()
    store = _open_store(config)
    reparsed = 0
    inserted = 0
    try:
        for path in archive.iter_archived(config.archive_dir):
            raw_bytes = path.read_bytes()
            message = email.message_from_bytes(raw_bytes, policy=email.policy.default)
            parser = route(message)
            if parser is None or (template and parser.template_key != template):
                continue

            message_id = str(message["Message-ID"])
            received_at = email.utils.parsedate_to_datetime(str(message["Date"]))
            txns = parser.parse(message)
            store.upsert_processed_email(
                config.user_id, message_id, received_at,
                str(message.get("From", "")), parser.template_key,
                parser.parser_version, "PARSED", None, len(txns),
            )
            inserted += upsert_by_account(store, config.user_id, message_id, txns)
            reparsed += 1
    finally:
        store.close()

    typer.echo(f"reparsed={reparsed} txns_inserted={inserted}")


@app.command(name="import-esewa-statement")
def import_esewa_statement(
    path: Path = typer.Argument(..., help="Downloaded .xls from eSewa: Profile -> Statement"),
) -> None:
    """Stage an eSewa statement export as one raw_messages row, for the next
    `sync` to parse.

    eSewa sends no email or SMS for a wallet-to-wallet transfer -- only
    fund_load and payment_success get emailed (parsers/esewa.py). This is
    the only way that transaction type enters the ledger at all: download
    Profile -> Statement -> Excel in the app, run this against the file, then
    run `sync` (or wait for the next scheduled one) to actually parse and
    insert transactions.

    The phone can stage the same file too (Bank SMS screen -> Import eSewa
    statement) without this command ever running -- this is the manual/local
    equivalent, useful for a backlog of old exports or when IMAP is down and
    `sync` hasn't been the thing pulling raw_messages in the first place.
    Entirely offline except the DB write, like `reparse` -- no IMAP involved.

    Safe to re-run, including over an overlapping export: this file's
    content_hash won't match a previous run's (eSewa stamps each export with
    its own generation time), so it stages again and every row re-parses --
    but every row's insert still collides with dedupe_key at the transactions
    table, so nothing is duplicated there.
    """
    config = load_config()
    file_bytes = path.read_bytes()
    row_count = len(read_statement_rows(path))

    store = _open_store(config)
    try:
        fields = whole_file_raw_message_fields(file_bytes)
        was_new = store.insert_raw_message(
            config.user_id,
            channel="ESEWA_STATEMENT",
            sender=fields["sender"],
            body=fields["body"],
            received_at=fields["received_at"],
            content_hash=fields["content_hash"],
        )
    finally:
        store.close()

    typer.echo(
        f"rows_found={row_count} staged={'yes' if was_new else 'already staged'} "
        f"-- run `sync` to parse the staged file into transactions"
    )


@app.command()
def review(
    limit: int = typer.Option(20, help="Max NEEDS_REVIEW transactions to show"),
) -> None:
    """Terminal review queue for the NEEDS_REVIEW pile. Section 6.1.
    Assigning a category writes a merchant_rules row (learned_from_user=True)
    -- next sync, the rule fires locally and the model isn't consulted.
    """
    config = load_config()
    store = _open_store(config)
    try:
        categories = store.fetch_categories(config.user_id)
        if not categories:
            typer.echo("no categories found -- run supabase/seed.sql first")
            return
        names = sorted(categories)

        candidates = store.fetch_needs_review_transactions(config.user_id, limit=limit)
        if not candidates:
            typer.echo("nothing to review")
            return

        for i, txn in enumerate(candidates, start=1):
            label = txn.counterparty or txn.description_raw
            typer.echo(f"\n[{i}/{len(candidates)}] NPR {txn.amount_paisa / 100:,.2f}  {label}")
            typer.echo(f"    {txn.description_raw}")
            for idx, name in enumerate(names, start=1):
                typer.echo(f"    {idx}) {name}")

            choice = typer.prompt(
                "category number (Enter to skip, 's' to stop)", default="", show_default=False
            )
            if choice.lower() == "s":
                break
            if not choice:
                continue
            try:
                category_name = names[int(choice) - 1]
            except (ValueError, IndexError):
                typer.echo("  not a valid choice, skipping")
                continue

            category_id = categories[category_name]
            store.apply_category(txn.id, category_id, "user", 1.0)
            pattern = re.escape(label[:40])
            store.create_merchant_rule(config.user_id, pattern, category_id, learned_from_user=True)
            typer.echo(f"  -> {category_name} (rule learned)")
    finally:
        store.close()


if __name__ == "__main__":
    app()
