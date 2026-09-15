"""laxmi.sms_alert against the one real fixture on file.

Mirrors tests/test_parsers.py's fixture-vs-expected-output shape, but for SMS:
there's no email.message.EmailMessage to construct, so the fixture is just
the raw body text and the expectations live inline rather than in
expected.yaml (that file's loader is wired to the email `route`).
"""

from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path

from expense_tracker.parsers.sms import SmsMessage, route_sms

FIXTURES_DIR = Path(__file__).parent / "fixtures" / "sms" / "laxmi"


def _load(rel_path: str) -> SmsMessage:
    body = (FIXTURES_DIR / rel_path).read_text()
    return SmsMessage(
        id="raw-1",
        sender="LaxmiSunrise",
        body=body,
        received_at=datetime(2026, 9, 11, 12, 0, tzinfo=timezone.utc),
        content_hash="content-hash-1",
    )


def test_qr_pay_debit_fixture_matches_expected():
    message = _load("laxmi_sms_alert_2026-09-11_qr_pay.txt")

    parser = route_sms(message)
    assert parser is not None
    assert parser.template_key == "laxmi.sms_alert"

    (txn,) = parser.parse(message)

    assert txn.institution == "LAXMI"
    assert txn.account_mask == "20001234"
    assert txn.direction == "DEBIT"
    assert txn.amount_paisa == 159_500
    assert txn.currency == "NPR"
    assert txn.occurred_at == datetime(2026, 9, 11, tzinfo=txn.occurred_at.tzinfo)
    assert txn.occurred_precision == "DAY"
    assert txn.description_raw == "QR-Pay,CMPAY,44700000D4T4/KK Store,Sales;Sales"
    assert txn.reference == "44700000D4T4"
    assert txn.counterparty == "KK Store"
    assert txn.channel == "QR_PAY"
    assert txn.dedupe_key == "laxmi:content-hash-1"


def test_credit_variant_of_the_same_shape_is_recognised():
    message = _load("laxmi_sms_alert_2026-09-11_qr_pay.txt")
    message = SmsMessage(
        id=message.id,
        sender=message.sender,
        body=message.body.replace("debited", "credited"),
        received_at=message.received_at,
        content_hash=message.content_hash,
    )

    parser = route_sms(message)
    (txn,) = parser.parse(message)

    assert txn.direction == "CREDIT"


def test_unrelated_sms_is_not_matched():
    message = SmsMessage(
        id="raw-2",
        sender="Ncell",
        body="Your OTP is 4821. Do not share it with anyone.",
        received_at=datetime(2026, 9, 11, 12, 0, tzinfo=timezone.utc),
        content_hash="content-hash-2",
    )

    assert route_sms(message) is None
