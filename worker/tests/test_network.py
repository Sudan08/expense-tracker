"""Section 6.4: IMAP unreachable (DNS failure, connection refused, timeout)
must surface as NetworkUnavailable, not a bare OSError -- that's what lets
the CLI (cli.py's `sync`) tell "no network, try again later" apart from a
real bug. Offline: no network, no DB.

Also covers the other half of that promise: a connection that dies *after*
it was established -- which is what actually happens on a laptop wake or a
wifi handover, and which raises imaplib.IMAP4.abort rather than OSError.
"""

from __future__ import annotations

import imaplib
from datetime import datetime, timezone

import pytest

from expense_tracker.ingest.imap import ImapSource
from expense_tracker.ingest.source import NetworkUnavailable

SINCE = datetime(2026, 1, 1, tzinfo=timezone.utc)


def test_connection_failure_raises_network_unavailable(monkeypatch):
    def _boom(host, timeout=None):
        raise OSError("[Errno -2] Name or service not known")

    monkeypatch.setattr("expense_tracker.ingest.imap.MailBox", _boom)

    source = ImapSource("imap.gmail.com", "user@example.com", "app-password")
    with pytest.raises(NetworkUnavailable, match="imap.gmail.com"):
        source.fetch_since(datetime(2026, 1, 1, tzinfo=timezone.utc), ["esewa.com.np"])


def test_login_failure_is_not_swallowed_as_network_unavailable(monkeypatch):
    """A bad password is a real config problem, not a transient outage --
    it must propagate as-is so the user sees it immediately."""

    class _FakeBox:
        def login(self, username, password):
            raise RuntimeError("AUTHENTICATIONFAILED")

    monkeypatch.setattr("expense_tracker.ingest.imap.MailBox", lambda host, timeout=None: _FakeBox())

    source = ImapSource("imap.gmail.com", "user@example.com", "wrong-password")
    with pytest.raises(RuntimeError, match="AUTHENTICATIONFAILED"):
        source.fetch_since(datetime(2026, 1, 1, tzinfo=timezone.utc), ["esewa.com.np"])


class _DyingBox:
    """A MailBox whose socket dies mid-fetch, and whose logout then fails
    too -- exactly the shape of the 2026-09 failures in expense-sync.err.log.
    """

    def __init__(self, fail_with):
        self._fail_with = fail_with
        self.logged_out = False

    def login(self, username, password):
        return self

    def fetch(self, criteria, mark_seen=False, limit=None, reverse=False):
        raise self._fail_with

    def logout(self):
        self.logged_out = True
        raise imaplib.IMAP4.abort("socket error: [Errno 32] Broken pipe")


@pytest.mark.parametrize(
    "failure",
    [
        imaplib.IMAP4.abort("socket error: EOF"),
        imaplib.IMAP4.abort("command: UID => socket error: EOF"),
        BrokenPipeError(32, "Broken pipe"),
    ],
    ids=["eof", "eof-mid-command", "broken-pipe"],
)
def test_connection_dying_mid_fetch_is_network_unavailable(monkeypatch, failure):
    """imaplib.IMAP4.abort is not an OSError, so catching only OSError let a
    mid-fetch disconnect escape as an unhandled crash -- exit 1 and a rich
    traceback -- instead of section 6.4's quiet skip."""
    box = _DyingBox(failure)
    monkeypatch.setattr("expense_tracker.ingest.imap.MailBox", lambda host, timeout=None: box)

    source = ImapSource("imap.gmail.com", "user@example.com", "app-password")
    with pytest.raises(NetworkUnavailable, match="imap.gmail.com"):
        source.fetch_since(SINCE, ["esewa.com.np"])


def test_failing_logout_does_not_mask_the_real_failure(monkeypatch):
    """MailBox.__exit__ logs out unconditionally, and logout on an already
    dead socket raises -- which used to replace the real cause with a
    useless "Broken pipe" raised from the exit path."""
    box = _DyingBox(imaplib.IMAP4.abort("socket error: EOF"))
    monkeypatch.setattr("expense_tracker.ingest.imap.MailBox", lambda host, timeout=None: box)

    source = ImapSource("imap.gmail.com", "user@example.com", "app-password")
    with pytest.raises(NetworkUnavailable, match="socket error: EOF"):
        source.fetch_since(SINCE, ["esewa.com.np"])
    assert box.logged_out, "logout must still be attempted, just not allowed to raise"


def test_protocol_error_is_not_swallowed_as_network_unavailable(monkeypatch):
    """IMAP4.error (abort's parent) covers real protocol and credential
    problems. Widening the handler to it would silently retry a broken
    config forever, so only abort is treated as a lost connection."""
    box = _DyingBox(imaplib.IMAP4.error("BAD invalid command"))
    monkeypatch.setattr("expense_tracker.ingest.imap.MailBox", lambda host, timeout=None: box)

    source = ImapSource("imap.gmail.com", "user@example.com", "app-password")
    with pytest.raises(imaplib.IMAP4.error, match="BAD invalid command"):
        source.fetch_since(SINCE, ["esewa.com.np"])
