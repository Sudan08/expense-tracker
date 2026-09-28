"""One Nabil transaction, two transports, one row -- against a real Postgres.

test_parsers_nabil_sms.py proves the two parsers compute the same dedupe_key.
That is necessary but not sufficient: what actually decides whether the ledger
double-counts is the unique constraint and the ON CONFLICT clause, and those
only exist in the database. This is where that half is checked.

The specific thing worth guarding: the SMS arrives first (seconds) and carries
no balance; the email arrives at the next sync (up to twelve hours later) and
does. If the second arrival is simply discarded, the row keeps a null balance
forever, reconcile.py skips it, and balance-gap detection silently stops
working for the account -- a failure that looks exactly like a clean ledger.

Requires a local Postgres; skipped if EXPENSE_TRACKER_TEST_DB_URL isn't set.
conftest.py applies the migrations the first time it sees a fresh database.
"""

from __future__ import annotations

import os
import uuid
from datetime import datetime
from zoneinfo import ZoneInfo

import psycopg
import pytest

from expense_tracker.parsers.base import NormalizedTxn
from expense_tracker.parsers.nabil import (
    canonical_account_mask,
    nabil_account_dedupe_key,
)
from expense_tracker.pipeline.sync import upsert_by_account
from expense_tracker.store.supabase import PostgresStore

DB_URL = os.environ.get("EXPENSE_TRACKER_TEST_DB_URL")
pytestmark = pytest.mark.skipif(not DB_URL, reason="EXPENSE_TRACKER_TEST_DB_URL not set")

KTM = ZoneInfo("Asia/Kathmandu")
WHEN_SECONDS = datetime(2026, 9, 15, 18, 16, 13, tzinfo=KTM)
WHEN_MINUTES = datetime(2026, 9, 15, 18, 16, tzinfo=KTM)
REMARKS = "OWCLG CHQ 22803558"
AMOUNT = 14_000_000
BALANCE = 18_543_055


@pytest.fixture
def user_id() -> str:
    uid = str(uuid.uuid4())
    with psycopg.connect(DB_URL, autocommit=True) as conn:
        conn.execute("insert into auth.users (id) values (%s)", (uid,))
    return uid


@pytest.fixture
def store():
    s = PostgresStore(DB_URL)
    yield s
    s.close()


@pytest.fixture
def email_source_id(user_id, store) -> str:
    """A processed_emails row for the email leg to hang off.

    transactions carries `check (num_nonnulls(source_message_id,
    source_raw_message_id) = 1)` plus a foreign key to each -- a parser-derived
    row must say which message it came from, and exactly one of them.
    """
    message_id = f"<cross-transport-{uuid.uuid4()}@example.com>"
    store.upsert_processed_email(
        user_id, message_id, WHEN_MINUTES, "txn-alert@nabilbank.com",
        "nabil.txn_alert", 1, "PARSED", None, 1,
    )
    return message_id


@pytest.fixture
def sms_source_id(user_id, store) -> str:
    """The raw_messages row the SMS leg came from."""
    content_hash = f"sms-{uuid.uuid4()}"
    store.insert_raw_message(
        user_id,
        channel="SMS",
        sender="NabilBank",
        body="(body staged by the phone)",
        received_at=WHEN_SECONDS,
        content_hash=content_hash,
    )
    with psycopg.connect(DB_URL) as conn:
        return str(
            conn.execute(
                "select id from raw_messages where user_id = %s and content_hash = %s",
                (user_id, content_hash),
            ).fetchone()[0]
        )


def _txn(*, mask: str, when: datetime, precision: str, balance: int | None,
         template: str, message_id: str) -> NormalizedTxn:
    return NormalizedTxn(
        template_key=template,
        parser_version=1,
        institution="NABIL",
        account_mask=mask,
        occurred_at=when,
        occurred_precision=precision,
        direction="CREDIT",
        amount_paisa=AMOUNT,
        balance_after_paisa=balance,
        currency="NPR",
        description_raw=REMARKS,
        message_id=message_id,
        dedupe_key=nabil_account_dedupe_key(mask, when, "CREDIT", AMOUNT, REMARKS),
    )


def sms_leg() -> NormalizedTxn:
    """As parsers/nabil_sms.py builds it: short mask, seconds, no balance."""
    return _txn(mask="00134567", when=WHEN_SECONDS, precision="SECOND",
                balance=None, template="nabil.sms_alert", message_id="hash-sms")


EMAIL_MASK = "001#####234567"


def email_leg() -> NormalizedTxn:
    """As parsers/nabil.py builds it.

    Note the mask is *canonicalised* before it becomes account_mask -- the
    parser does that deliberately, and it is the whole reason both transports
    resolve to one `accounts` row. Passing the raw printed mask here instead
    would make this fixture unfaithful to the parser and quietly create a
    second account.
    """
    return _txn(mask=canonical_account_mask(EMAIL_MASK), when=WHEN_MINUTES,
                precision="MINUTE", balance=BALANCE,
                template="nabil.txn_alert", message_id="<msg@x>")


def rows_for(user_id: str) -> list[tuple]:
    with psycopg.connect(DB_URL) as conn:
        return conn.execute(
            "select balance_after_paisa, amount_paisa, direction "
            "from transactions where user_id = %s",
            (user_id,),
        ).fetchall()


def accounts_for(user_id: str) -> list[str]:
    with psycopg.connect(DB_URL) as conn:
        return [
            r[0] for r in conn.execute(
                "select mask from accounts where user_id = %s and institution = 'NABIL'",
                (user_id,),
            ).fetchall()
        ]


def test_sms_then_email_is_one_row_and_the_email_supplies_the_balance(user_id, store, sms_source_id, email_source_id):
    """The real-world order: SMS in seconds, email at the next sync."""
    assert upsert_by_account(store, user_id, [sms_leg()], raw_message_id=sms_source_id) == 1
    assert rows_for(user_id) == [(None, AMOUNT, "CREDIT")]

    # Second transport, same transaction. Must not insert.
    assert upsert_by_account(store, user_id, [email_leg()], message_id=email_source_id) == 0

    rows = rows_for(user_id)
    assert len(rows) == 1, "one transaction reported twice became two rows"
    assert rows[0][0] == BALANCE, "the email's balance was discarded"


def test_email_then_sms_is_also_one_row_and_keeps_the_balance(user_id, store, sms_source_id, email_source_id):
    """The backfill order, and the direction where coalesce has to protect an
    existing value rather than fill a blank."""
    assert upsert_by_account(store, user_id, [email_leg()], message_id=email_source_id) == 1
    assert upsert_by_account(store, user_id, [sms_leg()], raw_message_id=sms_source_id) == 0

    rows = rows_for(user_id)
    assert len(rows) == 1
    assert rows[0][0] == BALANCE, "the SMS's null balance overwrote a real reading"


def test_both_transports_land_on_one_account(user_id, store, sms_source_id, email_source_id):
    """Two masks for one account would split the balance chain in half, and
    reconcile.py walks the chain per account."""
    upsert_by_account(store, user_id, [sms_leg()], raw_message_id=sms_source_id)
    upsert_by_account(store, user_id, [email_leg()], message_id=email_source_id)
    assert accounts_for(user_id) == ["00134567"]


def test_replaying_the_same_leg_stays_a_no_op(user_id, store, email_source_id):
    """ON CONFLICT DO UPDATE returns a row where DO NOTHING didn't, so the
    inserted count has to come from xmax rather than from RETURNING."""
    assert upsert_by_account(store, user_id, [email_leg()], message_id=email_source_id) == 1
    for _ in range(3):
        assert upsert_by_account(store, user_id, [email_leg()], message_id=email_source_id) == 0
    assert len(rows_for(user_id)) == 1


def test_a_genuinely_different_transaction_in_the_same_minute_is_kept(user_id, store, sms_source_id):
    """The guard against over-collapsing: same account, minute, direction and
    amount, different reference."""
    upsert_by_account(store, user_id, [sms_leg()], raw_message_id=sms_source_id)

    other = _txn(mask="00134567", when=WHEN_SECONDS, precision="SECOND",
                 balance=None, template="nabil.sms_alert", message_id="hash-sms-2")
    other = other.model_copy(update={
        "description_raw": "OWCLG CHQ 22803559",
        "dedupe_key": nabil_account_dedupe_key(
            "00134567", WHEN_SECONDS, "CREDIT", AMOUNT, "OWCLG CHQ 22803559"
        ),
    })
    assert upsert_by_account(store, user_id, [other], raw_message_id=sms_source_id) == 1
    assert len(rows_for(user_id)) == 2
