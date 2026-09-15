"""find_gaps against real Nabil balance data from the Phase 0 fixture corpus
(worker/tests/fixtures/expected.yaml) -- these 25 emails were deliberately
sampled spread across ~6 months out of ~200 real messages (see the fork
report from Phase 0), so essentially no two are chronologically adjacent in
the real account history. That makes them a genuine real-data test of gap
*detection*: the reconciler should find a gap between nearly every
consecutive pair. The exact-arithmetic and no-gap cases use small synthetic
chains instead, since Phase 0 didn't capture a verified-adjacent real
sequence.
"""

from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path

import yaml

from expense_tracker.pipeline.reconcile import (
    BalanceRow,
    ReconcileResult,
    find_gaps,
    reconcile_and_record_gaps,
)

FIXTURES_DIR = Path(__file__).parent / "fixtures"
EXPECTED = yaml.safe_load((FIXTURES_DIR / "expected.yaml").read_text())

ACCOUNT_ID = "001#####234567"


def _real_nabil_txn_alert_rows() -> list[BalanceRow]:
    rows = []
    for rel_path, fields in EXPECTED.items():
        if fields.get("template_key") != "nabil.txn_alert":
            continue
        rows.append(
            BalanceRow(
                id=rel_path,
                account_id=ACCOUNT_ID,
                occurred_at=datetime.fromisoformat(fields["occurred_at"]),
                direction=fields["direction"],
                amount_paisa=fields["amount_paisa"],
                balance_after_paisa=fields["balance_after_paisa"],
            )
        )
    rows.sort(key=lambda r: r.occurred_at)
    return rows


def test_real_sparse_sample_mostly_shows_gaps_between_consecutive_pairs():
    rows = _real_nabil_txn_alert_rows()
    assert len(rows) == 25

    gaps = find_gaps(rows)
    # These 25 were deliberately spread across ~200 real emails (Phase 0),
    # so most consecutive pairs aren't truly adjacent in the real account
    # history and should register as gaps. 19 of the 24 consecutive pairs
    # do (the other 5 landing on genuinely quiet stretches with no other
    # real transaction in between is itself a real, useful signal -- not a
    # reconciler bug).
    assert len(gaps) == 19
    assert all(g.missing_paisa != 0 for g in gaps)


def test_first_real_gap_matches_hand_computed_value():
    # Feb 25 (DEBIT 500, balance_after 115054974) -> Mar 15 (DEBIT 2500000,
    # balance_after 112329474). expected = 115054974 - 2500000 = 112554974.
    # missing = 112329474 - 112554974 = -225500 (NPR -2,255.00), computed by
    # hand from the real fixture values, independent of reconcile.py's formula.
    rows = _real_nabil_txn_alert_rows()
    gaps = find_gaps(rows)
    first = gaps[0]
    assert first.after_txn_id == "nabil/nabil_txn_alert_2026-02-25_19c942.eml"
    assert first.before_txn_id == "nabil/nabil_txn_alert_2026-03-15_19cf0d.eml"
    assert first.missing_paisa == -225500


def test_clean_synthetic_chain_reports_no_gaps():
    base = datetime(2026, 1, 1, tzinfo=timezone.utc)
    rows = [
        BalanceRow("t1", "acct", base, "CREDIT", 100_00, 500_00),
        BalanceRow("t2", "acct", base, "DEBIT", 30_00, 470_00),
        BalanceRow("t3", "acct", base, "DEBIT", 20_00, 450_00),
        BalanceRow("t4", "acct", base, "CREDIT", 1000_00, 1450_00),
    ]
    assert find_gaps(rows) == []


def test_esewa_rows_with_no_balance_are_skipped_not_treated_as_gaps():
    base = datetime(2026, 1, 1, tzinfo=timezone.utc)
    rows = [
        BalanceRow("t1", "bank", base, "CREDIT", 100_00, 500_00),
        BalanceRow("wallet1", "esewa", base, "CREDIT", 50_00, None),  # no balance
        BalanceRow("t2", "bank", base, "DEBIT", 30_00, 470_00),
    ]
    assert find_gaps(rows) == []


def test_single_missing_transaction_reports_the_exact_shortfall():
    base = datetime(2026, 1, 1, tzinfo=timezone.utc)
    rows = [
        BalanceRow("t1", "acct", base, "CREDIT", 100_00, 500_00),
        # a DEBIT of 40_00 happened here but its email never arrived
        BalanceRow("t2", "acct", base, "DEBIT", 30_00, 430_00),
    ]
    gaps = find_gaps(rows)
    assert len(gaps) == 1
    assert gaps[0].missing_paisa == -40_00


# --------------------------------------------------------------------------
# reconcile_and_record_gaps: recording is only half of it. Nothing ever set
# ledger_gaps.resolved before -- a gap stayed open forever even once the
# missing transaction turned up. These cover the closing half, including the
# case the app depends on: a MANUAL entry inserted between the two rows a
# gap names, carrying the balance that makes the chain reconcile.


class _RecordingStore:
    """Just enough Store for reconcile_and_record_gaps."""

    def __init__(self, rows_by_account, open_gaps=()):
        self._rows = rows_by_account
        # (account_id, after_txn_id, before_txn_id) currently unresolved.
        self.open_gaps = set(open_gaps)
        self.resolved: set = set()

    def fetch_balance_rows_by_account(self, user_id):
        return self._rows

    def insert_ledger_gap(self, user_id, gap):
        key = (gap.account_id, gap.after_txn_id, gap.before_txn_id)
        if key in self.open_gaps:
            return False
        self.open_gaps.add(key)
        return True

    def resolve_gaps_absent_from(self, user_id, detected):
        stale = self.open_gaps - set(detected)
        self.open_gaps -= stale
        self.resolved |= stale
        return len(stale)


def test_filling_a_gap_with_a_manual_entry_closes_it():
    base = datetime(2026, 1, 1, tzinfo=timezone.utc)
    gap_key = ("acct", "t1", "t2")

    # Before: a 40.00 DEBIT is missing between t1 and t2, and that gap is
    # already on file from an earlier run.
    store = _RecordingStore(
        {
            "acct": [
                BalanceRow("t1", "acct", base, "CREDIT", 100_00, 500_00),
                # the user checks the bank app and adds exactly what was
                # missing, with the balance it left behind (500_00 - 40_00)
                BalanceRow("m1", "acct", base.replace(hour=1), "DEBIT", 40_00, 460_00),
                BalanceRow("t2", "acct", base.replace(hour=2), "DEBIT", 30_00, 430_00),
            ]
        },
        open_gaps=[gap_key],
    )

    result = reconcile_and_record_gaps(store, "user")

    assert result.new_gaps == 0
    assert result.resolved_gaps == 1
    assert store.resolved == {gap_key}
    assert store.open_gaps == set()


def test_a_wrong_manual_amount_narrows_the_gap_rather_than_hiding_it():
    """The safety property behind letting the phone write these rows at all:
    an entry with the wrong amount still dissolves the original pair, but the
    two new pairs around it don't reconcile, so the run records those. A bad
    answer becomes a smaller question, never a silently closed one."""
    base = datetime(2026, 1, 1, tzinfo=timezone.utc)
    original = ("acct", "t1", "t2")

    store = _RecordingStore(
        {
            "acct": [
                BalanceRow("t1", "acct", base, "CREDIT", 100_00, 500_00),
                # 40_00 was missing; the user typed 25_00 and a balance to match
                BalanceRow("m1", "acct", base.replace(hour=1), "DEBIT", 25_00, 475_00),
                BalanceRow("t2", "acct", base.replace(hour=2), "DEBIT", 30_00, 430_00),
            ]
        },
        open_gaps=[original],
    )

    result = reconcile_and_record_gaps(store, "user")

    assert store.resolved == {original}, "the original pair is no longer consecutive"
    assert result.new_gaps == 1
    assert store.open_gaps == {("acct", "m1", "t2")}, "the remaining 15.00 is still asked about"


def test_a_gap_that_is_still_a_gap_is_neither_reinserted_nor_resolved():
    base = datetime(2026, 1, 1, tzinfo=timezone.utc)
    gap_key = ("acct", "t1", "t2")
    store = _RecordingStore(
        {
            "acct": [
                BalanceRow("t1", "acct", base, "CREDIT", 100_00, 500_00),
                BalanceRow("t2", "acct", base.replace(hour=2), "DEBIT", 30_00, 430_00),
            ]
        },
        open_gaps=[gap_key],
    )

    result = reconcile_and_record_gaps(store, "user")

    assert result == ReconcileResult(new_gaps=0, resolved_gaps=0)
    assert store.open_gaps == {gap_key}
