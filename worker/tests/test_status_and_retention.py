"""Phase 5 hardening: `status` (last run, unparsed count, open gaps) and the
raw/ retention job (section 11.3). Requires a local Postgres, skipped if
EXPENSE_TRACKER_TEST_DB_URL isn't set -- see test_sync_integration.py's
module docstring for how to stand one up.
"""

from __future__ import annotations

import os
import uuid
from datetime import datetime, timedelta, timezone

import psycopg
import pytest

from expense_tracker.ingest import archive
from expense_tracker.parsers.base import NormalizedTxn
from expense_tracker.pipeline.retention import RETENTION_DAYS, run_retention
from expense_tracker.store.supabase import PostgresStore

DB_URL = os.environ.get("EXPENSE_TRACKER_TEST_DB_URL")
pytestmark = pytest.mark.skipif(not DB_URL, reason="EXPENSE_TRACKER_TEST_DB_URL not set")


@pytest.fixture
def user_id() -> str:
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
def store():
    s = PostgresStore(DB_URL)
    yield s
    s.close()


def _insert_txn(
    store: PostgresStore, user_id: str, message_id: str, occurred_at: datetime, dedupe_key: str
) -> str:
    """Inserts one real transaction (own account + processed_emails row) and
    returns its id -- ledger_gaps and the retention query both need a real
    row to reference or count, not a bare fixture.
    """
    store.upsert_processed_email(
        user_id, message_id, occurred_at, "test@nabilbank.com",
        "nabil.txn_alert", 1, "PARSED", None, 1,
    )
    account_id = store.get_or_create_account(user_id, "NABIL", "0000#####0000", "BANK", "NPR")
    txn = NormalizedTxn(
        template_key="nabil.txn_alert", parser_version=1, institution="NABIL",
        account_mask="0000#####0000", occurred_at=occurred_at, occurred_precision="MINUTE",
        direction="DEBIT", amount_paisa=100000, description_raw="test txn",
        message_id=message_id, dedupe_key=dedupe_key,
    )
    store.upsert_transactions(user_id, account_id, [txn], source_message_id=message_id)
    with psycopg.connect(DB_URL) as conn, conn.cursor() as cur:
        cur.execute(
            "select id from transactions where user_id = %s and dedupe_key = %s",
            (user_id, dedupe_key),
        )
        return str(cur.fetchone()[0])


def _set_status(txn_id: str, status: str) -> None:
    with psycopg.connect(DB_URL) as conn, conn.cursor() as cur:
        cur.execute("update transactions set status = %s where id = %s", (status, txn_id))


class TestStatus:
    def test_fetch_last_sync_run_reflects_most_recent_attempt_including_failure(
        self, user_id, store
    ):
        assert store.fetch_last_sync_run(user_id) is None

        started = datetime.now(timezone.utc)
        run_id = store.start_sync_run(user_id, "test-machine", started, started)
        store.finish_sync_run(run_id, started, fetched=5, parsed=4, failed=1, txns_inserted=4, error=None)

        last = store.fetch_last_sync_run(user_id)
        assert last.machine == "test-machine"
        assert last.fetched == 5 and last.parsed == 4 and last.failed == 1
        assert last.error is None

        started2 = started + timedelta(hours=1)
        run_id2 = store.start_sync_run(user_id, "test-machine", started2, started2)
        store.finish_sync_run(
            run_id2, started2, fetched=0, parsed=0, failed=0, txns_inserted=0,
            error="could not reach imap.gmail.com",
        )

        last2 = store.fetch_last_sync_run(user_id)
        assert last2.error == "could not reach imap.gmail.com"

    def test_count_failed_emails(self, user_id, store):
        assert store.count_failed_emails(user_id) == 0
        store.upsert_processed_email(
            user_id, "<broken@nabilbank.com>", datetime.now(timezone.utc),
            "alerts@nabilbank.com", "nabil.txn_alert", 1, "FAILED", "boom", 0,
        )
        store.upsert_processed_email(
            user_id, "<ok@nabilbank.com>", datetime.now(timezone.utc),
            "alerts@nabilbank.com", "nabil.txn_alert", 1, "PARSED", None, 1,
        )
        assert store.count_failed_emails(user_id) == 1

    def test_count_open_ledger_gaps(self, user_id, store):
        now = datetime.now(timezone.utc)
        after = _insert_txn(store, user_id, "<gap-after@nabilbank.com>", now, "gap:after")
        before = _insert_txn(
            store, user_id, "<gap-before@nabilbank.com>", now + timedelta(minutes=1), "gap:before"
        )
        account_id_row = None
        with psycopg.connect(DB_URL) as conn, conn.cursor() as cur:
            cur.execute("select account_id from transactions where id = %s", (after,))
            account_id_row = cur.fetchone()[0]

        from expense_tracker.pipeline.reconcile import LedgerGap

        assert store.count_open_ledger_gaps(user_id) == 0
        store.insert_ledger_gap(
            user_id,
            LedgerGap(
                account_id=str(account_id_row), after_txn_id=after, before_txn_id=before,
                missing_paisa=50000,
            ),
        )
        assert store.count_open_ledger_gaps(user_id) == 1

        with psycopg.connect(DB_URL, autocommit=True) as conn, conn.cursor() as cur:
            cur.execute(
                "update ledger_gaps set resolved = true where after_txn_id = %s", (after,)
            )
        assert store.count_open_ledger_gaps(user_id) == 0


class TestRetention:
    def test_deletes_only_old_all_confirmed_emails(self, user_id, store, tmp_path):
        archive_dir = tmp_path / "raw"
        now = datetime.now(timezone.utc)
        old = now - timedelta(days=RETENTION_DAYS + 30)
        recent = now - timedelta(days=10)

        # Eligible: old, PARSED, single txn CONFIRMED.
        eligible_id = "<eligible@nabilbank.com>"
        eligible_txn = _insert_txn(store, user_id, eligible_id, old, "retain:eligible")
        _set_status(eligible_txn, "CONFIRMED")
        eligible_path = archive.write(archive_dir, eligible_id, old, b"eligible raw bytes")

        # Not eligible: old, but still NEEDS_REVIEW.
        unconfirmed_id = "<unconfirmed@nabilbank.com>"
        _insert_txn(store, user_id, unconfirmed_id, old, "retain:unconfirmed")
        unconfirmed_path = archive.write(archive_dir, unconfirmed_id, old, b"unconfirmed raw bytes")

        # Not eligible: CONFIRMED, but too recent.
        recent_id = "<recent@nabilbank.com>"
        recent_txn = _insert_txn(store, user_id, recent_id, recent, "retain:recent")
        _set_status(recent_txn, "CONFIRMED")
        recent_path = archive.write(archive_dir, recent_id, recent, b"recent raw bytes")

        deleted = run_retention(store, user_id, archive_dir, now=now)

        assert deleted == 1
        assert not eligible_path.exists()
        assert unconfirmed_path.exists()
        assert recent_path.exists()

        # processed_emails and transactions are never touched -- only the
        # raw cache file.
        with psycopg.connect(DB_URL) as conn, conn.cursor() as cur:
            cur.execute(
                "select count(*) from processed_emails where user_id = %s", (user_id,)
            )
            assert cur.fetchone()[0] == 3
