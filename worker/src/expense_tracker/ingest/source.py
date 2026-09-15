"""MailSource protocol. Behind this, the pipeline never talks to imaplib
directly. See docs/EXPENSE_TRACKER_PLAN.md section 5.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Protocol


@dataclass(frozen=True)
class RawMessage:
    message_id: str
    raw_bytes: bytes
    received_at: datetime
    from_addr: str


@dataclass(frozen=True)
class MailboxCount:
    """How many messages a window holds, without having downloaded any.

    `count_since` answers "how much is there?" cheaply so the user can decide
    whether they want it, which is a different question from "give it to me"
    and must not cost the same. IMAP answers it with a SEARCH that returns
    message numbers only -- no bodies, no attachments.
    """

    by_sender: dict[str, int]

    @property
    def total(self) -> int:
        return sum(self.by_sender.values())


class MailSource(Protocol):
    def fetch_since(
        self, since: datetime, senders: list[str], limit: int | None = None
    ) -> list[RawMessage]: ...

    def count_since(self, since: datetime, senders: list[str]) -> MailboxCount: ...


class NetworkUnavailable(Exception):
    """IMAP host couldn't be reached at all -- DNS failure, connection
    refused, timeout. Distinct from a bad password or protocol error, which
    are real config problems the user should see immediately rather than
    have silently retried. Section 6.4: "a failed sync isn't an error
    condition, it's Tuesday" applies to this case only.
    """
