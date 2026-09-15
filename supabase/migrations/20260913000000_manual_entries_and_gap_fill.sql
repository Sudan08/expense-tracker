-- Manual entries, and filling a ledger gap by hand.
--
-- ---------------------------------------------------------------------------
-- Amendment to invariant 8
-- ---------------------------------------------------------------------------
-- Plan section 2 invariant 8 reads "the phone never writes financial facts.
-- It can recategorize, confirm, and attach its own note. It cannot insert or
-- delete transactions."
--
-- That was the right rule when every row in the ledger came from a parser: it
-- kept the phone from inventing a fact the bank never stated. But it also
-- means the ledger can only ever be as complete as the senders it listens to,
-- and section 7.3's balance reconciler exists precisely because it isn't --
-- ledger_gaps is a list of transactions the bank definitely made and the
-- pipeline definitively never saw. Before this migration the only thing the
-- app could do with that list was display it.
--
-- The invariant is narrowed rather than dropped:
--
--     The phone never writes PARSER-DERIVED facts. It may record its own
--     assertions, which are labelled entry_source = 'MANUAL', can never
--     claim a source message or a parser version, and are never touched by
--     a reparse.
--
-- Everything that made the original rule worth having survives, because the
-- separation is enforced by the database rather than by the app:
--
--   * a MANUAL row cannot reference a processed_emails or raw_messages row
--     (transactions_source_shape), so it can never be mistaken for something
--     a parser produced;
--   * a MANUAL row's parser_version is pinned to 0 and the column is not
--     granted to `authenticated`, so the phone cannot forge provenance;
--   * a MANUAL row's dedupe_key must start with 'manual:', which no parser
--     emits (they use 'nabil:' / 'esewa:'), so a manual entry can never
--     occupy the dedupe slot of a real transaction still to arrive;
--   * `authenticated` still has NO delete on transactions, and still cannot
--     UPDATE amount, date, or direction on any row -- manual ones included.
--     A mistyped manual entry is corrected the same way a mistyped anything
--     is: by the worker, or not at all.
--
-- This is a real widening of what a stolen phone can do: it can now add
-- plausible-looking rows to the ledger. It cannot alter or remove a single
-- existing one, which is the property that actually protects the history.

alter table transactions
    add column entry_source text not null default 'PARSED'
        check (entry_source in ('PARSED', 'MANUAL'));

comment on column transactions.entry_source is
    'PARSED: produced by a parser from an email or SMS. MANUAL: asserted by '
    'the user in the app, typically to fill a ledger_gaps row. A reparse '
    'never touches a MANUAL row -- it has no source message to reparse.';

-- ------------------------------------------------------------ provenance shape
-- Migration 20260908010000 required exactly one of the two source columns.
-- A manual entry legitimately has neither, so the rule becomes conditional
-- on entry_source rather than being relaxed for everybody.
alter table transactions
    drop constraint transactions_exactly_one_source;

alter table transactions
    add constraint transactions_source_shape check (
        case entry_source
            when 'MANUAL' then num_nonnulls(source_message_id, source_raw_message_id) = 0
            else               num_nonnulls(source_message_id, source_raw_message_id) = 1
        end
    );

-- A manual entry has no parser, so it cannot carry a parser version. The
-- default is what makes this work without granting the column to the phone:
-- the insert simply omits it. The worker always passes one explicitly.
alter table transactions
    alter column parser_version set default 0;

alter table transactions
    add constraint transactions_manual_has_no_parser_version
        check (entry_source <> 'MANUAL' or parser_version = 0);

-- Namespaced so a manual entry can never collide with, and thereby suppress,
-- a parsed transaction that hasn't arrived yet. See the header.
alter table transactions
    add constraint transactions_manual_dedupe_namespace
        check (
            case entry_source
                when 'MANUAL' then dedupe_key like 'manual:%'
                else               dedupe_key not like 'manual:%'
            end
        );

-- ------------------------------------------------------------ gap resolution
-- Which manual entry closed a gap, and when. resolved has existed since the
-- initial schema but nothing ever set it -- a gap, once detected, stayed open
-- forever even after the missing transaction turned up.
alter table ledger_gaps
    add column resolved_at    timestamptz,
    add column resolved_by    text
        check (resolved_by is null or resolved_by in ('MANUAL_ENTRY', 'RECONCILER', 'DISMISSED')),
    add column resolution_note text
        check (resolution_note is null or length(resolution_note) <= 500);

comment on column ledger_gaps.resolved_by is
    'MANUAL_ENTRY: the user filled it in the app. RECONCILER: the balance '
    'chain closed on its own, because the missing email finally arrived or '
    'a manual entry completed the run. DISMISSED: the user chose to stop '
    'being asked about it.';

-- ------------------------------------------------------------------- security
--
-- Insert on transactions, restricted to the user's own MANUAL rows. The
-- with-check clause is what makes entry_source unforgeable from the phone:
-- an insert claiming 'PARSED' is refused by the policy, and one that omits
-- the column gets the 'PARSED' default and is refused for the same reason.
create policy "insert own manual" on transactions
    for insert with check (auth.uid() = user_id and entry_source = 'MANUAL');

-- Column-level, in the same spirit as the initial migration's update grant.
-- Absent by design: parser_version (pinned to 0 by default + constraint),
-- source_message_id and source_raw_message_id (a manual row must have
-- neither), transfer_group_id (the worker's matcher owns it), created_at,
-- category_confidence.
--
-- balance_after_paisa IS granted, and it is the one that makes gap-filling
-- work at all: reconcile.py skips rows with a null balance, so an entry
-- without one would leave the very gap it was meant to close still open.
-- The app computes it from the gap's own arithmetic (the balance the bank
-- showed after the transaction before it, plus this entry's signed amount),
-- so a correctly-filled gap makes the chain reconcile on the next run.
--
-- description_raw is granted despite invariant 9 ("the bank's words and the
-- user's words are different columns"): for a MANUAL row there are no bank
-- words, and no reparse will ever overwrite them. user_note still means the
-- same thing it always did.
grant insert (
    user_id, account_id, occurred_at, occurred_precision, direction,
    amount_paisa, balance_after_paisa, currency, reference, description_raw,
    counterparty, channel, user_note, category_id, category_source,
    excluded_from_spend, status, dedupe_key, entry_source
) on transactions to authenticated;

-- Marking a gap resolved (or dismissed) from the app. Detection stays the
-- worker's: the phone may close a gap, never open one, and never edit the
-- amount or the transaction pair that defines it.
create policy "update own" on ledger_gaps
    for update using (auth.uid() = user_id)
                with check (auth.uid() = user_id);

revoke update on ledger_gaps from authenticated;
grant  update (resolved, resolved_at, resolved_by, resolution_note)
       on ledger_gaps to authenticated;

-- ------------------------------------------------------------ open gaps view
-- The gap-fill form needs the balance the account stood at *before* the gap
-- and the timestamps bracketing it, all of which live on the two referenced
-- transactions. PostgREST can embed those, but it cannot express "only the
-- rows where both sides still exist" or hand back a ready-made running
-- balance, and the arithmetic is identical for every caller -- so it belongs
-- here once rather than in the app.
--
-- security_invoker = on, for the reason the initial migration spells out:
-- without it the view runs as its owner and bypasses RLS entirely.
create view v_open_ledger_gaps with (security_invoker = on) as
select
    g.id,
    g.user_id,
    g.account_id,
    a.display_name              as account_display_name,
    a.currency                  as currency,
    g.missing_paisa,
    g.detected_at,
    g.after_txn_id,
    after_txn.occurred_at       as after_occurred_at,
    after_txn.balance_after_paisa as after_balance_paisa,
    g.before_txn_id,
    before_txn.occurred_at      as before_occurred_at,
    before_txn.balance_after_paisa as before_balance_paisa
from ledger_gaps g
join accounts     a          on a.id = g.account_id
join transactions after_txn  on after_txn.id  = g.after_txn_id
join transactions before_txn on before_txn.id = g.before_txn_id
where not g.resolved;

comment on view v_open_ledger_gaps is
    'Unresolved balance discontinuities, with the bracketing transactions '
    'timestamps and balances the gap-fill form needs. missing_paisa is '
    'signed: negative means a DEBIT is missing, positive means a CREDIT is.';
