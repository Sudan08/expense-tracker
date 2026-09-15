"""esewa.fund_load and esewa.payment_success. See docs/EXPENSE_TRACKER_PLAN.md
section 8.2 (fund_load) and 8.4 (payment_success -- listed there as
"the actual spending case, and the one you have zero samples of right now";
promoted here once a real sample showed up in the mailbox).
"""

from __future__ import annotations

from email.message import EmailMessage

from selectolax.parser import HTMLParser

from expense_tracker.parsers.base import NormalizedTxn
from expense_tracker.parsers.dates import parse_esewa_fund_load
from expense_tracker.parsers.money import parse_subunit


def _html_body(message: EmailMessage) -> str:
    part = message.get_body(preferencelist=("html",))
    if part is None:
        raise ValueError("no HTML part")
    return part.get_content()


class EsewaFundLoadParser:
    template_key = "esewa.fund_load"
    parser_version = 1

    def matches(self, message: EmailMessage) -> bool:
        from_addr = str(message.get("From", ""))
        if "esewa.com.np" not in from_addr:
            return False
        try:
            body = _html_body(message)
        except ValueError:
            return False
        return "Your fund load from bank details" in body

    def parse(self, message: EmailMessage) -> list[NormalizedTxn]:
        message_id = str(message["Message-ID"])
        body = _html_body(message)

        tree = HTMLParser(body)
        # NOT "first table with a <thead>" as the plan's section 8.2 spec
        # says: the real HTML nests <table> inside <p>, which selectolax's
        # HTML5 parser fosters out into a second, malformed table whose rows
        # concatenate the whole email's text. table[border="1"] is specific
        # enough to skip that artifact.
        table = tree.css_first('table[border="1"]')
        if table is None:
            raise ValueError("esewa.fund_load: no bordered table found")

        header_cells = [c.text(strip=True) for c in table.css("thead th")]
        column = {name: i for i, name in enumerate(header_cells)}

        rows = table.css("tbody tr")
        txns: list[NormalizedTxn] = []
        for row in rows:
            cells = [c.text(strip=True) for c in row.css("td")]
            if not cells:
                continue

            bank_name = cells[column["Bank Name"]]
            occurred_at = parse_esewa_fund_load(cells[column["Transaction Time"]])
            reference = cells[column["Reference Code"]]
            amount_col = next(k for k in column if k.startswith("Transaction Amount"))
            amount_paisa = parse_subunit(cells[column[amount_col]])

            txns.append(
                NormalizedTxn(
                    template_key=self.template_key,
                    parser_version=self.parser_version,
                    institution="ESEWA",
                    occurred_at=occurred_at,
                    occurred_precision="SECOND",
                    direction="CREDIT",
                    amount_paisa=amount_paisa,
                    currency="NPR",
                    reference=reference,
                    description_raw=bank_name,
                    counterparty=bank_name,
                    channel="WALLET_LOAD",
                    message_id=message_id,
                    dedupe_key=f"esewa:{reference}",
                )
            )
        return txns


class EsewaPaymentSuccessParser:
    template_key = "esewa.payment_success"
    parser_version = 1

    def matches(self, message: EmailMessage) -> bool:
        from_addr = str(message.get("From", ""))
        if "esewa.com.np" not in from_addr:
            return False
        try:
            body = _html_body(message)
        except ValueError:
            return False
        return "Thank you for the payment" in body

    def parse(self, message: EmailMessage) -> list[NormalizedTxn]:
        message_id = str(message["Message-ID"])
        body = _html_body(message)

        tree = HTMLParser(body)
        # Same fostering hazard as esewa.fund_load: the bordered table is
        # nested inside a <div>/<p>, and an HTML5 parser fosters that out
        # into a malformed sibling table. table[border="1"] stays specific
        # enough to skip it.
        table = tree.css_first('table[border="1"]')
        if table is None:
            raise ValueError("esewa.payment_success: no bordered table found")

        header_cells = [c.text(strip=True) for c in table.css("thead th")]
        column = {name: i for i, name in enumerate(header_cells)}

        rows = table.css("tbody tr")
        txns: list[NormalizedTxn] = []
        for row in rows:
            cells = [c.text(strip=True) for c in row.css("td")]
            if not cells:
                continue

            merchant = cells[column["Merchant Name"]]
            occurred_at = parse_esewa_fund_load(cells[column["Transaction Date"]])
            reference = cells[column["Transaction Code"]]
            amount_col = next(k for k in column if k.startswith("Transaction Amount"))
            amount_paisa = parse_subunit(cells[column[amount_col]])

            txns.append(
                NormalizedTxn(
                    template_key=self.template_key,
                    parser_version=self.parser_version,
                    institution="ESEWA",
                    occurred_at=occurred_at,
                    occurred_precision="SECOND",
                    direction="DEBIT",
                    amount_paisa=amount_paisa,
                    currency="NPR",
                    reference=reference,
                    description_raw=merchant,
                    counterparty=merchant,
                    channel="WALLET_PAYMENT",
                    message_id=message_id,
                    dedupe_key=f"esewa:{reference}",
                )
            )
        return txns
