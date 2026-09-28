"""The daily sync run. See docs/EXPENSE_TRACKER_PLAN.md section 6.1.

One deliberate deviation from the plan's pseudocode: "skip if raw/<hash>.eml
already exists" (step 4) only skips the local *write*, never the
route/parse/upsert that follows. Read literally, gating the whole per-message
pipeline on that existence check would mean a crash between archiving a
message and upserting it loses that message forever -- the next run would
see the file on disk and skip it again, and it would never reach the DB.
Routing, parsing, and upserting every fetched message every run is what
invariant 5 (idempotent by DB constraint, not by application logic) actually
requires; the existence check is purely a redundant-download optimization.
"""

from __future__ import annotations

import email
import email.policy
import logging
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from expense_tracker.ingest import archive
from expense_tracker.ingest.source import MailSource
from expense_tracker.ingest.watermark import resolve_watermark
from expense_tracker.parsers.registry import route
from expense_tracker.parsers.sms import route_sms
from expense_tracker.pipeline.categorize import categorize_and_record
from expense_tracker.pipeline.reconcile import reconcile_and_record_gaps
from expense_tracker.pipeline.transfers import match_and_link_transfers
from expense_tracker.store.base import Store

logger = logging.getLogger(__name__)

ACCOUNT_KIND = {"NABIL": "BANK", "ESEWA": "WALLET", "LAXMI": "BANK"}
TRANSFER_WINDOW_DAYS = 60


@dataclass
class SyncResult:
    since: datetime
    fetched: int = 0
    parsed: int = 0
    failed: int = 0
    ignored: int = 0
    txns_inserted: int = 0
    # SMS legs are counted separately from the email ones: sync_runs.fetched
    # /parsed/failed have always meant "emails", and quietly folding a second
    # transport into them would make every historical row mean something
    # different. txns_inserted is genuinely shared -- a transaction is a
    # transaction whichever transport carried it.
    sms_pending: int = 0
    sms_parsed: int = 0
    sms_failed: int = 0
    sms_ignored: int = 0
    # Set when --max-emails cut the fetch short. The caller needs to know
    # the window wasn't fully drained, because the watermark still advances
    # to now on a successful run -- so "run it again" is not, by itself,
    # enough to pick up the remainder. See cli.py's backfill.
    truncated_by_cap: bool = False
    transfers_matched: int = 0
    new_ledger_gaps: int = 0
    resolved_ledger_gaps: int = 0
    categorized_by_rule: int = 0
    categorized_by_llm: int = 0
    still_review: int = 0


def run_sync(
    *,
    store: Store,
    mail_source: MailSource,
    archive_dir: Path,
    user_id: str,
    machine: str,
    senders: list[str],
    account_start: datetime,
    since_override: datetime | None = None,
    max_emails: int | None = None,
    use_ollama: bool = False,
) -> SyncResult:
    started_at = datetime.now(timezone.utc)
    since = since_override or resolve_watermark(
        store.last_completed_sync_at(user_id), account_start
    )
    run_id = store.start_sync_run(user_id, machine, started_at, since)
    result = SyncResult(since=since)
    error: str | None = None

    try:
        messages = mail_source.fetch_since(since, senders, limit=max_emails)
        result.fetched = len(messages)
        result.truncated_by_cap = max_emails is not None and len(messages) >= max_emails

        for msg in messages:
            if not archive.exists(archive_dir, msg.message_id, msg.received_at):
                archive.write(archive_dir, msg.message_id, msg.received_at, msg.raw_bytes)

            email_message = email.message_from_bytes(msg.raw_bytes, policy=email.policy.default)
            parser = route(email_message)

            if parser is None:
                store.upsert_processed_email(
                    user_id, msg.message_id, msg.received_at, msg.from_addr,
                    None, None, "IGNORED", None, 0,
                )
                result.ignored += 1
                continue

            try:
                txns = parser.parse(email_message)
            except Exception as exc:  # noqa: BLE001 -- record it, never crash the run
                store.upsert_processed_email(
                    user_id, msg.message_id, msg.received_at, msg.from_addr,
                    parser.template_key, parser.parser_version, "FAILED", str(exc), 0,
                )
                result.failed += 1
                continue

            store.upsert_processed_email(
                user_id, msg.message_id, msg.received_at, msg.from_addr,
                parser.template_key, parser.parser_version, "PARSED", None, len(txns),
            )
            result.parsed += 1
            result.txns_inserted += upsert_by_account(
                store, user_id, txns, message_id=msg.message_id
            )

        _ingest_sms(store, user_id, result)

        result.transfers_matched = match_and_link_transfers(
            store, user_id, window_days=TRANSFER_WINDOW_DAYS
        )
        reconciled = reconcile_and_record_gaps(store, user_id)
        result.new_ledger_gaps = reconciled.new_gaps
        result.resolved_ledger_gaps = reconciled.resolved_gaps

        category_counts = categorize_and_record(store, user_id, use_ollama=use_ollama)
        result.categorized_by_rule = category_counts["categorized_by_rule"]
        result.categorized_by_llm = category_counts["categorized_by_llm"]
        result.still_review = category_counts["still_review"]

    except Exception as exc:  # noqa: BLE001 -- section 6.4: a failed sync isn't a crash
        error = str(exc)
        raise
    finally:
        _record_finish(store, run_id, result, error)

    return result


def _record_finish(
    store: Store, run_id: str, result: SyncResult, error: str | None
) -> None:
    """Close out the sync_runs row, and never let doing so become the
    failure the caller sees.

    This runs in run_sync's `finally`, so it runs precisely when the run has
    already blown up -- and the most common reason a run blows up is that
    the network went away, which means this bookkeeping write is the next
    thing to hit the dead connection. An exception raised here replaces the
    real cause with a traceback pointing at the bookkeeping, which is how a
    mid-fetch IMAP disconnect got logged as an opaque psycopg
    OperationalError. The row is worth trying for, never worth masking with.
    """
    try:
        store.finish_sync_run(
            run_id,
            datetime.now(timezone.utc),
            result.fetched,
            result.parsed,
            result.failed,
            result.txns_inserted,
            error,
        )
    except Exception:  # noqa: BLE001 -- see docstring
        logger.warning(
            "could not close out sync_runs row %s (run outcome: %s)",
            run_id,
            error or "ok",
            exc_info=True,
        )


def upsert_by_account(
    store: Store,
    user_id: str,
    txns: list,
    *,
    message_id: str | None = None,
    raw_message_id: str | None = None,
) -> int:
    by_account: dict[tuple[str, str], list] = {}
    for txn in txns:
        by_account.setdefault((txn.institution, txn.account_mask or ""), []).append(txn)

    inserted = 0
    for (institution, mask), account_txns in by_account.items():
        account_id = store.get_or_create_account(
            user_id, institution, mask or None,
            ACCOUNT_KIND[institution], account_txns[0].currency,
        )
        inserted += store.upsert_transactions(
            user_id, account_id, account_txns,
            source_message_id=message_id,
            source_raw_message_id=raw_message_id,
        )
    return inserted


def _ingest_sms(store: Store, user_id: str, result: SyncResult) -> None:
    """Parse whatever the phone has uploaded to raw_messages since the last run.

    Deliberately not gated on the watermark. The watermark answers "how far
    back must I ask Gmail?", which is a question about an expensive remote
    fetch; raw_messages is already local to the DB and carries its own
    status column, so `status = 'PENDING'` is the whole cursor. That also
    means a message the phone backfills from six months ago gets picked up on
    the next run rather than being skipped for arriving late -- which is the
    entire point of making the SMS inbox re-scannable.
    """
    pending = store.fetch_pending_raw_messages(user_id)
    result.sms_pending = len(pending)

    for sms in pending:
        parser = route_sms(sms)

        if parser is None:
            store.mark_raw_message(
                sms.id, "IGNORED", None, None,
                "no SMS parser matched this sender/body", 0,
            )
            result.sms_ignored += 1
            continue

        try:
            txns = parser.parse(sms)
        except Exception as exc:  # noqa: BLE001 -- record it, never crash the run
            store.mark_raw_message(
                sms.id, "FAILED", parser.template_key, parser.parser_version, str(exc), 0,
            )
            result.sms_failed += 1
            continue

        store.mark_raw_message(
            sms.id, "PARSED", parser.template_key, parser.parser_version, None, len(txns),
        )
        result.sms_parsed += 1
        
        if parser.template_key in ("nabil.statement_row", "bank.statement_row"):
            from expense_tracker.pipeline.statement_audit import audit_and_insert_missing
            result.txns_inserted += audit_and_insert_missing(store, user_id, txns, sms.id)
        else:
            result.txns_inserted += upsert_by_account(
                store, user_id, txns, raw_message_id=sms.id
            )
