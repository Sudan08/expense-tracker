"""Phase 2 DoD: run sync twice against a real Postgres and the second run
inserts zero rows. Kill it mid-run (simulated) and restart -- still zero
duplicates. Requires a local Postgres; skipped if EXPENSE_TRACKER_TEST_DB_URL
isn't set. conftest.py applies the real migration automatically the first
time it sees a fresh database, so no manual setup step is needed beyond:

    docker run -d --name expense-tracker-pg-test -e POSTGRES_PASSWORD=postgres \
        -p 55432:5432 postgres:16
    EXPENSE_TRACKER_TEST_DB_URL=postgresql://postgres:postgres@localhost:55432/postgres \
        pytest tests/test_sync_integration.py -v
"""

from __future__ import annotations

import email
import email.policy
import os
import uuid
from datetime import datetime, timezone
from pathlib import Path

import psycopg
import pytest

from expense_tracker.ingest.source import MailSource, RawMessage
from expense_tracker.pipeline.sync import run_sync
from expense_tracker.store.supabase import PostgresStore

DB_URL = os.environ.get("EXPENSE_TRACKER_TEST_DB_URL")
pytestmark = pytest.mark.skipif(not DB_URL, reason="EXPENSE_TRACKER_TEST_DB_URL not set")

FIXTURES_DIR = Path(__file__).parent / "fixtures" / "emails"
SEED_SQL = (Path(__file__).parent.parent.parent / "supabase" / "seed.sql").read_text()
SENDERS = ["esewa.com.np", "nabilbank.com"]

# Derived, not hard-coded. This was literally `30` in eight assertions while the
# corpus held 31 files -- and because every test in this module is skipped
# without a database, nothing noticed. Counting the directory means adding a
# fixture can't silently break a test nobody runs locally.
FIXTURE_COUNT = len(sorted(FIXTURES_DIR.glob("*/*.eml")))


class FakeMailSource:
    """Every fixture .eml, every call -- imitates fetching the same overlap
    window on every sync, the way the real 3-day-overlap watermark does.
    """

    def __init__(self, paths: list[Path]) -> None:
        self._paths = paths

    def fetch_since(
        self, since: datetime, senders: list[str], limit: int | None = None
    ) -> list[RawMessage]:
        messages = []
        for path in self._paths:
            raw = path.read_bytes()
            msg = email.message_from_bytes(raw, policy=email.policy.default)
            date_hdr = msg["Date"]
            received_at = email.utils.parsedate_to_datetime(str(date_hdr))
            messages.append(
                RawMessage(
                    message_id=str(msg["Message-ID"]),
                    raw_bytes=raw,
                    received_at=received_at,
                    from_addr=str(msg.get("From", "")),
                )
            )
        # Newest-first, like ImapSource: a cap keeps the most recent.
        messages.sort(key=lambda m: m.received_at, reverse=True)
        return messages if limit is None else messages[:limit]


@pytest.fixture
def user_id() -> str:
    # processed_emails.message_id is a *global* primary key (section 9's
    # schema, matching a real Message-ID header) -- fine for the plan's
    # assumed single-user deployment (section 15), but it means two tests
    # that reuse the same real fixture .eml files under different synthetic
    # user_ids collide on message_id. Truncate first so each test starts
    # from a clean table rather than fighting a previous test's rows.
    with psycopg.connect(DB_URL, autocommit=True) as conn:
        with conn.cursor() as cur:
            cur.execute(
                "truncate table transactions, processed_emails, accounts, sync_runs, "
                "transfer_groups, ledger_gaps, categories, merchant_rules, "
                "auth.users cascade"
            )
            uid = str(uuid.uuid4())
            cur.execute("insert into auth.users (id) values (%s)", (uid,))
    return uid


@pytest.fixture
def seeded_user_id(user_id) -> str:
    """user_id, plus the real supabase/seed.sql categories and merchant_rules
    applied -- psql's `:'user_id'` substitution done here as plain text
    replacement since these are locally-generated UUIDs, not untrusted input.
    """
    sql = SEED_SQL.replace(":'user_id'", f"'{user_id}'")
    with psycopg.connect(DB_URL, autocommit=True) as conn, conn.cursor() as cur:
        cur.execute(sql)
    return user_id


@pytest.fixture
def store():
    s = PostgresStore(DB_URL)
    yield s
    s.close()


def test_sync_twice_inserts_zero_duplicates(tmp_path, user_id, store):
    all_fixtures = sorted(FIXTURES_DIR.glob("*/*.eml"))
    assert len(all_fixtures) == FIXTURE_COUNT

    mail_source = FakeMailSource(all_fixtures)
    account_start = datetime(2026, 1, 1, tzinfo=timezone.utc)
    archive_dir = tmp_path / "raw"

    first = run_sync(
        store=store, mail_source=mail_source, archive_dir=archive_dir,
        user_id=user_id, machine="test-machine", senders=SENDERS,
        account_start=account_start,
    )
    assert first.fetched == FIXTURE_COUNT
    assert first.parsed == FIXTURE_COUNT
    assert first.failed == 0
    assert first.txns_inserted == FIXTURE_COUNT

    second = run_sync(
        store=store, mail_source=mail_source, archive_dir=archive_dir,
        user_id=user_id, machine="test-machine", senders=SENDERS,
        account_start=account_start,
    )
    assert second.fetched == FIXTURE_COUNT
    assert second.parsed == FIXTURE_COUNT
    assert second.txns_inserted == 0, "second run must insert zero rows"

    with psycopg.connect(DB_URL) as conn, conn.cursor() as cur:
        cur.execute("select count(*) from transactions where user_id = %s", (user_id,))
        assert cur.fetchone()[0] == FIXTURE_COUNT

        cur.execute("select count(*) from processed_emails where user_id = %s", (user_id,))
        assert cur.fetchone()[0] == FIXTURE_COUNT


def test_sync_survives_crash_before_db_write(tmp_path, user_id, store):
    """The exact scenario section 6.1's skip-if-archived step would break if
    taken literally: the raw file gets written to disk, then the process
    dies before any DB upsert happens. The next run must still reach the DB
    for that message -- see the module docstring on pipeline/sync.py.
    """
    fixture = sorted(FIXTURES_DIR.glob("*/*.eml"))[0]
    mail_source = FakeMailSource([fixture])
    account_start = datetime(2026, 1, 1, tzinfo=timezone.utc)
    archive_dir = tmp_path / "raw"

    raw = fixture.read_bytes()
    msg = email.message_from_bytes(raw, policy=email.policy.default)
    message_id = str(msg["Message-ID"])
    received_at = email.utils.parsedate_to_datetime(str(msg["Date"]))

    from expense_tracker.ingest import archive as archive_mod

    archive_mod.write(archive_dir, message_id, received_at, raw)
    assert archive_mod.exists(archive_dir, message_id, received_at)

    with psycopg.connect(DB_URL) as conn, conn.cursor() as cur:
        cur.execute("select count(*) from transactions where user_id = %s", (user_id,))
        assert cur.fetchone()[0] == 0

    result = run_sync(
        store=store, mail_source=mail_source, archive_dir=archive_dir,
        user_id=user_id, machine="test-machine", senders=SENDERS,
        account_start=account_start,
    )
    assert result.txns_inserted == 1, (
        "the file already existed on disk from the simulated crash, but the "
        "message must still reach the DB on this run"
    )


def test_balance_reconciliation_over_real_fixtures_is_idempotent(tmp_path, user_id, store):
    """Phase 3 DoD: 'the balance chain runs clean or reports specific gaps.'
    Runs the *real* Nabil balance chain (25 fixtures, sparsely sampled across
    ~200 real emails -- test_reconcile.py independently confirms this
    produces 19 real gaps) through the actual sync pipeline end to end, then
    re-runs it to confirm the daily reconciler doesn't re-insert the same
    gaps every day (the ledger_gaps_unique_pair constraint from this phase's
    migration).
    """
    all_fixtures = sorted(FIXTURES_DIR.glob("*/*.eml"))
    mail_source = FakeMailSource(all_fixtures)
    account_start = datetime(2026, 1, 1, tzinfo=timezone.utc)
    archive_dir = tmp_path / "raw"

    first = run_sync(
        store=store, mail_source=mail_source, archive_dir=archive_dir,
        user_id=user_id, machine="test-machine", senders=SENDERS,
        account_start=account_start,
    )
    assert first.new_ledger_gaps == 19

    second = run_sync(
        store=store, mail_source=mail_source, archive_dir=archive_dir,
        user_id=user_id, machine="test-machine", senders=SENDERS,
        account_start=account_start,
    )
    assert second.new_ledger_gaps == 0, "an unresolved gap must not be re-inserted daily"

    with psycopg.connect(DB_URL) as conn, conn.cursor() as cur:
        cur.execute("select count(*) from ledger_gaps where user_id = %s", (user_id,))
        assert cur.fetchone()[0] == 19


def test_transfer_match_excludes_both_legs_and_preserves_monthly_total(tmp_path, user_id, store):
    """Phase 3 DoD: the eSewa/Nabil pair 'collapse into one transfer_group,
    both legs excluded from spend, and the monthly total is unchanged by
    that pair.' The real eSewa Aug 31 fund-load fixture supplies the CREDIT
    leg; no matching Nabil DEBIT email exists in the mailbox yet (checked via
    Gmail search during this phase -- a live instance of the section 7.3
    'missing email' scenario), so its counterpart is inserted directly at
    the store level here, the same way a real sync would once that email
    arrives and gets parsed.
    """
    esewa_fixture = FIXTURES_DIR / "esewa" / "esewa_fund_load_2026-08-31.eml"
    mail_source = FakeMailSource([esewa_fixture])
    account_start = datetime(2026, 1, 1, tzinfo=timezone.utc)
    archive_dir = tmp_path / "raw"

    run_sync(
        store=store, mail_source=mail_source, archive_dir=archive_dir,
        user_id=user_id, machine="test-machine", senders=SENDERS,
        account_start=account_start,
    )

    from expense_tracker.parsers.base import NormalizedTxn
    from expense_tracker.parsers.dates import KATHMANDU

    # 09:46 Asia/Kathmandu -- 7 seconds after the real eSewa credit's
    # 09:45:53 local time, not 09:46 UTC (5h45m away and outside the
    # 30-minute matching window, which is exactly the bug this comment is
    # here to stop a future edit from reintroducing).
    debit_occurred_at = datetime(2026, 8, 31, 9, 46, tzinfo=KATHMANDU)

    nabil_account_id = store.get_or_create_account(user_id, "NABIL", "001#####234567", "BANK", "NPR")
    with psycopg.connect(DB_URL, autocommit=True) as conn, conn.cursor() as cur:
        cur.execute(
            "insert into processed_emails (message_id, user_id, received_at, from_addr, "
            "status) values (%s, %s, %s, %s, 'PARSED')",
            ("<synthetic-nabil-counterpart@test>", user_id, debit_occurred_at, "txn-alert@nabilbank.com"),
        )
    nabil_debit = NormalizedTxn(
        template_key="nabil.txn_alert", parser_version=1, institution="NABIL",
        account_mask="001#####234567",
        occurred_at=debit_occurred_at,
        occurred_precision="MINUTE", direction="DEBIT", amount_paisa=100_000,
        currency="NPR", description_raw="ESW DLA:SYNTHETIC",
        message_id="<synthetic-nabil-counterpart@test>",
        dedupe_key="nabil:001#####234567:2026-08-31T09:46:DEBIT:100000:synthetic",
    )
    store.upsert_transactions(
        user_id, nabil_account_id, [nabil_debit],
        source_message_id="<synthetic-nabil-counterpart@test>",
    )

    with psycopg.connect(DB_URL) as conn, conn.cursor() as cur:
        cur.execute(
            "select spent_paisa from v_monthly_spend where user_id = %s", (user_id,)
        )
        before = cur.fetchall()
        # RLS default-denies without a session role; this connection uses
        # the service_role-equivalent test superuser so it bypasses RLS the
        # same way the worker's connection does.
    spent_before = sum(row[0] or 0 for row in before)
    assert spent_before >= 100_000  # the synthetic debit is still counted as spend

    from expense_tracker.pipeline.transfers import match_and_link_transfers

    linked = match_and_link_transfers(store, user_id, window_days=60)
    assert linked == 1

    with psycopg.connect(DB_URL) as conn, conn.cursor() as cur:
        cur.execute(
            "select transfer_group_id, excluded_from_spend from transactions "
            "where user_id = %s order by direction",
            (user_id,),
        )
        rows = cur.fetchall()
        assert len(rows) == 2
        group_ids = {r[0] for r in rows}
        assert len(group_ids) == 1 and None not in group_ids
        assert all(r[1] is True for r in rows)

        cur.execute("select spent_paisa from v_monthly_spend where user_id = %s", (user_id,))
        after = cur.fetchall()
    spent_after = sum(row[0] or 0 for row in after)
    assert spent_after == spent_before - 100_000, (
        "the linked pair must drop out of spend entirely -- it's a transfer, not spend"
    )


def test_categorization_hits_phase4_dod_and_is_idempotent(tmp_path, seeded_user_id, store):
    """Phase 4 DoD: '>= 80% of the last three months auto-categorized by
    rules alone, with the Ollama path disabled.' Runs the full sync pipeline
    (steps 1-9) end to end against the real supabase/seed.sql rules and all
    the whole Phase 0 fixture corpus, then re-runs it to confirm the categorizer
    doesn't touch already-CATEGORIZED rows or re-count them.
    """
    user_id = seeded_user_id
    all_fixtures = sorted(FIXTURES_DIR.glob("*/*.eml"))
    mail_source = FakeMailSource(all_fixtures)
    account_start = datetime(2026, 1, 1, tzinfo=timezone.utc)
    archive_dir = tmp_path / "raw"

    first = run_sync(
        store=store, mail_source=mail_source, archive_dir=archive_dir,
        user_id=user_id, machine="test-machine", senders=SENDERS,
        account_start=account_start, use_ollama=False,
    )
    assert first.categorized_by_llm == 0, "Ollama must stay disabled for this DoD measurement"
    coverage = first.categorized_by_rule / first.txns_inserted
    assert coverage >= 0.80, f"only {coverage:.0%} auto-categorized by rules alone"

    with psycopg.connect(DB_URL) as conn, conn.cursor() as cur:
        cur.execute(
            "select status, count(*) from transactions where user_id = %s group by status",
            (user_id,),
        )
        status_counts = dict(cur.fetchall())
    assert status_counts.get("CATEGORIZED", 0) == first.categorized_by_rule
    assert status_counts.get("NEEDS_REVIEW", 0) == first.still_review

    second = run_sync(
        store=store, mail_source=mail_source, archive_dir=archive_dir,
        user_id=user_id, machine="test-machine", senders=SENDERS,
        account_start=account_start, use_ollama=False,
    )
    assert second.categorized_by_rule == 0, "nothing new to categorize on a rerun"
    assert second.still_review == first.still_review, (
        "the categorizer must not lose track of rows a rule still doesn't cover"
    )
