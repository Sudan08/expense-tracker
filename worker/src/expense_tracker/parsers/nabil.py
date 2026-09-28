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

# Nabil masks the same account differently depending on the transport:
#
#     email  "001#####234567"   first 3 + last 6, one # per hidden digit
#     SMS    "001##34567"       first 3 + last 5, # count is decorative
#
# Left as-is these are two different strings, which means two rows in
# `accounts` for one real account and -- worse -- two different dedupe_keys
# for one real transaction, so every Nabil transaction that arrives by both
# transports would be counted twice. Reducing both to the digits they agree
# on (first 3 + last 5) is what makes the email and SMS legs land on the same
# account and collapse onto the same row.
#
# Guarded on length because it must never be pointed at a card mask:
# "XXXX4321" carries four digits, and blindly slicing would turn a card into
# something that collides with a bank account. nabil.card_txn deliberately
# does not use this.
_CANONICAL_MIN_DIGITS = 8


def canonical_account_mask(mask: str) -> str:
    """The digits both transports agree on, for one Nabil bank account."""
    digits = re.sub(r"\D", "", mask or "")
    if len(digits) < _CANONICAL_MIN_DIGITS:
        return mask
    return f"{digits[:3]}{digits[-5:]}"


# Nabil's SMS truncates the remarks field to 18 characters, hard. Measured
# against 157 real SMS bodies: 128 were cut at exactly 18, and every shorter
# one was a remark genuinely shorter than that. The email carries up to 50.
#
#     email  "ATM WDL -03051911-NABIL-NABIL"
#     SMS    "ATM WDL -03051911-"
#
# So 18 characters is the *entire* overlap between the two transports. A
# fingerprint taken over any more than this can never match across them --
# which is exactly how an earlier version of this function, reading 24
# characters, silently duplicated every Nabil transaction that arrived twice.
_SMS_REMARKS_LIMIT = 18


def _remarks_fingerprint(remarks: str) -> str:
    """A hash of the remarks that both transports can compute identically.

    The remarks field is the only thing distinguishing two transactions of
    the same amount, in the same minute, in the same direction -- so the
    dedupe key needs it. But it must be read only as far as the *shorter*
    transport carries it, which is why the raw string is cut to
    _SMS_REMARKS_LIMIT before anything else happens to it. Truncating after
    normalising would not work: the two sides strip a different number of
    non-alphanumerics on the way there and land in different places.

    The cost is real and accepted: two transactions on one account, in the
    same minute, in the same direction, for the same amount, whose remarks
    agree for 18 characters, collapse into one -- two Rs 5 ASBA fees for
    different IPOs would. Measured over the full 667-transaction corpus this
    has never once happened, and balance reconciliation (section 7.3) is the
    backstop that would surface it if it did.
    """
    truncated = (remarks or "")[:_SMS_REMARKS_LIMIT]
    normalized = re.sub(r"[^A-Z0-9]", "", truncated.upper())
    # sha256 rather than sha1 purely for portability: the migration that
    # rewrites existing keys has to recompute this in SQL, and sha256() is a
    # core Postgres function while sha1 is only available via the pgcrypto
    # extension -- which on Supabase is installed into a separate `extensions`
    # schema that a bare digest() call may not resolve against. The hash is a
    # dedupe discriminator, not a security primitive, so any stable digest
    # does; picking the one both sides can always compute costs nothing.
    return hashlib.sha256(normalized.encode()).hexdigest()[:8]


def nabil_account_dedupe_key(
    mask: str | None,
    occurred_at,
    direction: str,
    amount_paisa: int,
    remarks: str,
) -> str:
    """One transaction, one key -- whichever transport reported it.

    Truncated to the minute because that is the coarser of the two: the SMS
    gives seconds, the email only minutes, and a key built from seconds could
    never match one built from minutes.
    """
    return (
        f"nabil:{canonical_account_mask(mask or '')}:"
        f"{occurred_at:%Y-%m-%dT%H:%M}:{direction}:{amount_paisa}:"
        f"{_remarks_fingerprint(remarks)}"
    )

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

            dedupe_key = nabil_account_dedupe_key(
                account_mask, occurred_at, direction, amount_paisa, description_raw
            )

            txns.append(
                NormalizedTxn(
                    template_key=self.template_key,
                    parser_version=self.parser_version,
                    institution="NABIL",
                    # Canonical, not the mask as printed: this is the account's
                    # identity, and nabil.sms_alert must resolve to the same one.
                    account_mask=canonical_account_mask(account_mask or ""),
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

    # Deliberately NOT canonicalised. A card mask is not a bank account
    # number, it carries four digits rather than fourteen, and there is no
    # second transport reporting the same card transaction to collapse
    # against -- so this template keeps the raw mask and its original
    # dedupe_key formula, and is untouched by the cross-transport work above.

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
