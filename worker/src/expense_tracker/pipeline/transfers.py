"""Transfer matching. Pure and offline -- operates on already-stored
transaction rows, no DB access. See docs/EXPENSE_TRACKER_PLAN.md section 7.2.

candidate pair (A, B) where
    A.direction = DEBIT  and  B.direction = CREDIT
    A.amount_paisa = B.amount_paisa
    A.account_id  != B.account_id
    |A.occurred_at - B.occurred_at| <= 30 min

Score it, don't just accept it:
    +0.5 base for a candidate pair
    +0.3 if either side's text names the other's institution
    +0.2 if the gap is under 5 minutes
    -0.3 if more than one candidate matches

>= 0.8 auto-links (transactions.excluded_from_spend = true on both legs).
Below that still creates a transfer_groups row (confidence stored, both legs'
transfer_group_id set) but leaves excluded_from_spend false -- that's the
review queue: a UI can find review candidates as "has a transfer_group_id but
excluded_from_spend is still false and confirmed_by_user is still false".
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    # Deferred import: store/base.py imports TransferCandidate from this
    # module, so importing Store here at module level would be circular.
    from expense_tracker.store.base import Store

MAX_GAP_SECONDS = 30 * 60
TIGHT_GAP_SECONDS = 5 * 60
AUTO_LINK_THRESHOLD = 0.8

_INSTITUTION_NAMES = {"NABIL": "nabil", "ESEWA": "esewa"}


@dataclass(frozen=True)
class TransferCandidate:
    id: str
    account_id: str
    institution: str  # 'NABIL' | 'ESEWA'
    direction: str  # 'DEBIT' | 'CREDIT'
    amount_paisa: int
    occurred_at: datetime
    description_raw: str
    counterparty: str | None = None


@dataclass(frozen=True)
class TransferMatch:
    debit: TransferCandidate
    credit: TransferCandidate
    confidence: float
    auto_link: bool


def _mentions_institution(candidate: TransferCandidate, other_institution: str) -> bool:
    name = _INSTITUTION_NAMES[other_institution]
    haystacks = [candidate.description_raw, candidate.counterparty or ""]
    return any(name in h.lower() for h in haystacks)


def _score(debit: TransferCandidate, credit: TransferCandidate, ambiguous: bool) -> float:
    score = 0.5
    if _mentions_institution(debit, credit.institution) or _mentions_institution(
        credit, debit.institution
    ):
        score += 0.3
    gap_seconds = abs((debit.occurred_at - credit.occurred_at).total_seconds())
    if gap_seconds <= TIGHT_GAP_SECONDS:
        score += 0.2
    if ambiguous:
        score -= 0.3
    return round(score, 3)


def find_matches(candidates: list[TransferCandidate]) -> list[TransferMatch]:
    debits = [c for c in candidates if c.direction == "DEBIT"]
    credits = [c for c in candidates if c.direction == "CREDIT"]

    raw_pairs: list[tuple[TransferCandidate, TransferCandidate]] = []
    for debit in debits:
        for credit in credits:
            if debit.account_id == credit.account_id:
                continue
            if debit.amount_paisa != credit.amount_paisa:
                continue
            gap_seconds = abs((debit.occurred_at - credit.occurred_at).total_seconds())
            if gap_seconds > MAX_GAP_SECONDS:
                continue
            raw_pairs.append((debit, credit))

    debit_hits: dict[str, int] = {}
    credit_hits: dict[str, int] = {}
    for debit, credit in raw_pairs:
        debit_hits[debit.id] = debit_hits.get(debit.id, 0) + 1
        credit_hits[credit.id] = credit_hits.get(credit.id, 0) + 1

    matches = []
    for debit, credit in raw_pairs:
        ambiguous = debit_hits[debit.id] > 1 or credit_hits[credit.id] > 1
        confidence = _score(debit, credit, ambiguous)
        matches.append(
            TransferMatch(
                debit=debit,
                credit=credit,
                confidence=confidence,
                auto_link=confidence >= AUTO_LINK_THRESHOLD,
            )
        )
    return matches


def match_and_link_transfers(store: "Store", user_id: str, window_days: int = 60) -> int:
    """Section 6.1 step 7. Fetches ungrouped transactions from the last
    `window_days`, scores candidate pairs, and persists every match found
    (auto-linked ones excluded from spend immediately, the rest left for
    review -- see the module docstring). Returns the number of pairs matched.
    """
    since = datetime.now(timezone.utc) - timedelta(days=window_days)
    candidates = store.fetch_transfer_candidates(user_id, since)
    matches = find_matches(candidates)

    for match in matches:
        transfer_group_id = store.create_transfer_group(user_id, match.confidence)
        store.link_transfer_leg(transfer_group_id, match.debit.id, match.auto_link)
        store.link_transfer_leg(transfer_group_id, match.credit.id, match.auto_link)

    return len(matches)
