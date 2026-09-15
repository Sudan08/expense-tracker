"""SMS parser contract, and the registry that routes a message to one.

The email path routes on an `email.message.EmailMessage`; an SMS has no
headers, no MIME parts, and no Message-ID -- just a sender label, a body, and
a timestamp the handset recorded. Forcing both down one abstraction would mean
inventing a fake EmailMessage for every SMS, so they stay separate protocols.

What they share is the thing that matters: both produce `NormalizedTxn`.
Everything downstream of parsing -- dedupe, transfer matching, reconciliation,
categorization -- never learns which transport a row came from.

Pure and offline, exactly like parsers/base.py: no network, no DB, no config.

Despite the name, "SMS" here really means "raw_messages row" -- anything
staged the same way an SMS is (sender/body/received_at/content_hash), parsed
the same way, with no email leg at all. esewa_statement.py's rows are the
second case: they come from a downloaded .xls, not a handset, but they are
staged in raw_messages and routed through this same registry rather than
inventing a third transport for what is, to everything downstream, just
another way a NormalizedTxn arrives without an email behind it.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import ClassVar, Protocol

from expense_tracker.parsers.base import NormalizedTxn
from expense_tracker.parsers.esewa_statement import EsewaStatementFileParser
from expense_tracker.parsers.laxmi import LaxmiSmsAlertParser


@dataclass(frozen=True)
class SmsMessage:
    """One row of `raw_messages`, as the parser sees it."""

    id: str
    sender: str
    body: str
    received_at: datetime
    content_hash: str


class SmsParser(Protocol):
    template_key: ClassVar[str]
    parser_version: ClassVar[int]

    def matches(self, message: SmsMessage) -> bool: ...
    def parse(self, message: SmsMessage) -> list[NormalizedTxn]: ...


# laxmi.sms_alert is fit to a single real fixture so far (see laxmi.py's
# docstring) -- anything that doesn't match its debited/credited-by-NPR shape
# still lands as IGNORED with the reason recorded (invariant 6), and the body
# stays in raw_messages for re-parsing once the shape is confirmed.
SMS_PARSERS: list[SmsParser] = [LaxmiSmsAlertParser(), EsewaStatementFileParser()]


def route_sms(message: SmsMessage) -> SmsParser | None:
    for parser in SMS_PARSERS:
        if parser.matches(message):
            return parser
    return None
