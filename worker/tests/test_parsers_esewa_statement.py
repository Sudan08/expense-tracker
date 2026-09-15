"""esewa.statement_row -- the eSewa 'Statement' .xls export, staged whole as
a single raw_messages row and parsed here. See
parsers/esewa_statement.py's module docstring for why this exists: eSewa
sends no email or SMS at all for a wallet-to-wallet transfer, so the
statement export is the only source for that transaction type, and the
only one that carries a running balance for eSewa at all.

normalize_row (the StatementRow -> NormalizedTxn mapping) is tested
directly with hand-built rows -- no xlrd, no file, no base64 -- the same
"pure and offline" split every other parser keeps. EsewaStatementFileParser
itself (base64 decode -> xlrd -> normalize_row) is exercised separately in
test_ingest_esewa_statement_file.py against a real in-memory workbook.
"""

from __future__ import annotations

import pytest

from expense_tracker.ingest.esewa_statement_file import StatementRow
from expense_tracker.parsers.esewa_statement import normalize_row


def _row(**overrides) -> StatementRow:
    fields = dict(
        reference="1R1G2EC",
        datetime_str="2026-09-14 13:40:57.0",
        description="Fund Transferred to Test Person",
        dr="370.0",
        cr="0.0",
        balance="4544.77",
        channel="App",
    )
    fields.update(overrides)
    return StatementRow(**fields)


def test_p2p_transfer_out_is_a_debit_with_balance_and_counterparty():
    txn = normalize_row(_row(), message_id="hash-1")

    assert txn.institution == "ESEWA"
    assert txn.direction == "DEBIT"
    assert txn.amount_paisa == 37_000
    assert txn.balance_after_paisa == 454_477
    assert txn.occurred_precision == "SECOND"
    assert txn.occurred_at.isoformat() == "2026-09-14T13:40:57+05:45"
    assert txn.reference == "1R1G2EC"
    assert txn.dedupe_key == "esewa:1R1G2EC"
    # Same scheme esewa.py's email templates use -- a later-arriving email
    # for the same transaction collides on this key rather than duplicating.
    assert txn.counterparty == "Test Person"
    assert txn.channel == "WALLET_TRANSFER"
    assert txn.message_id == "hash-1"


def test_p2p_transfer_in_is_a_credit():
    txn = normalize_row(
        _row(description="Fund Transferred by Someone Else", dr="0.0", cr="320.0"),
        message_id="hash-1",
    )
    assert txn.direction == "CREDIT"
    assert txn.amount_paisa == 32_000
    assert txn.counterparty == "Someone Else"
    assert txn.channel == "WALLET_TRANSFER"


def test_bank_fund_load_is_recognised_as_wallet_load():
    txn = normalize_row(
        _row(description="Money transferred from NABIL BANK LTD.", dr="0.0", cr="185.0"),
        message_id="hash-1",
    )
    assert txn.direction == "CREDIT"
    assert txn.counterparty == "NABIL BANK LTD."
    assert txn.channel == "WALLET_LOAD"


def test_merchant_payment_is_recognised_as_wallet_payment():
    txn = normalize_row(
        _row(description="Paid for Daraz Kaymu Private Limited", dr="999.0", cr="0.0"),
        message_id="hash-1",
    )
    assert txn.direction == "DEBIT"
    assert txn.counterparty == "Daraz Kaymu Private Limited"
    assert txn.channel == "WALLET_PAYMENT"


def test_bill_split_is_not_swallowed_by_the_plainer_paid_to_pattern():
    txn = normalize_row(
        _row(description="Paid For Bill Split to Bikash Sharma", dr="136.0", cr="0.0"),
        message_id="hash-1",
    )
    assert txn.counterparty == "Bikash Sharma"
    assert txn.channel == "WALLET_PAYMENT"


def test_unrecognised_description_still_parses_with_no_guess():
    txn = normalize_row(
        _row(description="Some New Shape Nobody Has Seen", dr="10.0", cr="0.0"),
        message_id="hash-1",
    )
    assert txn.counterparty is None
    assert txn.channel is None
    assert txn.amount_paisa == 1_000  # amount/direction still correct


def test_ambiguous_dr_and_cr_both_nonzero_is_rejected():
    with pytest.raises(ValueError, match="ambiguous"):
        normalize_row(_row(dr="10.0", cr="10.0"), message_id="hash-1")


def test_neither_dr_nor_cr_nonzero_is_rejected():
    with pytest.raises(ValueError, match="ambiguous"):
        normalize_row(_row(dr="0.0", cr="0.0"), message_id="hash-1")
