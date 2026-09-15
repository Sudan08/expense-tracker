"""nabil.txn_alert and nabil.card_txn. See docs/EXPENSE_TRACKER_PLAN.md section 8.

nabil.card_txn has no plan spec yet -- its template_key, channel value
(CARD_FX), and dedupe_key formula here are provisional, carried over from
the Phase 0 fixture corpus (worker/tests/fixtures/expected.yaml). Promote
them into the plan once a human confirms the shape is stable.
"""

from __future__ import annotations

import hashlib
import re
from email.message import EmailMessage

from selectolax.parser import HTMLParser

from expense_tracker.parsers.base import NormalizedTxn
from expense_tracker.parsers.dates import parse_nabil_card_txn, parse_nabil_txn_alert
from expense_tracker.parsers.money import parse_subunit

_ACCOUNT_MASK_RE = re.compile(r"account number ([0-9#]+)")

_CHANNEL_RULES: list[tuple[str, str]] = [
    ("ATM WDL", "ATM"),
    ("MPAY FPQR", "FONEPAY"),
    ("MPAY ", "MOBILE_BANKING"),
    ("C-ASBA Fee", "CHARGE"),
    ("CASBA allot", "IPO_ALLOTMENT"),
    ("eSewa Load", "ESEWA_LOAD"),
    ("ESW DLA:", "ESEWA_LOAD"),
]


def guess_channel(remarks: str) -> str | None:
    remarks = remarks.strip()
    if remarks.lower().startswith("salary for"):
        return "SALARY"
    for prefix, channel in _CHANNEL_RULES:
        if remarks.startswith(prefix):
            return channel
    return None


def _html_body(message: EmailMessage) -> str:
    part = message.get_body(preferencelist=("html",))
    if part is None:
        raise ValueError("no HTML part")
    return part.get_content()


def _plain_body(message: EmailMessage) -> str:
    part = message.get_body(preferencelist=("plain", "html"))
    if part is None:
        raise ValueError("no text part")
    return part.get_content()


class NabilTxnAlertParser:
    template_key = "nabil.txn_alert"
    parser_version = 1

    def matches(self, message: EmailMessage) -> bool:
        from_addr = str(message.get("From", ""))
        if "nabilbank.com" not in from_addr:
            return False
        try:
            body = _html_body(message)
        except ValueError:
            return False
        return "Transaction Alert" in body

    def parse(self, message: EmailMessage) -> list[NormalizedTxn]:
        message_id = str(message["Message-ID"])
        body = _html_body(message)

        mask_match = _ACCOUNT_MASK_RE.search(body)
        account_mask = mask_match.group(1) if mask_match else None

        tree = HTMLParser(body)
        table = tree.css_first('table[border="1"]')
        if table is None:
            raise ValueError("nabil.txn_alert: no bordered table found")

        rows = table.css("tr")
        header_cells = [c.text(strip=True) for c in rows[0].css("td, th")]
        column = {name: i for i, name in enumerate(header_cells)}

        txns: list[NormalizedTxn] = []
        for row in rows[1:]:
            cells = [c.text(strip=True) for c in row.css("td, th")]
            if not cells:
                continue

            occurred_at = parse_nabil_txn_alert(cells[column["Transaction Date"]])
            direction = cells[column["Transaction Type"]].strip().upper()
            assert direction in ("DEBIT", "CREDIT")
            amount_paisa = parse_subunit(cells[column["Transaction Amount"]])
            balance_after_paisa = parse_subunit(cells[column["Available Balance"]])
            description_raw = cells[column["Remarks"]]

            remarks_hash = hashlib.sha1(description_raw.encode()).hexdigest()[:8]
            dedupe_key = (
                f"nabil:{account_mask}:{occurred_at:%Y-%m-%dT%H:%M}:"
                f"{direction}:{amount_paisa}:{remarks_hash}"
            )

            txns.append(
                NormalizedTxn(
                    template_key=self.template_key,
                    parser_version=self.parser_version,
                    institution="NABIL",
                    account_mask=account_mask,
                    occurred_at=occurred_at,
                    occurred_precision="MINUTE",
                    direction=direction,
                    amount_paisa=amount_paisa,
                    balance_after_paisa=balance_after_paisa,
                    currency="NPR",
                    description_raw=description_raw,
                    channel=guess_channel(description_raw),
                    message_id=message_id,
                    dedupe_key=dedupe_key,
                )
            )
        return txns


_CARD_TXN_RE = re.compile(
    r"Your Debit Card (?P<mask>\S+) was used at (?P<description>.+?)"
    r" for Purchase of (?P<currency>[A-Z]{3}) (?P<amount>[\d,]+\.\d{2})"
    r" on (?P<date>\d{2}-[A-Z]{3}-\d{2})",
    re.DOTALL,
)


class NabilCardTxnParser:
    template_key = "nabil.card_txn"
    parser_version = 1

    def matches(self, message: EmailMessage) -> bool:
        from_addr = str(message.get("From", ""))
        subject = str(message.get("Subject", ""))
        return "card-no-reply@nabilbank.com" in from_addr or "debit and credit txn" in subject.lower()

    def parse(self, message: EmailMessage) -> list[NormalizedTxn]:
        message_id = str(message["Message-ID"])
        body = " ".join(_plain_body(message).split())

        match = _CARD_TXN_RE.search(body)
        if match is None:
            raise ValueError("nabil.card_txn: body did not match expected shape")

        mask = match.group("mask")
        description_raw = match.group("description").strip()
        counterparty = description_raw.split(";")[0].strip()
        currency = match.group("currency")
        amount_subunit = parse_subunit(match.group("amount"))
        occurred_at = parse_nabil_card_txn(match.group("date"))

        desc_hash = hashlib.sha1(description_raw.encode()).hexdigest()[:8]
        dedupe_key = (
            f"nabil:{mask}:{occurred_at:%Y-%m-%d}:DEBIT:{amount_subunit}:{desc_hash}"
        )

        return [
            NormalizedTxn(
                template_key=self.template_key,
                parser_version=self.parser_version,
                institution="NABIL",
                account_mask=mask,
                occurred_at=occurred_at,
                occurred_precision="DAY",
                direction="DEBIT",
                amount_paisa=amount_subunit,
                currency=currency,
                description_raw=description_raw,
                counterparty=counterparty,
                channel="CARD_FX",
                message_id=message_id,
                dedupe_key=dedupe_key,
            )
        ]
