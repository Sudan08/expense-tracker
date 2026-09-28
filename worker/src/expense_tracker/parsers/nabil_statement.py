"""bank_statement -- Generic parser for exported bank statement PDFs (Nabil, Laxmi, etc.)."""

from __future__ import annotations

import base64
import io
import re
from datetime import datetime, date
from typing import TYPE_CHECKING
import pdfplumber

from expense_tracker.parsers.base import NormalizedTxn
from expense_tracker.parsers.dates import KATHMANDU
from expense_tracker.parsers.money import parse_subunit

if TYPE_CHECKING:
    from expense_tracker.parsers.sms import SmsMessage

SUPPORTED_SENDERS = {"NABIL_STATEMENT", "LAXMI_STATEMENT", "BANK_STATEMENT"}


def parse_statement_date(s: str) -> datetime:
    """Parses date from bank statements in various formats to Kathmandu tz."""
    clean = s.strip()
    for fmt in (
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%d",
        "%d/%m/%Y %H:%M:%S",
        "%d/%m/%Y",
        "%d-%m-%Y",
        "%d-%b-%Y",
        "%d %b %Y",
        "%d/%m/%y",
        "%d-%m-%y",
    ):
        try:
            return datetime.strptime(clean, fmt).replace(tzinfo=KATHMANDU)
        except ValueError:
            continue
    try:
        d = date.fromisoformat(clean[:10])
        return datetime.combine(d, datetime.min.time(), tzinfo=KATHMANDU)
    except Exception:
        raise ValueError(f"unrecognised statement date format: {clean!r}")


class BankStatementFileParser:
    template_key = "bank.statement_row"
    parser_version = 1

    def matches(self, message: "SmsMessage") -> bool:
        return message.sender in SUPPORTED_SENDERS or message.sender.endswith("_STATEMENT")

    def parse(self, message: "SmsMessage") -> list[NormalizedTxn]:
        file_bytes = base64.b64decode(message.body)
        txns: list[NormalizedTxn] = []
        account_mask: str | None = None
        institution: str = "NABIL"
        if "LAXMI" in message.sender:
            institution = "LAXMI"

        with pdfplumber.open(io.BytesIO(file_bytes)) as pdf:
            full_text = ""
            for page in pdf.pages:
                text = page.extract_text() or ""
                full_text += " " + text

            # Auto-detect institution from header text
            text_lower = full_text.lower()
            if "laxmi" in text_lower or "sunrise" in text_lower:
                institution = "LAXMI"
            elif "nabil" in text_lower:
                institution = "NABIL"

            # Auto-detect account number
            acct_match = re.search(
                r"(?:Account\s*(?:Number|No\.?)|A/C\s*No\.?)\s*[:.]?\s*(\d{8,20})",
                full_text,
                re.IGNORECASE,
            )
            if acct_match:
                account_mask = acct_match.group(1)

            for page in pdf.pages:
                table = page.extract_table()
                if not table:
                    continue

                # Locate header row dynamically
                header_idx = -1
                date_col = -1
                desc_col = -1
                withdraw_col = -1
                deposit_col = -1
                balance_col = -1

                for i, row in enumerate(table):
                    if not row or len(row) < 4:
                        continue
                    row_cells = [str(c or "").strip().lower() for c in row]
                    
                    has_date = any("date" in c for c in row_cells)
                    has_amount = any(
                        any(term in c for term in ["withdraw", "debit", "dr", "deposit", "credit", "cr", "amount"])
                        for c in row_cells
                    )
                    if has_date and has_amount:
                        header_idx = i
                        for col_idx, cell in enumerate(row_cells):
                            if date_col == -1 and ("txn date" in cell or "transaction date" in cell or "date" in cell):
                                date_col = col_idx
                            elif desc_col == -1 and ("description" in cell or "particular" in cell or "narration" in cell or "remarks" in cell):
                                desc_col = col_idx
                            elif withdraw_col == -1 and ("withdraw" in cell or "debit" in cell or cell == "dr" or cell.startswith("dr.")):
                                withdraw_col = col_idx
                            elif deposit_col == -1 and ("deposit" in cell or "credit" in cell or cell == "cr" or cell.startswith("cr.")):
                                deposit_col = col_idx
                            elif balance_col == -1 and "balance" in cell:
                                balance_col = col_idx
                        break

                if header_idx == -1:
                    continue

                # Default column fallbacks
                if date_col == -1 and len(table[header_idx]) >= 2:
                    date_col = 1
                if desc_col == -1 and len(table[header_idx]) >= 3:
                    desc_col = 2
                if withdraw_col == -1 and len(table[header_idx]) >= 4:
                    withdraw_col = 3
                if deposit_col == -1 and len(table[header_idx]) >= 5:
                    deposit_col = 4
                if balance_col == -1 and len(table[header_idx]) >= 6:
                    balance_col = 5

                for row in table[header_idx + 1:]:
                    if not row or len(row) <= max(date_col, desc_col, withdraw_col, deposit_col):
                        continue

                    date_str = str(row[date_col] or "").strip()
                    desc = str(row[desc_col] or "").strip()
                    withdraw_str = str(row[withdraw_col] or "").strip() if withdraw_col < len(row) and row[withdraw_col] else ""
                    deposit_str = str(row[deposit_col] or "").strip() if deposit_col < len(row) and row[deposit_col] else ""
                    balance_str = str(row[balance_col] or "").strip() if balance_col != -1 and balance_col < len(row) and row[balance_col] else ""

                    if (
                        not date_str
                        or "opening balance" in desc.lower()
                        or "closing balance" in desc.lower()
                        or "total" in desc.lower()
                        or "carried over" in desc.lower()
                    ):
                        continue

                    # Determine direction and amount
                    if withdraw_str and withdraw_str not in ("-", "0.00", "0"):
                        direction = "DEBIT"
                        amount = parse_subunit(withdraw_str)
                    elif deposit_str and deposit_str not in ("-", "0.00", "0"):
                        direction = "CREDIT"
                        amount = parse_subunit(deposit_str)
                    else:
                        continue

                    balance_paisa = (
                        parse_subunit(balance_str)
                        if balance_str and balance_str not in ("-", "")
                        else None
                    )

                    # Canonical mask
                    canon_mask = account_mask
                    if account_mask:
                        if institution == "NABIL" and len(account_mask) > 8:
                            canon_mask = account_mask[:3] + account_mask[-5:]
                        elif institution == "LAXMI":
                            canon_mask = account_mask[-8:] if len(account_mask) > 8 else account_mask

                    try:
                        occurred_at = parse_statement_date(date_str)
                    except ValueError:
                        continue

                    txns.append(
                        NormalizedTxn(
                            template_key=self.template_key,
                            parser_version=self.parser_version,
                            institution=institution,
                            account_mask=canon_mask,
                            occurred_at=occurred_at,
                            occurred_precision="DAY",
                            direction=direction,
                            amount_paisa=amount,
                            balance_after_paisa=balance_paisa,
                            currency="NPR",
                            description_raw=desc.replace("\n", " "),
                            message_id=message.content_hash,
                            dedupe_key=f"{institution.lower()}_stmt:{message.content_hash}:{len(txns)}",
                        )
                    )

        return txns


# Backward compatibility alias
NabilStatementFileParser = BankStatementFileParser
