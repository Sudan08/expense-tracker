"""nabil.sms_alert -- the SMS half of the Nabil bank account.

Nabil reports the same transaction twice, over two transports with different
strengths:

    SMS    arrives within seconds, carries a full timestamp, no balance
    email  arrives when the worker next syncs, minute precision, WITH the
           running balance

Neither is redundant. The SMS is what makes a transaction visible today; the
balance only the email carries is what feeds reconciliation, which is how a
transaction the pipeline never saw at all gets detected (section 7.3). So
this parser is not a replacement for nabil.py -- the two are designed to
collapse onto one row, each contributing what the other lacks.

That collapse is `nabil_account_dedupe_key` in nabil.py: both templates build
the same key for the same transaction, and the unique constraint on
(user_id, dedupe_key) does the rest. Whichever transport arrives first
creates the row; the second is absorbed, and `upsert_transactions` fills in a
balance the first one couldn't supply. Nothing here needs to know which
happened -- invariant 5, idempotent by DB constraint rather than by
application logic.

Observed shape (one real body on file, redacted into the fixture corpus):

    Dear Customer, Your 001##34567 has been deposited by NPR 140000.0 on
    15/09/2026 18:16:13, Remarks: OWCLG CHQ 22803558 Activate
    bit.ly/xxxxxxx for a/c balance

PROVISIONAL, same discipline as laxmi.py: fit to the shapes seen so far,
widened as more real bodies arrive. Anything that doesn't match lands as
IGNORED with the reason recorded rather than being guessed at, and the body
stays in raw_messages to be re-parsed once the shape is known.
"""

from __future__ import annotations

import re
from typing import TYPE_CHECKING

from expense_tracker.parsers.base import NormalizedTxn
from expense_tracker.parsers.dates import parse_nabil_sms_alert
from expense_tracker.parsers.money import parse_subunit
from expense_tracker.parsers.nabil import (
    canonical_account_mask,
    guess_channel,
    nabil_account_dedupe_key,
)

if TYPE_CHECKING:
    # sms.py imports this module to build SMS_PARSERS, so importing
    # SmsMessage back at runtime would be circular -- see laxmi.py.
    from expense_tracker.parsers.sms import SmsMessage

# Direction verbs, not Laxmi's debited/credited pair. "deposited" is the only
# one on file; the withdrawal side is included from the same template family
# and will be confirmed against a real body -- an unrecognised verb doesn't
# match at all rather than defaulting to a direction, because guessing wrong
# here silently inverts a transaction.
_CREDIT_VERBS = ("deposited", "credited")
_DEBIT_VERBS = ("withdrawn", "debited")

_TXN_RE = re.compile(
    r"Your\s+#?(?P<account>[0-9#]+)\s+has been\s+"
    r"(?P<verb>" + "|".join(_CREDIT_VERBS + _DEBIT_VERBS) + r")\s+by\s+"
    r"(?P<currency>NPR|USD)\s*(?P<amount>[\d,]+(?:\.\d+)?)\s+on\s+"
    r"(?P<date>\d{2}/\d{2}/\d{4}\s+\d{2}:\d{2}:\d{2})"
    r"\s*[,.]?\s*Remarks:\s*(?P<remarks>.*?)\s*$",
    re.IGNORECASE | re.DOTALL,
)

# Nabil appends a standing advert to the end of the SMS. It is not part of
# the remarks, and leaving it in poisons both the dedupe fingerprint -- the
# SMS then cannot match its own email leg -- and every categorization rule the
# user writes against what they think they saw.
#
# Matched by *shape* rather than by listing the adverts, which was the earlier
# approach and was wrong twice: three variants turned out to be in circulation
# ("Download App: <url>", "For A/C Balance: <url>", "Activate <shortlink> for
# a/c balance"), and enumerating them means the next one Nabil invents
# silently starts duplicating transactions again.
#
# The general rule is: a trailing line carrying a URL is never part of a bank
# remark. Real remarks are references, merchant names and cheque numbers --
# none of them contain links.
_TRAILER_RE = re.compile(
    r"\s*(?:"
    r"[^\n]*https?://\S+"            # any trailing line containing a URL
    r"|Activate\s+\S+(?:\s+for\s+a/c\s+balance)?"   # shortlink, no scheme
    r"|-\s*Nabil\s*Bank.*"
    r")\s*$",
    re.IGNORECASE,
)


def _strip_trailer(remarks: str) -> str:
    previous = None
    while previous != remarks:
        previous = remarks
        remarks = _TRAILER_RE.sub("", remarks).strip()
    return remarks


class NabilSmsAlertParser:
    template_key = "nabil.sms_alert"
    parser_version = 1

    def matches(self, message: SmsMessage) -> bool:
        haystack = f"{message.sender} {message.body}".upper()
        if "NABIL" not in haystack:
            return False
        return _TXN_RE.search(message.body) is not None

    def parse(self, message: SmsMessage) -> list[NormalizedTxn]:
        match = _TXN_RE.search(message.body)
        if match is None:
            raise ValueError("nabil.sms_alert: body did not match expected shape")

        verb = match.group("verb").lower()
        direction = "CREDIT" if verb in _CREDIT_VERBS else "DEBIT"

        account_mask = canonical_account_mask(match.group("account"))
        amount_paisa = parse_subunit(match.group("amount"))
        occurred_at = parse_nabil_sms_alert(match.group("date"))
        description_raw = _strip_trailer(match.group("remarks"))

        return [
            NormalizedTxn(
                template_key=self.template_key,
                parser_version=self.parser_version,
                institution="NABIL",
                account_mask=account_mask,
                occurred_at=occurred_at,
                # The SMS really does carry seconds. Recording that honestly
                # matters for transfer matching, which widens its window
                # according to the precision it is told (invariant 2) -- even
                # though the dedupe key deliberately drops down to minutes to
                # meet the email leg.
                occurred_precision="SECOND",
                direction=direction,
                amount_paisa=amount_paisa,
                # No balance in this template -- Nabil's SMS advertises a
                # shortcode for the balance instead of quoting it. Left None
                # rather than zero: reconcile.py skips rows without a balance,
                # and a zero here would read as a real reading of zero and
                # manufacture a gap. The email leg supplies it later.
                balance_after_paisa=None,
                currency=match.group("currency").upper(),
                description_raw=description_raw,
                channel=guess_channel(description_raw),
                message_id=message.content_hash,
                dedupe_key=nabil_account_dedupe_key(
                    account_mask, occurred_at, direction, amount_paisa, description_raw
                ),
            )
        ]
