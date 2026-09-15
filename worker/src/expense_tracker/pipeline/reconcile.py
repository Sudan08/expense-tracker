"""Balance reconciliation. Pure and offline. See
docs/EXPENSE_TRACKER_PLAN.md section 7.3.

Per bank account, ordered by time, over consecutive rows that both carry a
balance:

    expected = prev.balance_after_paisa + (curr.direction = CREDIT ? +amt : -amt)
    if expected != curr.balance_after_paisa:
        -> a transaction is missing; the gap is exactly (curr.balance_after - expected)

eSewa carries no balance, so wallet accounts don't get this -- rows with
balance_after_paisa = None are skipped rather than treated as a break in the
chain.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    # Deferred import: store/base.py imports BalanceRow/LedgerGap from this
    # module, so importing Store here at module level would be circular.
    from expense_tracker.store.base import Store


@dataclass(frozen=True)
class BalanceRow:
    id: str
    account_id: str
    occurred_at: datetime
    direction: str  # 'DEBIT' | 'CREDIT'
    amount_paisa: int
    balance_after_paisa: int | None


@dataclass(frozen=True)
class LedgerGap:
    account_id: str
    after_txn_id: str
    before_txn_id: str
    missing_paisa: int  # signed


def find_gaps(rows: list[BalanceRow]) -> list[LedgerGap]:
    """`rows` must already be filtered to a single account and sorted by
    occurred_at -- the caller (section 6.1 step 8) does this per account.
    """
    gaps: list[LedgerGap] = []
    prev: BalanceRow | None = None

    for row in rows:
        if row.balance_after_paisa is None:
            continue
        if prev is not None:
            delta = row.amount_paisa if row.direction == "CREDIT" else -row.amount_paisa
            expected = prev.balance_after_paisa + delta
            if expected != row.balance_after_paisa:
                gaps.append(
                    LedgerGap(
                        account_id=row.account_id,
                        after_txn_id=prev.id,
                        before_txn_id=row.id,
                        missing_paisa=row.balance_after_paisa - expected,
                    )
                )
        prev = row

    return gaps


@dataclass(frozen=True)
class ReconcileResult:
    new_gaps: int
    resolved_gaps: int


def reconcile_and_record_gaps(store: "Store", user_id: str) -> ReconcileResult:
    """Section 6.1 step 8, per bank account.

    Two halves, and the second one is why this returns a pair rather than a
    count. Recording a gap was always idempotent (insert_ledger_gap is a
    no-op for a gap already on file -- see the migration adding
    ledger_gaps_unique_pair), but nothing ever *closed* one: `resolved` was
    written by no code path at all, so a gap stayed open forever even after
    the transaction it was about turned up.

    Now the detected set is treated as the authority. An open row whose pair
    is no longer a gap is resolved, which covers both of the ways that
    happens:

      * the missing email finally arrived and a parser filled it in, or
      * the user filled it by hand in the app, which inserts a MANUAL
        transaction *between* after_txn and before_txn carrying the balance
        the chain needs -- so the pair stops being consecutive and stops
        being a gap.

    The second case is why the app doesn't have to get the bookkeeping
    exactly right for the ledger to stay honest: if the amount entered was
    wrong, the pair still reconciles away but the two *new* pairs around the
    manual row don't, and the next run records those instead. A wrong answer
    turns into a smaller, more specific question rather than a silently
    closed one.
    """
    by_account = store.fetch_balance_rows_by_account(user_id)

    detected: list[LedgerGap] = []
    for rows in by_account.values():
        detected.extend(find_gaps(rows))

    new_gaps = sum(1 for gap in detected if store.insert_ledger_gap(user_id, gap))
    resolved = store.resolve_gaps_absent_from(
        user_id, [(g.account_id, g.after_txn_id, g.before_txn_id) for g in detected]
    )
    return ReconcileResult(new_gaps=new_gaps, resolved_gaps=resolved)
