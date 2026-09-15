"""(from, subject, body) -> parser. See docs/EXPENSE_TRACKER_PLAN.md section 8."""

from __future__ import annotations

from email.message import EmailMessage

from expense_tracker.parsers.base import Parser
from expense_tracker.parsers.esewa import EsewaFundLoadParser, EsewaPaymentSuccessParser
from expense_tracker.parsers.nabil import NabilCardTxnParser, NabilTxnAlertParser

PARSERS: list[Parser] = [
    NabilTxnAlertParser(),
    NabilCardTxnParser(),
    EsewaFundLoadParser(),
    EsewaPaymentSuccessParser(),
]


def route(message: EmailMessage) -> Parser | None:
    for parser in PARSERS:
        if parser.matches(message):
            return parser
    return None
