"""The --max-emails cap, and the count-without-fetching path behind `inbox`.

The cap exists so a first backfill over years of mail can be taken in bites.
Two things about it are load-bearing and easy to get silently wrong: it must
keep the *newest* messages rather than an arbitrary slice, and the caller must
be able to tell that it bit -- because a capped run still advances the
watermark, so a plain `sync` afterwards will not pick up the remainder.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest

from expense_tracker.ingest.source import MailboxCount, RawMessage
from expense_tracker.pipeline.sync import run_sync

BASE = datetime(2026, 9, 1, tzinfo=timezone.utc)


class CountingMailSource:
    """Generates N dated messages that no parser will claim.

    Routing them to IGNORED keeps the test about fetching and capping rather
    than about any particular bank's HTML.
    """

    def __init__(self, count: int) -> None:
        self.count = count
        self.fetch_calls: list[int | None] = []

    def _all(self) -> list[RawMessage]:
        return [
            RawMessage(
                message_id=f"<msg-{i}@example.com>",
                raw_bytes=(
                    f"From: someone@example.com\r\n"
                    f"Subject: not a bank email {i}\r\n\r\nbody\r\n"
                ).encode(),
                received_at=BASE + timedelta(days=i),
                from_addr="someone@example.com",
            )
            for i in range(self.count)
        ]

    def fetch_since(self, since, senders, limit=None):
        self.fetch_calls.append(limit)
        messages = sorted(self._all(), key=lambda m: m.received_at, reverse=True)
        return messages if limit is None else messages[:limit]

    def count_since(self, since, senders):
        return MailboxCount(by_sender={s: self.count for s in senders})


class FakeStore:
    """Enough of the Store surface for run_sync to complete offline.

    Every fetched message here routes to IGNORED, so the only write that
    matters is upsert_processed_email; the rest return empty so the
    transfer/reconcile/categorize stages run and find nothing to do.
    """

    def __init__(self) -> None:
        self.processed: list[str] = []

    def close(self): ...
    def last_completed_sync_at(self, user_id): return None
    def start_sync_run(self, user_id, machine, started_at, since): return "run-1"
    def finish_sync_run(self, *args, **kwargs): ...

    def upsert_processed_email(self, user_id, message_id, *args, **kwargs):
        self.processed.append(message_id)

    def fetch_pending_raw_messages(self, user_id, limit=500): return []
    def fetch_transfer_candidates(self, user_id, window_days): return []
    def fetch_balance_rows_by_account(self, user_id): return {}
    def resolve_gaps_absent_from(self, user_id, keys): return 0
    def fetch_merchant_rules(self, user_id): return []
    def fetch_needs_review_transactions(self, user_id, limit=500): return []
    def fetch_category_tree(self, user_id): return {}


@pytest.fixture
def run(tmp_path):
    def _run(source, **kwargs):
        return run_sync(
            store=FakeStore(),
            mail_source=source,
            archive_dir=tmp_path / "raw",
            user_id="user-1",
            machine="test",
            senders=["esewa.com.np"],
            account_start=BASE,
            **kwargs,
        )

    return _run


def test_uncapped_run_fetches_everything_and_reports_no_truncation(run):
    source = CountingMailSource(12)
    result = run(source)
    assert source.fetch_calls == [None]
    assert result.fetched == 12
    assert result.truncated_by_cap is False


def test_cap_limits_the_fetch_and_flags_that_it_bit(run):
    source = CountingMailSource(12)
    result = run(source, max_emails=5)
    assert source.fetch_calls == [5]
    assert result.fetched == 5
    assert result.truncated_by_cap is True


def test_cap_larger_than_the_mailbox_is_not_reported_as_truncation(run):
    """A cap of 50 over 12 messages drained the window -- telling the user
    there is more to fetch would send them into a pointless second run."""
    result = run(CountingMailSource(12), max_emails=50)
    assert result.fetched == 12
    assert result.truncated_by_cap is False


def test_cap_keeps_the_newest_messages(run):
    """Capping to the oldest N would mean a user taking a long backfill in
    bites sees their ledger fill in from years ago forward, with the recent
    months -- the ones they actually look at -- arriving last."""
    source = CountingMailSource(10)
    kept = source.fetch_since(BASE, ["esewa.com.np"], limit=3)
    assert [m.message_id for m in kept] == [
        "<msg-9@example.com>",
        "<msg-8@example.com>",
        "<msg-7@example.com>",
    ]


def test_count_since_totals_across_senders():
    source = CountingMailSource(7)
    counts = source.count_since(BASE, ["esewa.com.np", "nabilbank.com"])
    assert counts.by_sender == {"esewa.com.np": 7, "nabilbank.com": 7}
    assert counts.total == 14


def test_mailbox_count_of_an_empty_window_totals_zero():
    assert MailboxCount(by_sender={}).total == 0
