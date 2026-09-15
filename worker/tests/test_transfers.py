"""find_matches against the section 7.2 scoring rules. The auto-link case
uses the real eSewa Aug 31 fixture (worker/tests/fixtures/emails/esewa/
esewa_fund_load_2026-08-31.eml, NPR 1,000, ref 1PWB11H) as the CREDIT leg --
that email is real. Its Nabil DEBIT counterpart is NOT: as of this Phase 3
work, no matching Nabil txn-alert exists in the mailbox yet (checked via
Gmail search) -- a live example of the section 7.3 "missing email" scenario.
The DEBIT leg here is constructed to match the plan's own description of
that pair (section 7.2's worked example), not lifted from a real fixture.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from expense_tracker.pipeline.transfers import TransferCandidate, find_matches

ESEWA_CREDIT = TransferCandidate(
    id="esewa-credit-1",
    account_id="esewa-wallet",
    institution="ESEWA",
    direction="CREDIT",
    amount_paisa=100_000,  # NPR 1,000.00, real fixture value
    occurred_at=datetime(2026, 8, 31, 9, 45, 53, tzinfo=timezone.utc),
    description_raw="NABIL BANK LTD.",  # real fixture value
    counterparty="NABIL BANK LTD.",
)


def test_matching_pair_within_five_minutes_naming_the_other_bank_auto_links():
    nabil_debit = TransferCandidate(
        id="nabil-debit-1",
        account_id="nabil-001234567",
        institution="NABIL",
        direction="DEBIT",
        amount_paisa=100_000,
        occurred_at=ESEWA_CREDIT.occurred_at + timedelta(minutes=2),
        description_raw="ESW DLA:TESTCODE",
        counterparty=None,
    )
    matches = find_matches([ESEWA_CREDIT, nabil_debit])
    assert len(matches) == 1
    match = matches[0]
    # 0.5 base + 0.3 (eSewa's own row literally says "NABIL BANK LTD.") + 0.2 (< 5 min) = 1.0
    assert match.confidence == 1.0
    assert match.auto_link is True


def test_matching_pair_with_no_institution_mention_and_wider_gap_goes_to_review():
    # A synthetic credit whose text doesn't name the other side's institution
    # -- unlike a real esewa.fund_load row, whose description_raw is always
    # the source bank's name (section 8.2), so the institution-mention bonus
    # fires for essentially every real esewa.fund_load pair by construction.
    generic_credit = TransferCandidate(
        id="generic-credit-1",
        account_id="some-other-account",
        institution="ESEWA",
        direction="CREDIT",
        amount_paisa=100_000,
        occurred_at=datetime(2026, 1, 1, 12, 0, 0, tzinfo=timezone.utc),
        description_raw="Fund received",
        counterparty=None,
    )
    debit = TransferCandidate(
        id="nabil-debit-2",
        account_id="nabil-001234567",
        institution="NABIL",
        direction="DEBIT",
        amount_paisa=100_000,
        occurred_at=generic_credit.occurred_at + timedelta(minutes=20),  # > 5 min, <= 30 min
        description_raw="ESW DLA:TESTCODE",  # doesn't name ESEWA either
        counterparty=None,
    )
    matches = find_matches([generic_credit, debit])
    assert len(matches) == 1
    match = matches[0]
    assert match.confidence == 0.5  # base only
    assert match.auto_link is False


def test_pair_more_than_thirty_minutes_apart_is_not_a_candidate_at_all():
    nabil_debit = TransferCandidate(
        id="nabil-debit-3",
        account_id="nabil-001234567",
        institution="NABIL",
        direction="DEBIT",
        amount_paisa=100_000,
        occurred_at=ESEWA_CREDIT.occurred_at + timedelta(minutes=31),
        description_raw="NABIL BANK LTD.",
        counterparty=None,
    )
    assert find_matches([ESEWA_CREDIT, nabil_debit]) == []


def test_same_account_never_pairs_with_itself():
    same_account_credit = TransferCandidate(
        id="c2",
        account_id="esewa-wallet",
        institution="ESEWA",
        direction="CREDIT",
        amount_paisa=100_000,
        occurred_at=ESEWA_CREDIT.occurred_at,
        description_raw="internal",
    )
    debit = TransferCandidate(
        id="d1",
        account_id="esewa-wallet",  # same account as the credit
        institution="ESEWA",
        direction="DEBIT",
        amount_paisa=100_000,
        occurred_at=ESEWA_CREDIT.occurred_at,
        description_raw="internal",
    )
    assert find_matches([same_account_credit, debit]) == []


def test_ambiguous_multiple_candidates_get_penalized_on_both_sides():
    # One NABIL debit that matches two different eSewa credits of the same
    # amount within the window -- neither pairing should be trusted blindly.
    base_time = datetime(2026, 1, 1, 12, 0, 0, tzinfo=timezone.utc)
    debit = TransferCandidate(
        id="d1", account_id="nabil", institution="NABIL", direction="DEBIT",
        amount_paisa=50_000, occurred_at=base_time, description_raw="NABIL BANK LTD.",
    )
    credit_a = TransferCandidate(
        id="ca", account_id="esewa", institution="ESEWA", direction="CREDIT",
        amount_paisa=50_000, occurred_at=base_time + timedelta(minutes=1),
        description_raw="NABIL BANK LTD.",
    )
    credit_b = TransferCandidate(
        id="cb", account_id="esewa", institution="ESEWA", direction="CREDIT",
        amount_paisa=50_000, occurred_at=base_time + timedelta(minutes=2),
        description_raw="NABIL BANK LTD.",
    )
    matches = find_matches([debit, credit_a, credit_b])
    assert len(matches) == 2
    for match in matches:
        # 0.5 + 0.3 (names institution) + 0.2 (< 5 min) - 0.3 (ambiguous) = 0.7
        assert match.confidence == 0.7
        assert match.auto_link is False


def test_real_esewa_load_debits_without_a_matching_credit_never_match():
    """Two real Nabil debits from Phase 0 ('eSewa Load 9800000003, ...' and
    'eSewa Load 9800000002, ...') looked at first glance like Nabil-side
    halves of eSewa wallet top-ups. But the phone numbers in those remarks
    (9800000003, 9800000002) aren't the account owner's own eSewa ID
    (9800000001, confirmed via a separate real 'Notification ID
    Verification' email) -- these are loads to someone else's wallet, i.e.
    real spending, not a self-transfer. The matcher shouldn't need to know
    that distinction explicitly: since no eSewa-side CREDIT transaction
    exists for either of these in the current data, they correctly produce
    zero candidate pairs regardless.
    """
    base_time = datetime(2026, 5, 18, 19, 9, tzinfo=timezone.utc)
    debit_may18 = TransferCandidate(
        id="nabil-may18", account_id="nabil-001234567", institution="NABIL",
        direction="DEBIT", amount_paisa=300_000, occurred_at=base_time,
        description_raw="eSewa Load 9800000003, 261277999",
    )
    debit_apr17 = TransferCandidate(
        id="nabil-apr17", account_id="nabil-001234567", institution="NABIL",
        direction="DEBIT", amount_paisa=65_000,
        occurred_at=datetime(2026, 4, 17, 13, 29, tzinfo=timezone.utc),
        description_raw="eSewa Load 9800000002, 249135736",
    )
    # Only the one real eSewa credit in the whole corpus, unrelated amount/date.
    assert find_matches([debit_may18, debit_apr17, ESEWA_CREDIT]) == []
