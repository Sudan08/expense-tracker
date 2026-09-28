import logging
from datetime import timedelta
from expense_tracker.store.base import Store
from expense_tracker.parsers.base import NormalizedTxn

logger = logging.getLogger(__name__)

def audit_and_insert_missing(
    store: Store,
    user_id: str,
    txns: list[NormalizedTxn],
    raw_message_id: str
) -> int:
    """
    Takes parsed statement rows, compares them against existing transactions
    for the same account and date range, and inserts any that are missing.
    """
    if not txns:
        return 0
        
    inserted = 0
    
    # Group by account
    by_account = {}
    for t in txns:
        by_account.setdefault((t.institution, t.account_mask or ""), []).append(t)
        
    for (institution, mask), account_txns in by_account.items():
        if not account_txns:
            continue
            
        account_id = store.get_or_create_account(
            user_id, institution, mask or None,
            "BANK", account_txns[0].currency,
        )
        
        # Determine date range
        start_date = min(t.occurred_at for t in account_txns).replace(hour=0, minute=0, second=0)
        end_date = max(t.occurred_at for t in account_txns).replace(hour=23, minute=59, second=59)
        
        # Fetch existing txns
        existing_txns = store.fetch_transactions_in_range(user_id, account_id, start_date, end_date)
        
        missing_txns = []
        for st_txn in account_txns:
            # Try to find a match in existing txns
            matched = False
            for ex in existing_txns:
                # Match criteria: Same date, same amount, same direction
                if (ex.occurred_at.date() == st_txn.occurred_at.date() and
                    ex.amount_paisa == st_txn.amount_paisa and
                    ex.direction == st_txn.direction):
                    # It's a match!
                    matched = True
                    # Remove from pool to avoid double-matching if there are two identical transactions
                    existing_txns.remove(ex)
                    break
                    
            if not matched:
                missing_txns.append(st_txn)
                
        if missing_txns:
            logger.info(f"Statement audit found {len(missing_txns)} missing transactions for account {mask}")
            inserted += store.upsert_transactions(
                user_id, account_id, missing_txns, source_raw_message_id=raw_message_id
            )
            
    return inserted
