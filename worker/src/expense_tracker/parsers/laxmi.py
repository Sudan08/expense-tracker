"""laxmi.sms_alert. See docs/EXPENSE_TRACKER_PLAN.md section 8.5.

PROVISIONAL, same caveat as nabil.card_txn (nabil.py): the plan calls for
collecting real SMS bodies into a fixture corpus before writing the parser,
and as of this file there is exactly one real body on file (a QR-Pay debit).
The core sentence shape --

    Dear Customer, Your #{account} has been {debited|credited} by NPR
    {amount} on {date}. Remarks:{remarks}
    -Laxmi Sunrise

-- is common to Nepali bank SMS alerts generally, so direction/amount/date
extraction should hold across other Laxmi templates (ATM, fund transfer,
salary, ...). `guess_channel`/`guess_counterparty` is fit to the one
QR-Pay example and returns None for anything else it doesn't recognise,
same fallback discipline as nabil.guess_channel -- so an unrecognised
remarks shape still parses (amount/direction/date correct), it just leaves
channel/reference/counterparty unset rather than guessing wrong. Widen the
regexes as more real bodies come in.
"""

from __future__ import annotations

import re
from typing import TYPE_CHECKING

from expense_tracker.parsers.base import NormalizedTxn
from expense_tracker.parsers.dates import parse_laxmi_sms_alert
from expense_tracker.parsers.money import parse_subunit

if TYPE_CHECKING:
    # sms.py imports this module to build SMS_PARSERS, so importing SmsMessage
    # back at runtime would be circular. The annotations below are strings
    # (see __future__ import above), so this type-only import is enough.
    from expense_tracker.parsers.sms import SmsMessage

_TXN_RE = re.compile(
    r"Your #(?P<account>\S+) has been (?P<direction>debited|credited) by NPR"
    r"\s*(?P<amount>[\d,]+\.\d{2}) on (?P<date>\d{2}/\d{2}/\d{2})\."
    r"\s*Remarks:(?P<remarks>.*?)\s*(?:-\s*Laxmi\b.*)?$",
    re.IGNORECASE | re.DOTALL,
)

# "QR-Pay,CMPAY,44700000D4T4/KK Store,Sales;Sales" -> reference
# "44700000D4T4", counterparty "KK Store". Only shape seen so far.
_QR_PAY_REF_RE = re.compile(r"(?P<reference>[A-Z0-9]{6,})/(?P<counterparty>[^,;]+)")


def guess_channel(remarks: str) -> str | None:
    remarks = remarks.strip()
    if remarks.upper().startswith("QR-PAY"):
        return "QR_PAY"
    return None


class LaxmiSmsAlertParser:
    template_key = "laxmi.sms_alert"
    parser_version = 1

    def matches(self, message: SmsMessage) -> bool:
        if "LAXMI" not in message.sender.upper() and "LAXMI" not in message.body.upper():
            return False
        return _TXN_RE.search(message.body) is not None

    def parse(self, message: SmsMessage) -> list[NormalizedTxn]:
        match = _TXN_RE.search(message.body)
        if match is None:
            raise ValueError("laxmi.sms_alert: body did not match expected shape")

        account_mask = match.group("account")
        direction = "DEBIT" if match.group("direction").lower() == "debited" else "CREDIT"
        amount_paisa = parse_subunit(match.group("amount"))
        occurred_at = parse_laxmi_sms_alert(match.group("date"))
        description_raw = match.group("remarks").strip()

        reference = None
        counterparty = None
        ref_match = _QR_PAY_REF_RE.search(description_raw)
        if ref_match is not None:
            reference = ref_match.group("reference")
            counterparty = ref_match.group("counterparty").strip()

        dedupe_key = f"laxmi:{message.content_hash}"

        return [
            NormalizedTxn(
                template_key=self.template_key,
                parser_version=self.parser_version,
                institution="LAXMI",
                account_mask=account_mask,
                occurred_at=occurred_at,
                occurred_precision="DAY",
                direction=direction,
                amount_paisa=amount_paisa,
                currency="NPR",
                reference=reference,
                description_raw=description_raw,
                counterparty=counterparty,
                channel=guess_channel(description_raw),
                message_id=message.content_hash,
                dedupe_key=dedupe_key,
            )
        ]
