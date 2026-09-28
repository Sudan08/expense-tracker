"""nabil.sms_alert, and the thing it exists for: collapsing onto the email leg.

Nabil reports one transaction twice. The parser being correct in isolation is
the easy half; the half that decides whether the ledger double-counts is
whether both transports compute the *same* dedupe_key from what each of them
was given -- different account masking, different timestamp precision, and
remarks the email truncates at 50 characters.
"""

from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

import pytest

from expense_tracker.parsers.nabil import (
    canonical_account_mask,
    nabil_account_dedupe_key,
)
from expense_tracker.parsers.nabil_sms import NabilSmsAlertParser
from expense_tracker.parsers.sms import SmsMessage, route_sms

KTM = ZoneInfo("Asia/Kathmandu")
FIXTURE = (
    Path(__file__).parent
    / "fixtures/sms/nabil/nabil_sms_alert_2026-09-15_deposit.txt"
)


def sms(body: str, *, sender: str = "NabilBank", content_hash: str = "h1") -> SmsMessage:
    return SmsMessage(
        id="raw-1",
        sender=sender,
        body=body,
        received_at=datetime(2026, 9, 15, 12, 31, tzinfo=timezone.utc),
        content_hash=content_hash,
    )


# --------------------------------------------------------------- the parser


def test_real_fixture_parses_to_its_stated_values():
    txn = route_sms(sms(FIXTURE.read_text())).parse(sms(FIXTURE.read_text()))[0]

    assert txn.template_key == "nabil.sms_alert"
    assert txn.institution == "NABIL"
    assert txn.account_mask == "00134567"
    assert txn.occurred_at == datetime(2026, 9, 15, 18, 16, 13, tzinfo=KTM)
    assert txn.occurred_precision == "SECOND"
    assert txn.direction == "CREDIT"
    assert txn.amount_paisa == 14_000_000
    assert txn.currency == "NPR"
    assert txn.description_raw == "OWCLG CHQ 22803558"


def test_the_standing_advert_is_not_part_of_the_remarks():
    """Nabil appends 'Activate <link> for a/c balance' to every SMS. Left in,
    it would poison the dedupe fingerprint and every merchant rule the user
    writes against what they think the remarks say."""
    txn = NabilSmsAlertParser().parse(sms(FIXTURE.read_text()))[0]
    assert "Activate" not in txn.description_raw
    assert "bit.ly" not in txn.description_raw


def test_no_balance_is_recorded_as_none_not_zero():
    """reconcile.py skips rows with no balance; a zero would read as a real
    reading of zero and manufacture a gap out of nothing."""
    txn = NabilSmsAlertParser().parse(sms(FIXTURE.read_text()))[0]
    assert txn.balance_after_paisa is None


@pytest.mark.parametrize(
    "verb,expected",
    [("deposited", "CREDIT"), ("credited", "CREDIT"),
     ("withdrawn", "DEBIT"), ("debited", "DEBIT")],
)
def test_direction_verbs(verb, expected):
    body = (
        f"Dear Customer, Your 001##34567 has been {verb} by NPR 500.0 "
        f"on 15/09/2026 18:16:13, Remarks: TEST REF"
    )
    assert NabilSmsAlertParser().parse(sms(body))[0].direction == expected


def test_amount_with_one_decimal_place_is_read_correctly():
    """Nabil writes '140000.0', not Laxmi's two-decimal '1,595.00'. Read with
    a two-decimal regex this silently fails to match at all."""
    body = (
        "Dear Customer, Your 001##34567 has been deposited by NPR 140000.0 "
        "on 15/09/2026 18:16:13, Remarks: X"
    )
    assert NabilSmsAlertParser().parse(sms(body))[0].amount_paisa == 14_000_000


def test_date_is_day_first_not_month_first():
    """15/09 has to be 15 September. Read month-first it isn't a date at all,
    and a body like 05/09 would silently land in the wrong month."""
    txn = NabilSmsAlertParser().parse(sms(FIXTURE.read_text()))[0]
    assert (txn.occurred_at.day, txn.occurred_at.month) == (15, 9)


def test_an_unrecognised_body_is_not_claimed():
    """It must land as IGNORED with a reason (invariant 6) rather than being
    guessed at -- a wrong direction here inverts a transaction."""
    assert route_sms(sms("Your OTP for Nabil Bank login is 123456")) is None


def test_another_banks_sms_is_not_claimed():
    body = (
        "Dear Customer, Your #20001234 has been debited by NPR 1,595.00 "
        "on 11/09/26. Remarks:QR-Pay -Laxmi Sunrise"
    )
    assert route_sms(sms(body, sender="LaxmiSunrise")).template_key == "laxmi.sms_alert"


# ------------------------------------------- collapsing onto the email leg


def test_sms_and_email_of_one_transaction_produce_one_dedupe_key():
    """The whole point. Different mask, different precision, same key."""
    from_sms = nabil_account_dedupe_key(
        "001##34567", datetime(2026, 9, 15, 18, 16, 13, tzinfo=KTM),
        "CREDIT", 14_000_000, "OWCLG CHQ 22803558",
    )
    from_email = nabil_account_dedupe_key(
        "001#####234567", datetime(2026, 9, 15, 18, 16, tzinfo=KTM),
        "CREDIT", 14_000_000, "OWCLG CHQ 22803558",
    )
    assert from_sms == from_email


def test_the_parsers_themselves_agree_not_just_the_helper():
    """Guards against one parser being changed without the other."""
    sms_txn = NabilSmsAlertParser().parse(sms(FIXTURE.read_text()))[0]
    email_equivalent = nabil_account_dedupe_key(
        "001#####234567", datetime(2026, 9, 15, 18, 16, tzinfo=KTM),
        "CREDIT", 14_000_000, "OWCLG CHQ 22803558",
    )
    assert sms_txn.dedupe_key == email_equivalent


def test_both_transports_resolve_to_the_same_account():
    """Two masks for one account would mean two `accounts` rows, and every
    balance chain split across them."""
    assert canonical_account_mask("001##34567") == canonical_account_mask("001#####234567")


def test_the_email_truncating_remarks_does_not_break_the_match():
    """The email's Remarks column cuts at 50 characters; the SMS doesn't."""
    full = "MPAY FPQR,41749528iKRz,EXAMPLE EDUCATION SERVICE,and more tail"
    assert len(full) > 50
    when = datetime(2026, 9, 15, 18, 16, tzinfo=KTM)
    assert nabil_account_dedupe_key("001##34567", when, "DEBIT", 100, full) == \
           nabil_account_dedupe_key("001#####234567", when, "DEBIT", 100, full[:50])


def test_two_different_transactions_in_the_same_minute_stay_distinct():
    """The reason the key carries a remarks fingerprint at all: same account,
    same minute, same direction, same amount, different transaction."""
    when = datetime(2026, 9, 15, 18, 16, tzinfo=KTM)
    assert nabil_account_dedupe_key("001##34567", when, "CREDIT", 14_000_000, "OWCLG CHQ 22803558") != \
           nabil_account_dedupe_key("001##34567", when, "CREDIT", 14_000_000, "OWCLG CHQ 22803559")


def test_a_card_mask_is_never_canonicalised():
    """nabil.card_txn keeps its own identity and its own key formula -- a card
    reduced to digits could collide with a bank account."""
    assert canonical_account_mask("XXXX4321") == "XXXX4321"
