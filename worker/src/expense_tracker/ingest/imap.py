"""IMAP fetch via imap-tools + Gmail app password. See
docs/EXPENSE_TRACKER_PLAN.md section 5.
"""

from __future__ import annotations

import contextlib
import imaplib
from datetime import datetime

from imap_tools import AND, MailBox

from expense_tracker.ingest.source import MailboxCount, NetworkUnavailable, RawMessage

# imaplib sockets are blocking with no timeout by default, so a network
# stall mid-read (wifi drop, laptop sleep) hangs the process forever --
# which then holds the sync lock and blocks every future scheduled run
# indefinitely. Bound every socket operation so a stall surfaces as
# NetworkUnavailable instead.
_SOCKET_TIMEOUT_SECONDS = 60

# imaplib raises IMAP4.abort -- NOT an OSError -- when an established
# connection dies underneath it: "socket error: EOF" when the server hangs
# up mid-command, "socket error: [Errno 32] Broken pipe" when the local
# socket is already dead (laptop wake, wifi handover). Catching only
# OSError let those escape as unhandled crashes, so a mid-fetch network
# flap exited non-zero instead of taking section 6.4's quiet-skip path.
# IMAP4.error (its parent) is deliberately NOT caught: that covers real
# protocol and credential problems, which must stay loud.
_CONNECTION_LOST = (OSError, imaplib.IMAP4.abort)


class ImapSource:
    def __init__(self, host: str, username: str, password: str) -> None:
        self._host = host
        self._username = username
        self._password = password

    @contextlib.contextmanager
    def _connected(self):
        """Yield a logged-in mailbox, mapping a dead connection to
        NetworkUnavailable.

        Both fetching and counting need exactly this, and the subtleties
        below were each paid for once already -- having two copies is how one
        of them silently loses a fix.
        """
        try:
            # The connection happens here, inside MailBox.__init__ -- not in
            # .login() below, which only sends IMAP LOGIN once a socket
            # already exists. OSError covers DNS failure, connection
            # refused, and timeout alike. The timeout also bounds every
            # later read on this same socket (login, fetch), so a stall
            # mid-fetch lands here too instead of hanging indefinitely.
            box = MailBox(self._host, timeout=_SOCKET_TIMEOUT_SECONDS)
            mailbox = box.login(self._username, self._password)
            # Deliberately not `with box.login(...) as mailbox`. MailBox's
            # __exit__ calls logout() unconditionally, and logout on an
            # already-dead socket raises -- which replaces the real failure
            # with a useless "abort: socket error: Broken pipe" raised from
            # the exit path. Closing a connection we are done with can
            # never tell us anything the caller needs, so suppress it.
            try:
                yield mailbox
            finally:
                with contextlib.suppress(Exception):
                    mailbox.logout()
        except _CONNECTION_LOST as exc:
            raise NetworkUnavailable(f"could not reach {self._host}: {exc}") from exc

    def fetch_since(
        self, since: datetime, senders: list[str], limit: int | None = None
    ) -> list[RawMessage]:
        """Download messages from `senders` received on or after `since`.

        `limit` caps the total number of messages downloaded across all
        senders -- the "don't pull ten years in one go" control. The cap is
        applied newest-first, so a capped run returns the most recent
        messages rather than an arbitrary prefix of the oldest ones; the
        older remainder is still there for the next run, because a cap
        narrows only this fetch and never advances anything on its own.
        """
        messages: list[RawMessage] = []
        with self._connected() as mailbox:
            for sender in senders:
                if limit is not None and len(messages) >= limit:
                    break
                remaining = None if limit is None else limit - len(messages)
                criteria = AND(from_=sender, date_gte=since.date())
                for msg in mailbox.fetch(
                    criteria, mark_seen=False, limit=remaining, reverse=True
                ):
                    message_id = (msg.obj["Message-ID"] or "").strip()
                    if not message_id:
                        # No Message-ID header at all is rare and not a case
                        # any real eSewa/Nabil email has hit; fall back to
                        # the IMAP UID so the row still has a stable key
                        # instead of silently being skipped.
                        message_id = f"<no-message-id-uid-{msg.uid}@{sender}>"
                    messages.append(
                        RawMessage(
                            message_id=message_id,
                            raw_bytes=msg.obj.as_bytes(),
                            received_at=msg.date,
                            from_addr=msg.from_,
                        )
                    )
        return messages

    def count_since(self, since: datetime, senders: list[str]) -> MailboxCount:
        """How many messages a fetch would return, without returning any.

        SEARCH gives back message numbers only, so this costs one round trip
        per sender regardless of how many years the window covers -- which is
        the whole point: the user gets to see the size of a backfill before
        deciding to pay for it.
        """
        by_sender: dict[str, int] = {}
        with self._connected() as mailbox:
            for sender in senders:
                criteria = AND(from_=sender, date_gte=since.date())
                by_sender[sender] = len(mailbox.numbers(criteria))
        return MailboxCount(by_sender=by_sender)
