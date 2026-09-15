"""esewa.statement_row -- eSewa's own Profile -> Statement export, not an
email or SMS.

eSewa sends no email or SMS at all for a wallet-to-wallet transfer (only for
fund_load and payment_success, esewa.py's two templates). The row that
records a P2P send exists nowhere the worker listens -- except the in-app
Statement screen, which the user can export as .xls and which carries every
transaction type, including a running balance esewa.py's email templates
never do.

Rather than invent a third ingest transport, a whole exported file is staged
as a single `raw_messages` row like an SMS is (see parsers/sms.py's
SmsMessage) -- sender="ESEWA_STATEMENT" is what `matches` below keys on, and
`body` is the file's own bytes, base64-encoded, not free text. Whichever side
does the staging -- the CLI's `import-esewa-statement` (reads a local path)
or the phone (uploads whatever the eSewa app just exported, since there is no
robust legacy-.xls reader on Android/iOS worth shipping when the worker
already has one) -- neither one parses a single row of the spreadsheet
itself; `EsewaStatementFileParser.parse` below is the only place that
happens, same as every other parser in this package.

dedupe_key intentionally reuses esewa.py's own `esewa:{reference}` scheme.
eSewa's reference codes are shared across every surface (statement, email,
mini-statement SMS) -- confirmed by the fixture corpus, where
esewa_fund_load and esewa_payment_success references ("1PWB11H", "1Q5D142")
are the same seven-character shape as a statement row's ("1R1G2EC"). So if
the same transaction later shows up by email too (a payment_success that
eventually gets sent, say), the two rows collide on (user_id, dedupe_key)
and the second insert is a no-op -- not a duplicate transaction. That is
also what makes staging the same file twice (or two exports with an
overlapping date range) harmless even though they will not share a
content_hash: every row inside re-parses, and every row's insert is a no-op
at the transactions table.
"""

from __future__ import annotations

import base64
import re
from decimal import Decimal
from typing import TYPE_CHECKING

from expense_tracker.parsers.base import NormalizedTxn
from expense_tracker.parsers.dates import parse_esewa_statement
from expense_tracker.parsers.money import parse_subunit

if TYPE_CHECKING:
    # sms.py imports this module to build SMS_PARSERS, so importing
    # SmsMessage back at runtime would be circular -- same as laxmi.py.
    from expense_tracker.ingest.esewa_statement_file import StatementRow
    from expense_tracker.parsers.sms import SmsMessage

SENDER = "ESEWA_STATEMENT"

# Ordered most-specific first: "Paid For Bill Split to X" must not fall
# through to the plainer "Paid ... X" pattern and lose the split note, and
# every pattern here only ever supplies counterparty/channel -- direction
# and amount always come from the statement's own Dr./Cr. columns, never
# guessed from this text.
_DESCRIPTION_PATTERNS: list[tuple[re.Pattern[str], str | None]] = [
    (re.compile(r"^Paid For Bill Split to (?P<name>.+)$", re.IGNORECASE), "WALLET_PAYMENT"),
    (re.compile(r"^Paid (?:for|to) (?P<name>.+)$", re.IGNORECASE), "WALLET_PAYMENT"),
    (re.compile(r"^Fund Transferred to (?P<name>.+)$", re.IGNORECASE), "WALLET_TRANSFER"),
    (re.compile(r"^Fund Transferred by (?P<name>.+)$", re.IGNORECASE), "WALLET_TRANSFER"),
    (re.compile(r"^Money transferred from (?P<name>.+)$", re.IGNORECASE), "WALLET_LOAD"),
]


def _guess_counterparty_and_channel(description: str) -> tuple[str | None, str | None]:
    for pattern, channel in _DESCRIPTION_PATTERNS:
        match = pattern.match(description.strip())
        if match is not None:
            return match.group("name").strip(), channel
    return None, None


def normalize_row(row: "StatementRow", message_id: str) -> NormalizedTxn:
    """One StatementRow -> one NormalizedTxn. Pure, and the only place this
    mapping happens -- both EsewaStatementFileParser and (indirectly, via
    reparse) anything else reading a statement funnel through this.
    """
    dr = Decimal(row.dr)
    cr = Decimal(row.cr)
    if (dr > 0) == (cr > 0):
        # Exactly one of Dr./Cr. must be nonzero -- a real statement row
        # never has both (a zero-amount COMPLETE row) or neither.
        raise ValueError(f"esewa.statement_row: ambiguous Dr./Cr. ({dr}, {cr})")

    direction = "DEBIT" if dr > 0 else "CREDIT"
    amount_paisa = parse_subunit(str(dr if dr > 0 else cr))
    balance_after_paisa = parse_subunit(row.balance)
    counterparty, channel = _guess_counterparty_and_channel(row.description)

    return NormalizedTxn(
        template_key=EsewaStatementFileParser.template_key,
        parser_version=EsewaStatementFileParser.parser_version,
        institution="ESEWA",
        occurred_at=parse_esewa_statement(row.datetime_str),
        occurred_precision="SECOND",
        direction=direction,
        amount_paisa=amount_paisa,
        balance_after_paisa=balance_after_paisa,
        currency="NPR",
        reference=row.reference,
        description_raw=row.description,
        counterparty=counterparty,
        channel=channel,
        message_id=message_id,
        dedupe_key=f"esewa:{row.reference}",
    )


class EsewaStatementFileParser:
    template_key = "esewa.statement_row"
    parser_version = 1

    def matches(self, message: "SmsMessage") -> bool:
        return message.sender == SENDER

    def parse(self, message: "SmsMessage") -> list[NormalizedTxn]:
        # Deferred: this module is imported by sms.py, and rows_from_sheet_values
        # lives in ingest/, which importing at module level would make circular
        # the same way SmsMessage's TYPE_CHECKING-only import above is.
        from expense_tracker.ingest.esewa_statement_file import rows_from_workbook_bytes

        file_bytes = base64.b64decode(message.body)
        rows = rows_from_workbook_bytes(file_bytes)
        return [normalize_row(row, message.content_hash) for row in rows]
