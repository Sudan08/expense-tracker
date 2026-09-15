"""When a run fails, the failure the operator sees must be the one that
actually happened.

Two things used to destroy that. run_sync closes out its sync_runs row in a
`finally`, which runs exactly when the run has already blown up -- and the
commonest reason it blew up is the network going away, so the bookkeeping
write is the next thing to hit the dead connection and its exception
replaces the real one. And cli.sync gave up after a single attempt, so a
launchd job fired at wake (before wifi has associated) forfeited the day.

Offline: fake store, fake mail source, no DB.
"""

from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path

import pytest

from expense_tracker import cli
from expense_tracker.ingest.source import NetworkUnavailable
from expense_tracker.pipeline.sync import SyncResult, run_sync
from expense_tracker.store.base import StoreUnavailable

SINCE = datetime(2026, 9, 1, tzinfo=timezone.utc)


class FakeStore:
    def __init__(self, finish_raises: Exception | None = None) -> None:
        self.finish_raises = finish_raises
        self.finished: list[str | None] = []
        self.closed = False

    def close(self):
        self.closed = True

    def last_completed_sync_at(self, user_id):
        return None

    def start_sync_run(self, user_id, machine, started_at, since):
        return "run-1"

    def fetch_pending_raw_messages(self, user_id, limit=500):
        return []

    def finish_sync_run(self, run_id, completed_at, fetched, parsed, failed, txns_inserted, error):
        if self.finish_raises is not None:
            raise self.finish_raises
        self.finished.append(error)


class DeadMailSource:
    def fetch_since(self, since, senders, limit=None):
        raise NetworkUnavailable("could not reach imap.gmail.com: socket error: EOF")


def _run(store, mail_source=None, archive_dir=Path("/nonexistent")):
    return run_sync(
        store=store,
        mail_source=mail_source or DeadMailSource(),
        archive_dir=archive_dir,
        user_id="user-1",
        machine="test",
        senders=["esewa.com.np"],
        account_start=SINCE,
    )


def test_bookkeeping_failure_does_not_mask_the_real_error():
    """The DB write that records the failure must not become the failure."""
    store = FakeStore(finish_raises=StoreUnavailable("database unreachable during query"))

    with pytest.raises(NetworkUnavailable, match="socket error: EOF"):
        _run(store)


def test_failed_run_is_still_recorded_when_the_connection_survives():
    store = FakeStore()

    with pytest.raises(NetworkUnavailable):
        _run(store)

    assert store.finished == ["could not reach imap.gmail.com: socket error: EOF"]


@pytest.mark.parametrize(
    "outage",
    [NetworkUnavailable("imap down"), StoreUnavailable("db down")],
    ids=["imap", "database"],
)
def test_sync_retries_while_the_network_comes_up(monkeypatch, outage):
    """launchd fires a missed job the instant the machine wakes, before wifi
    has associated. The first attempt fails; a later one must still get the
    day's data."""
    slept: list[int] = []
    monkeypatch.setattr(cli.time, "sleep", lambda s: slept.append(s))
    monkeypatch.setattr(cli, "PostgresStore", lambda db_url: FakeStore())
    monkeypatch.setattr(cli, "ImapSource", lambda *a, **k: None)

    calls = {"n": 0}
    sentinel = SyncResult(since=SINCE, fetched=3, parsed=3)

    def _run_sync(**kwargs):
        calls["n"] += 1
        if calls["n"] == 1:
            raise outage
        return sentinel

    monkeypatch.setattr(cli, "run_sync", _run_sync)

    result = cli._sync_once_network_permitting(_config(), None, False)

    assert result is sentinel
    assert calls["n"] == 2
    assert slept == [cli.STARTUP_BACKOFF_SECONDS]


def test_sync_gives_up_quietly_after_the_last_attempt(monkeypatch):
    """Section 6.4: still unreachable after waiting is not an error. Return
    None so the caller exits 0 and the next scheduled run picks up the gap."""
    monkeypatch.setattr(cli.time, "sleep", lambda s: None)
    monkeypatch.setattr(cli, "PostgresStore", lambda db_url: FakeStore())
    monkeypatch.setattr(cli, "ImapSource", lambda *a, **k: None)

    calls = {"n": 0}

    def _always_down(**kwargs):
        calls["n"] += 1
        raise NetworkUnavailable("imap down")

    monkeypatch.setattr(cli, "run_sync", _always_down)

    assert cli._sync_once_network_permitting(_config(), None, False) is None
    assert calls["n"] == cli.STARTUP_ATTEMPTS


def test_a_real_bug_still_propagates(monkeypatch):
    """Only unavailability is retried and swallowed. Anything else must
    still exit non-zero -- silently exiting 0 on a parser crash would mean
    the sync 'succeeds' every day while ingesting nothing."""
    monkeypatch.setattr(cli, "PostgresStore", lambda db_url: FakeStore())
    monkeypatch.setattr(cli, "ImapSource", lambda *a, **k: None)

    def _boom(**kwargs):
        raise ValueError("parser regression")

    monkeypatch.setattr(cli, "run_sync", _boom)

    with pytest.raises(ValueError, match="parser regression"):
        cli._sync_once_network_permitting(_config(), None, False)


def _config():
    class _C:
        db_url = "postgresql://example"
        imap_host = "imap.gmail.com"
        imap_username = "u"
        imap_password = "p"
        archive_dir = Path("/nonexistent")
        user_id = "user-1"
        machine = "test"
        esewa_sender = "esewa.com.np"
        nabil_sender = "nabilbank.com"
        account_start = SINCE

    return _C()
