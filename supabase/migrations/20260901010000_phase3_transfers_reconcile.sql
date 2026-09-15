-- Phase 3: transfer matching and balance reconciliation need no new tables
-- (transfer_groups + transactions.transfer_group_id already cover matching;
-- ledger_gaps already covers gap reporting) -- just one constraint the
-- original schema was missing.
--
-- section 6.1 step 8 runs the balance reconciler on every sync. Without a
-- uniqueness guard, an unresolved gap that's still there tomorrow (the
-- missing email still hasn't arrived) gets a fresh ledger_gaps row inserted
-- every single day, which breaks invariant 5 (idempotent by DB constraint).

alter table ledger_gaps
    add constraint ledger_gaps_unique_pair unique (account_id, after_txn_id, before_txn_id);
