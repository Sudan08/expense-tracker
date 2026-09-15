"""The SMS leg of the sync run: raw_messages -> parser -> transactions.

Covers the three outcomes a pending row can have, because the whole point of
staging SMS in the DB is that none of them is silently dropped (invariant 6).
"""

from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path

import pytest

from expense_tracker.ingest.source import RawMessage  # noqa: F401 -- protocol shape
from expense_tracker.parsers.base import NormalizedTxn
from expense_tracker.parsers.sms import SmsMessage
from expense_tracker.pipeline import sync as sync_module
from expense_tracker.pipeline.sync import run_sync

RECEIVED = datetime(2026, 9, 5, 10, 30, tzinfo=timezone.utc)
SINCE = datetime(2026, 9, 1, tzinfo=timezone.utc)


def _sms(sms_id: str, body: str) -> SmsMessage:
    return SmsMessage(
        id=sms_id,
        sender="LaxmiBank",
        body=body,
        received_at=RECEIVED,
        content_hash=f"hash-{sms_id}",
    )


class FakeStore:
    def __init__(self, pending: list[SmsMessage]) -> None:
        self.pending = pending
        self.marks: list[tuple] = []
        self.upserts: list[dict] = []

    # -- bookkeeping the run always touches ---------------------------------
    def last_completed_sync_at(self, user_id):
        return None

    def start_sync_run(self, user_id, machine, started_at, since):
        return "run-1"

    def finish_sync_run(self, *args, **kwargs):
        pass

    # -- the SMS leg ---------------------------------------------------------
    def fetch_pending_raw_messages(self, user_id, limit=500):
        return self.pending

    def mark_raw_message(self, raw_message_id, status, template_key, parser_version, error, txn_count):
        self.marks.append((raw_message_id, status, template_key, error, txn_count))

    def get_or_create_account(self, user_id, institution, mask, kind, currency):
        return f"account-{institution}"

    def upsert_transactions(self, user_id, account_id, txns, *, source_message_id=None, source_raw_message_id=None):
        self.upserts.append(
            {
                "account_id": account_id,
                "count": len(txns),
                "source_message_id": source_message_id,
                "source_raw_message_id": source_raw_message_id,
            }
        )
        return len(txns)

    # -- the later stages, stubbed out --------------------------------------
    def fetch_transfer_candidates(self, user_id, since):
        return []

    def fetch_balance_rows_by_account(self, user_id):
        return {}

    def resolve_gaps_absent_from(self, user_id, detected):
        return 0

    def fetch_needs_review_transactions(self, user_id, limit):
        return []

    def fetch_merchant_rules(self, user_id):
        return []

    def fetch_categories(self, user_id):
        return {}


class EmptyMailSource:
    def fetch_since(self, since, senders, limit=None):
        return []


class StubLaxmiParser:
    template_key = "laxmi.sms_alert"
    parser_version = 1

    def matches(self, message: SmsMessage) -> bool:
        return "LAXMI" in message.body.upper()

    def parse(self, message: SmsMessage) -> list[NormalizedTxn]:
        if "BOOM" in message.body:
            raise ValueError("unparseable amount")
        return [
            NormalizedTxn(
                template_key=self.template_key,
                parser_version=self.parser_version,
                institution="LAXMI",
                account_mask="123#####456",
                occurred_at=RECEIVED,
                occurred_precision="MINUTE",
                direction="DEBIT",
                amount_paisa=250_000,
                description_raw=message.body,
                message_id=message.content_hash,
                dedupe_key=f"laxmi:{message.content_hash}",
            )
        ]


@pytest.fixture
def with_stub_parser(monkeypatch):
    monkeypatch.setattr(sync_module, "route_sms", lambda m: StubLaxmiParser() if StubLaxmiParser().matches(m) else None)


def _run(store):
    return run_sync(
        store=store,
        mail_source=EmptyMailSource(),
        archive_dir=Path("/nonexistent"),
        user_id="user-1",
        machine="test",
        senders=["laxmibank.com"],
        account_start=SINCE,
    )


def test_matched_sms_becomes_a_transaction_tagged_with_its_raw_message(with_stub_parser):
    store = FakeStore([_sms("sms-1", "LAXMI: Debit NPR 2,500.00")])

    result = _run(store)

    assert result.sms_parsed == 1
    assert result.txns_inserted == 1
    assert store.marks == [("sms-1", "PARSED", "laxmi.sms_alert", None, 1)]

    # Provenance points at raw_messages, not processed_emails -- the check
    # constraint in the schema requires exactly one of the two.
    (upsert,) = store.upserts
    assert upsert["source_raw_message_id"] == "sms-1"
    assert upsert["source_message_id"] is None


def test_unmatched_sms_is_ignored_with_a_reason_not_dropped(with_stub_parser):
    store = FakeStore([_sms("sms-2", "Your OTP is 4821")])

    result = _run(store)

    assert result.sms_ignored == 1
    assert result.txns_inserted == 0
    sms_id, status, template_key, error, txn_count = store.marks[0]
    assert (sms_id, status, template_key, txn_count) == ("sms-2", "IGNORED", None, 0)
    assert error  # invariant 6: the reason is recorded, never a silent skip


def test_a_parser_blowing_up_fails_one_message_not_the_run(with_stub_parser):
    store = FakeStore(
        [
            _sms("sms-3", "LAXMI: BOOM"),
            _sms("sms-4", "LAXMI: Debit NPR 2,500.00"),
        ]
    )

    result = _run(store)

    assert result.sms_failed == 1
    assert result.sms_parsed == 1  # the good one still went through
    failed = [m for m in store.marks if m[1] == "FAILED"]
    assert failed[0][0] == "sms-3"
    assert "unparseable amount" in failed[0][3]
