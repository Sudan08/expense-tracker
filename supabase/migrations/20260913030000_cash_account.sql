-- A Cash account, so physical spending can be recorded at all.
--
-- Manual entries (migration 20260913000000) need an account to file against,
-- and every account that exists is one the worker created the first time a
-- parser saw a transaction from it. Cash is the one kind of spending no
-- parser will ever see: there is no email, no SMS, and no statement. It is
-- also the single most common thing a person would want to type in by hand,
-- so the manual-entry form shipped without the account its main use case
-- needs.
--
-- ------------------------------------------------------------- why WALLET
--
-- account_kind is ('BANK', 'WALLET') and cash is, literally, a wallet.
-- Adding a third 'CASH' value was the first instinct and is not worth it:
--
--   * Nothing branches on kind. The only behavioural difference between a
--     bank and a wallet in this codebase is whether rows carry
--     balance_after_paisa, which drives reconcile.py -- and it reads the
--     column, not the kind. Cash entries carry no balance (see
--     ManualEntryDraft.balanceAfterPaisa), so they are correctly skipped by
--     the reconciler exactly the way eSewa's are. A 'CASH' value would be a
--     label with no behaviour attached.
--   * `alter type ... add value` cannot be used in the same transaction that
--     adds it ("unsafe use of new value of enum type"), and every migration
--     here runs as one transaction. It would need splitting across two
--     files to buy that label.
--
-- The name the user actually sees is display_name, which says 'Cash'.

insert into accounts (user_id, kind, institution, mask, display_name, currency)
select distinct c.user_id, 'WALLET'::account_kind, 'CASH', '', 'Cash', 'NPR'
from categories c
on conflict (user_id, institution, mask) do nothing;
