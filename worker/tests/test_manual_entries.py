"""The database half of manual entries and gap filling
(supabase/migrations/20260913000000_manual_entries_and_gap_fill.sql).

Almost everything that makes this feature safe is a constraint or a grant
rather than application code -- migration 20260913000000's header narrows
plan invariant 8 from "the phone cannot insert transactions" to "the phone
cannot insert *parser-derived* transactions", and the whole argument rests on
Postgres actually refusing the things it claims to refuse. Testing that in
Dart would test the app's own validation; these tests go at the database
directly, the way a stolen phone with a valid JWT would.

Requires a local Postgres; skipped if EXPENSE_TRACKER_TEST_DB_URL isn't set.
See test_sync_integration.py's docstring for the one-line docker command.
"""

from __future__ import annotations

import os
import uuid
from datetime import datetime, timedelta, timezone

import psycopg
import pytest

from expense_tracker.pipeline.reconcile import reconcile_and_record_gaps
from expense_tracker.store.supabase import PostgresStore

DB_URL = os.environ.get("EXPENSE_TRACKER_TEST_DB_URL")
pytestmark = pytest.mark.skipif(not DB_URL, reason="EXPENSE_TRACKER_TEST_DB_URL not set")

BASE = datetime(2026, 3, 1, 9, 0, tzinfo=timezone.utc)


@pytest.fixture
def conn():
    with psycopg.connect(DB_URL, autocommit=True) as c:
        yield c


@pytest.fixture
def user_id(conn) -> str:
    with conn.cursor() as cur:
        cur.execute(
            "truncate table transactions, processed_emails, accounts, sync_runs, "
            "transfer_groups, ledger_gaps, categories, merchant_rules, "
            "auth.users cascade"
        )
        uid = str(uuid.uuid4())
        cur.execute("insert into auth.users (id) values (%s)", (uid,))
    return uid


@pytest.fixture
def account_id(conn, user_id) -> str:
    with conn.cursor() as cur:
        cur.execute(
            "insert into accounts (user_id, kind, institution, mask, display_name) "
            "values (%s, 'BANK', 'NABIL', '001#####234567', 'Nabil') returning id",
            (user_id,),
        )
        return str(cur.fetchone()[0])


@pytest.fixture
def store():
    s = PostgresStore(DB_URL)
    yield s
    s.close()


def _parsed_txn(
    conn, user_id, account_id, *, minutes, direction, amount, balance, key
) -> str:
    """A transaction as a parser would write it: a real source message, a
    real parser_version, entry_source left at its 'PARSED' default.
    """
    with conn.cursor() as cur:
        message_id = f"<{key}@example.test>"
        cur.execute(
            "insert into processed_emails "
            "(message_id, user_id, received_at, from_addr, status, txn_count) "
            "values (%s, %s, %s, 'alerts@nabilbank.com', 'PARSED', 1)",
            (message_id, user_id, BASE),
        )
        cur.execute(
            """
            insert into transactions
                (user_id, account_id, source_message_id, occurred_at,
                 occurred_precision, direction, amount_paisa, balance_after_paisa,
                 description_raw, dedupe_key, parser_version)
            values (%s, %s, %s, %s, 'MINUTE', %s, %s, %s, %s, %s, 3)
            returning id
            """,
            (
                user_id, account_id, message_id, BASE + timedelta(minutes=minutes),
                direction, amount, balance, f"remarks {key}", f"nabil:{key}",
            ),
        )
        return str(cur.fetchone()[0])


def _as_phone(conn, user_id):
    """Run the next statements the way PostgREST runs them for a signed-in
    user: as `authenticated`, with auth.uid() returning this user.

    This is the part that makes these tests worth anything. As the superuser
    every insert below succeeds, because RLS and column grants are exactly
    what a superuser bypasses -- the refusals only appear from inside the
    role the phone actually holds.
    """
    with conn.cursor() as cur:
        cur.execute(
            "create or replace function auth.uid() returns uuid "
            f"language sql stable as $$ select '{user_id}'::uuid $$"
        )
        cur.execute("grant usage on schema public to authenticated")
        cur.execute("grant select on all tables in schema public to authenticated")
        cur.execute("set role authenticated")


def _as_owner(conn):
    with conn.cursor() as cur:
        cur.execute("reset role")


def _manual_insert(conn, user_id, account_id, **overrides):
    fields = {
        "user_id": user_id,
        "account_id": account_id,
        "occurred_at": BASE + timedelta(minutes=30),
        "occurred_precision": "MINUTE",
        "direction": "DEBIT",
        "amount_paisa": 40_00,
        "balance_after_paisa": None,
        "currency": "NPR",
        "description_raw": "Chiya at the corner shop",
        "status": "CONFIRMED",
        "dedupe_key": f"manual:{uuid.uuid4().hex}",
        "entry_source": "MANUAL",
    }
    fields.update(overrides)
    columns = ", ".join(fields)
    placeholders = ", ".join(["%s"] * len(fields))
    with conn.cursor() as cur:
        cur.execute(
            f"insert into transactions ({columns}) values ({placeholders}) returning id",
            tuple(fields.values()),
        )
        return str(cur.fetchone()[0])


# --------------------------------------------------------------------------
# What the phone is now allowed to do


def test_phone_can_insert_its_own_manual_entry(conn, user_id, account_id):
    _as_phone(conn, user_id)
    txn_id = _manual_insert(conn, user_id, account_id)
    _as_owner(conn)

    with conn.cursor() as cur:
        cur.execute(
            "select entry_source, parser_version, source_message_id, "
            "source_raw_message_id from transactions where id = %s",
            (txn_id,),
        )
        entry_source, parser_version, email_src, sms_src = cur.fetchone()

    assert entry_source == "MANUAL"
    # Not granted to the phone, so it takes the column default -- the point
    # being that a manual row cannot claim to have come out of a parser.
    assert parser_version == 0
    assert email_src is None and sms_src is None


# --------------------------------------------------------------------------
# ...and what it still cannot, which is the substance of the amended
# invariant. Each of these is refused by Postgres, not by the app.


def test_phone_cannot_insert_a_row_claiming_to_be_parsed(conn, user_id, account_id):
    _as_phone(conn, user_id)
    with pytest.raises(psycopg.errors.InsufficientPrivilege):
        # entry_source is granted, but the insert policy's with-check demands
        # 'MANUAL'; PostgREST surfaces the policy refusal as a permissions
        # error rather than a constraint one.
        _manual_insert(
            conn, user_id, account_id,
            entry_source="PARSED",
            dedupe_key=f"nabil:{uuid.uuid4().hex}",
        )
    _as_owner(conn)


def test_phone_cannot_forge_a_parser_version(conn, user_id, account_id):
    _as_phone(conn, user_id)
    with pytest.raises(psycopg.errors.InsufficientPrivilege):
        _manual_insert(conn, user_id, account_id, parser_version=3)
    _as_owner(conn)


def test_phone_cannot_attach_a_manual_row_to_a_source_message(conn, user_id, account_id):
    _as_owner(conn)
    # A real parsed row exists, so its message_id is a valid FK target --
    # the refusal has to come from the grant, not from a dangling reference.
    _parsed_txn(conn, user_id, account_id, minutes=0, direction="CREDIT",
                amount=100_00, balance=500_00, key="a")

    _as_phone(conn, user_id)
    with pytest.raises(psycopg.errors.InsufficientPrivilege):
        _manual_insert(conn, user_id, account_id, source_message_id="<a@example.test>")
    _as_owner(conn)


def test_phone_cannot_squat_on_a_parser_dedupe_key(conn, user_id, account_id):
    """The namespace constraint. Without it a manual entry could take the
    dedupe_key of a transaction whose email hasn't arrived yet, and the real
    one would be silently swallowed by ON CONFLICT DO NOTHING on the next
    sync -- a way to lose a genuine transaction forever.
    """
    _as_phone(conn, user_id)
    with pytest.raises(psycopg.errors.CheckViolation):
        _manual_insert(conn, user_id, account_id, dedupe_key="nabil:004:2026-03-01T09:30:DEBIT:4000:abcd1234")
    _as_owner(conn)


def test_phone_still_cannot_delete_a_transaction(conn, user_id, account_id):
    txn_id = _parsed_txn(conn, user_id, account_id, minutes=0, direction="CREDIT",
                         amount=100_00, balance=500_00, key="a")
    _as_phone(conn, user_id)
    with pytest.raises(psycopg.errors.InsufficientPrivilege):
        with conn.cursor() as cur:
            cur.execute("delete from transactions where id = %s", (txn_id,))
    _as_owner(conn)


def test_phone_still_cannot_change_an_amount(conn, user_id, account_id):
    """Including on a manual row it created itself. A mistyped entry is not
    editable from the app by design -- the column grants never mention
    amount_paisa, and 'it's my own row' is not an exception the grant can
    express."""
    _as_phone(conn, user_id)
    txn_id = _manual_insert(conn, user_id, account_id)
    with pytest.raises(psycopg.errors.InsufficientPrivilege):
        with conn.cursor() as cur:
            cur.execute("update transactions set amount_paisa = 1 where id = %s", (txn_id,))
    _as_owner(conn)


def test_phone_cannot_insert_an_entry_for_another_user(conn, user_id, account_id):
    _as_owner(conn)
    with conn.cursor() as cur:
        other = str(uuid.uuid4())
        cur.execute("insert into auth.users (id) values (%s)", (other,))

    _as_phone(conn, user_id)
    with pytest.raises(psycopg.errors.InsufficientPrivilege):
        _manual_insert(conn, other, account_id)
    _as_owner(conn)


def test_phone_can_close_a_gap_but_not_open_one(conn, user_id, account_id):
    t1 = _parsed_txn(conn, user_id, account_id, minutes=0, direction="CREDIT",
                     amount=100_00, balance=500_00, key="a")
    t2 = _parsed_txn(conn, user_id, account_id, minutes=60, direction="DEBIT",
                     amount=30_00, balance=430_00, key="b")
    with conn.cursor() as cur:
        cur.execute(
            "insert into ledger_gaps (user_id, account_id, after_txn_id, "
            "before_txn_id, missing_paisa) values (%s, %s, %s, %s, %s) returning id",
            (user_id, account_id, t1, t2, -40_00),
        )
        gap_id = str(cur.fetchone()[0])

    _as_phone(conn, user_id)
    with conn.cursor() as cur:
        cur.execute(
            "update ledger_gaps set resolved = true, resolved_by = 'DISMISSED' where id = %s",
            (gap_id,),
        )
    with pytest.raises(psycopg.errors.InsufficientPrivilege):
        with conn.cursor() as cur:
            cur.execute(
                "insert into ledger_gaps (user_id, account_id, after_txn_id, "
                "before_txn_id, missing_paisa) values (%s, %s, %s, %s, %s)",
                (user_id, account_id, t1, t2, -1),
            )
    _as_owner(conn)


# --------------------------------------------------------------------------
# End to end: the reconciler and a manual entry, against real SQL.


def test_a_manual_entry_closes_the_gap_it_fills(conn, user_id, account_id, store):
    """The whole feature in one test, and specifically the part the app can't
    verify on its own: that the balance the form computes is the balance that
    makes reconcile.py's chain close on the next run."""
    _parsed_txn(conn, user_id, account_id, minutes=0, direction="CREDIT",
                amount=100_00, balance=500_00, key="a")
    _parsed_txn(conn, user_id, account_id, minutes=120, direction="DEBIT",
                amount=30_00, balance=430_00, key="b")

    first = reconcile_and_record_gaps(store, user_id)
    assert first.new_gaps == 1, "a 40.00 debit is missing between the two"

    with conn.cursor() as cur:
        cur.execute("select missing_paisa from ledger_gaps where user_id = %s", (user_id,))
        (missing,) = cur.fetchone()
    assert missing == -40_00

    # What the form does: the amount the gap names, at a time inside the
    # window, carrying the balance chained forward from 500.00.
    _as_phone(conn, user_id)
    _manual_insert(
        conn, user_id, account_id,
        occurred_at=BASE + timedelta(minutes=60),
        direction="DEBIT",
        amount_paisa=40_00,
        balance_after_paisa=460_00,
    )
    _as_owner(conn)

    second = reconcile_and_record_gaps(store, user_id)
    assert second.new_gaps == 0
    assert second.resolved_gaps == 1

    with conn.cursor() as cur:
        cur.execute(
            "select resolved, resolved_by from ledger_gaps where user_id = %s", (user_id,)
        )
        resolved, resolved_by = cur.fetchone()
    assert resolved is True
    assert resolved_by == "RECONCILER"


def test_v_open_ledger_gaps_carries_what_the_form_needs(conn, user_id, account_id, store):
    _parsed_txn(conn, user_id, account_id, minutes=0, direction="CREDIT",
                amount=100_00, balance=500_00, key="a")
    _parsed_txn(conn, user_id, account_id, minutes=120, direction="DEBIT",
                amount=30_00, balance=430_00, key="b")
    reconcile_and_record_gaps(store, user_id)

    with conn.cursor() as cur:
        cur.execute(
            "select account_display_name, currency, missing_paisa, "
            "after_balance_paisa, after_occurred_at, before_occurred_at "
            "from v_open_ledger_gaps where user_id = %s",
            (user_id,),
        )
        row = cur.fetchone()

    name, currency, missing, after_balance, after_at, before_at = row
    assert name == "Nabil"
    assert currency == "NPR"
    assert missing == -40_00
    # The number the fill form chains forward from. Without it the app cannot
    # compute a balance, and an entry with no balance leaves the gap open.
    assert after_balance == 500_00
    assert before_at > after_at, "the window the entry must land inside"


def test_a_resolved_gap_leaves_the_open_view(conn, user_id, account_id, store):
    _parsed_txn(conn, user_id, account_id, minutes=0, direction="CREDIT",
                amount=100_00, balance=500_00, key="a")
    _parsed_txn(conn, user_id, account_id, minutes=120, direction="DEBIT",
                amount=30_00, balance=430_00, key="b")
    reconcile_and_record_gaps(store, user_id)

    with conn.cursor() as cur:
        cur.execute("select count(*) from v_open_ledger_gaps where user_id = %s", (user_id,))
        assert cur.fetchone()[0] == 1
        cur.execute("update ledger_gaps set resolved = true where user_id = %s", (user_id,))
        cur.execute("select count(*) from v_open_ledger_gaps where user_id = %s", (user_id,))
        assert cur.fetchone()[0] == 0
