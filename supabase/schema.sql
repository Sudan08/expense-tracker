-- Consolidated schema for Expense Tracker
-- Automatically concatenated from supabase/migrations/*.sql
-- For single-click setup in Supabase SQL Editor or fresh deployments.
--
-- ========================================================
-- Migration: 20260901000000_initial_schema.sql
-- ========================================================
-- Initial schema. See docs/EXPENSE_TRACKER_PLAN.md sections 9 and 11.
-- Every table carries user_id from day one -- retrofitting RLS onto a schema
-- without it later is miserable, and it costs nothing now (section 9, 15).

create type account_kind   as enum ('BANK', 'WALLET');
create type direction      as enum ('DEBIT', 'CREDIT');
create type email_status   as enum ('PARSED', 'FAILED', 'IGNORED');
create type txn_status     as enum ('NEEDS_REVIEW', 'CATEGORIZED', 'CONFIRMED');
create type time_precision as enum ('SECOND', 'MINUTE', 'DAY');

-- ------------------------------------------------------------ ingest metadata
-- No bodies. Only enough to answer "have I seen this, and what happened to it?"

create table processed_emails (
    -- Global primary key, not scoped by user_id: two different users' Gmail
    -- accounts could in principle generate colliding Message-IDs and fight
    -- over one row. Fine under section 15's explicit single-user assumption;
    -- revisit (composite key on (user_id, message_id)) before ever retrofitting
    -- multi-user.
    message_id     text primary key,               -- RFC 5322 Message-ID
    user_id        uuid not null references auth.users(id),
    received_at    timestamptz not null,
    from_addr      text not null,
    template_key   text,
    parser_version int,
    status         email_status not null,
    error          text,
    txn_count      int not null default 0,
    processed_at   timestamptz not null default now()
);
create index on processed_emails (user_id, received_at desc);
create index on processed_emails (user_id, status);

create table sync_runs (
    id            uuid primary key default gen_random_uuid(),
    user_id       uuid not null references auth.users(id),
    machine       text not null,                   -- 'arch-laptop' | 'macbook'
    started_at    timestamptz not null,
    completed_at  timestamptz,
    since         timestamptz not null,
    fetched       int not null default 0,
    parsed        int not null default 0,
    failed        int not null default 0,
    txns_inserted int not null default 0,
    error         text
);
create index on sync_runs (user_id, completed_at desc);

-- ------------------------------------------------------------ ledger

create table accounts (
    id           uuid primary key default gen_random_uuid(),
    user_id      uuid not null references auth.users(id),
    kind         account_kind not null,
    institution  text not null,                    -- 'NABIL', 'ESEWA'
    mask         text,                             -- '001#####234567'
    display_name text not null,
    currency     char(3) not null default 'NPR',
    unique (user_id, institution, mask)
);

create table categories (
    id        uuid primary key default gen_random_uuid(),
    user_id   uuid not null references auth.users(id),
    name      text not null,
    parent_id uuid references categories(id),
    is_spend  boolean not null default true,       -- false for Transfer, Salary
    unique (user_id, name)
);

create table transfer_groups (
    id                uuid primary key default gen_random_uuid(),
    user_id           uuid not null references auth.users(id),
    confidence        numeric(4,3) not null,
    confirmed_by_user boolean not null default false,
    created_at        timestamptz not null default now()
);

create table transactions (
    id                  uuid primary key default gen_random_uuid(),
    user_id             uuid not null references auth.users(id),
    account_id          uuid not null references accounts(id),
    source_message_id   text not null references processed_emails(message_id),

    occurred_at         timestamptz not null,
    occurred_precision  time_precision not null,
    direction           direction not null,
    amount_paisa        bigint not null check (amount_paisa > 0),
    balance_after_paisa bigint,
    currency            char(3) not null default 'NPR',

    reference           text,
    description_raw     text not null,             -- Remarks / bank name, verbatim
    counterparty        text,                      -- normalized merchant
    channel             text,                      -- ATM | FONEPAY | IPS | POS | ...

    category_id         uuid references categories(id),
    category_source     text,                      -- 'rule' | 'llm' | 'user'
    category_confidence numeric(4,3),

    transfer_group_id   uuid references transfer_groups(id),
    excluded_from_spend boolean not null default false,

    status              txn_status not null default 'NEEDS_REVIEW',
    dedupe_key          text not null,
    parser_version      int not null,
    created_at          timestamptz not null default now(),

    unique (user_id, dedupe_key)
);
create index on transactions (user_id, account_id, occurred_at desc);
create index on transactions (user_id, status);
create index on transactions (transfer_group_id);

create table merchant_rules (
    id                 uuid primary key default gen_random_uuid(),
    user_id            uuid not null references auth.users(id),
    pattern            text not null,              -- regex over description_raw
    category_id        uuid not null references categories(id),
    counterparty_label text,
    priority           int not null default 100,
    learned_from_user  boolean not null default false,
    hit_count          int not null default 0,
    created_at         timestamptz not null default now()
);

create table ledger_gaps (
    id            uuid primary key default gen_random_uuid(),
    user_id       uuid not null references auth.users(id),
    account_id    uuid not null references accounts(id),
    after_txn_id  uuid not null references transactions(id),
    before_txn_id uuid not null references transactions(id),
    missing_paisa bigint not null,                 -- signed
    detected_at   timestamptz not null default now(),
    resolved      boolean not null default false
);

-- ------------------------------------------------------------ views for the phone
-- Without an API layer, the phone must not pull thousands of rows to sum them.

create view v_monthly_spend with (security_invoker = on) as
select
    user_id,
    date_trunc('month', occurred_at at time zone 'Asia/Kathmandu') as month,
    category_id,
    sum(amount_paisa) filter (where direction = 'DEBIT')  as spent_paisa,
    sum(amount_paisa) filter (where direction = 'CREDIT') as received_paisa,
    count(*)                                              as txn_count
from transactions
where not excluded_from_spend
group by 1, 2, 3;

-- security_invoker = on is not optional: a view created without it runs as
-- its owner and bypasses RLS entirely -- every user would read every row.
-- This is the single easiest way to leak a financial database on Supabase.

-- ------------------------------------------------------------ RLS (section 11.2)
-- Enable on every table. Default deny.

alter table transactions      enable row level security;
alter table accounts          enable row level security;
alter table categories        enable row level security;
alter table merchant_rules    enable row level security;
alter table transfer_groups   enable row level security;
alter table ledger_gaps       enable row level security;
alter table processed_emails  enable row level security;
alter table sync_runs         enable row level security;

create policy "read own" on transactions
    for select using (auth.uid() = user_id);
create policy "read own" on accounts
    for select using (auth.uid() = user_id);
create policy "read own" on categories
    for select using (auth.uid() = user_id);
create policy "read own" on transfer_groups
    for select using (auth.uid() = user_id);
create policy "read own" on ledger_gaps
    for select using (auth.uid() = user_id);
create policy "read own" on processed_emails
    for select using (auth.uid() = user_id);
create policy "read own" on sync_runs
    for select using (auth.uid() = user_id);
create policy "read own" on merchant_rules
    for select using (auth.uid() = user_id);

create policy "update own" on transactions
    for update using (auth.uid() = user_id)
                with check (auth.uid() = user_id);

-- Restrict *which columns* the phone may write, so "recategorize" can't
-- become "rewrite the amount". No insert/delete grant on transactions for
-- authenticated, ever -- only the worker (service_role, which bypasses RLS
-- and these grants entirely) writes financial facts.
revoke update on transactions from authenticated;
grant  update (category_id, category_source, status, excluded_from_spend)
       on transactions to authenticated;

-- merchant_rules is the one table the phone gets insert on -- the
-- correction loop from recategorizing in the app.
create policy "insert own" on merchant_rules
    for insert with check (auth.uid() = user_id);

-- ========================================================
-- Migration: 20260901010000_phase3_transfers_reconcile.sql
-- ========================================================
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

-- ========================================================
-- Migration: 20260908000000_user_note.sql
-- ========================================================
-- A place for the human's own words about a transaction ("dinner with Ram",
-- "reimbursed by office").
--
-- Deliberately NOT description_raw. That column is the bank's verbatim text
-- and belongs to the parser: invariant 4 (every parser run is versioned, so
-- "reparse everything the v3 parser touched" is one query) means a reparse
-- rewrites description_raw. Anything the user typed there would vanish.
-- user_note is never written by the worker, so it survives a reparse.
alter table transactions
    add column user_note text
        check (user_note is null or length(user_note) <= 500);

-- Extends the column-level grant from the initial migration (plan section
-- 11.2). Column grants accumulate, so this adds user_note alone -- amount,
-- date, and description_raw stay unwritable from the phone.
grant update (user_note) on transactions to authenticated;

-- ========================================================
-- Migration: 20260908010000_sms_ingest.sql
-- ========================================================
-- SMS ingest (Laxmi Bank, which sends no email at all).
--
-- The phone reads its own SMS inbox and inserts the raw text here; the worker
-- parses it into transactions on the next run. Invariant 8 ("the phone never
-- writes financial facts") still holds -- what the phone writes is raw
-- material, not a ledger row. Only the worker, holding service_role, creates
-- a transactions row, and it is still the only thing that runs a parser.
--
-- Why a staging table rather than forwarding SMS to Gmail: the phone's SMS
-- inbox is a durable archive the app can re-scan on demand, so a message
-- missed while the app was killed is recoverable -- a forwarder that drops
-- one drops it forever. Keeping the body here also makes reparsing free:
-- invariant 4's "reparse everything the v3 parser touched" applies to SMS
-- without the phone being involved a second time.

create type raw_message_status as enum ('PENDING','PARSED','FAILED','IGNORED');

create table raw_messages (
    id             uuid primary key default gen_random_uuid(),
    user_id        uuid not null references auth.users(id),

    channel        text not null default 'SMS',
    sender         text not null,               -- 'LaxmiBank', as the handset saw it
    body           text not null,
    received_at    timestamptz not null,        -- from the SMS, not the upload
    device         text,                        -- which handset uploaded it

    -- sha256(sender | received_at epoch millis | body), computed on the phone.
    -- This is what makes a re-scan of the whole inbox idempotent, and it is a
    -- DB constraint rather than application logic on purpose (invariant 5).
    content_hash   text not null,

    status         raw_message_status not null default 'PENDING',
    template_key   text,
    parser_version int,
    error          text,                        -- invariant 6: never silently dropped
    txn_count      int not null default 0,
    processed_at   timestamptz,

    uploaded_at    timestamptz not null default now(),

    unique (user_id, content_hash)
);
create index on raw_messages (user_id, status);
create index on raw_messages (user_id, received_at desc);

-- ---------------------------------------------------------------- provenance
--
-- transactions.source_message_id points at processed_emails, which an
-- SMS-derived row has no counterpart in. Rather than fabricate a synthetic
-- processed_emails row, name the second source honestly and require exactly
-- one of the two.

alter table transactions
    add column source_raw_message_id uuid references raw_messages(id);

alter table transactions
    alter column source_message_id drop not null;

alter table transactions
    add constraint transactions_exactly_one_source
    check (num_nonnulls(source_message_id, source_raw_message_id) = 1);

create index on transactions (source_raw_message_id);

-- ----------------------------------------------------------------- security
--
-- The phone inserts raw material and reads back what happened to it. It may
-- not set status/txn_count/error -- those are the worker's account of the
-- parse, and a phone that could write them could hide a failed message.

alter table raw_messages enable row level security;

create policy "read own" on raw_messages
    for select using (auth.uid() = user_id);

create policy "insert own" on raw_messages
    for insert with check (auth.uid() = user_id);

revoke insert on raw_messages from authenticated;
grant  insert (user_id, channel, sender, body, received_at, device, content_hash)
       on raw_messages to authenticated;

-- ========================================================
-- Migration: 20260908020000_currency_fix_and_merchant_rules_rw.sql
-- ========================================================
-- Two independent fixes, bundled because both are prerequisites named in
-- docs/APP_IMPROVEMENTS.md section 8 (items 1 and 3) before any chart work
-- starts.

-- ---------------------------------------------------------------- #1: currency
--
-- v_monthly_spend summed amount_paisa across currencies with no currency in
-- its GROUP BY. nabil.card_txn genuinely parses foreign-currency purchases
-- (parsers/nabil.py: `(?P<currency>[A-Z]{3})`), so a USD 20.00 charge was
-- silently added to the NPR total as Rs 20.00. Group by currency instead of
-- converting -- there is no exchange rate anywhere in this pipeline, and
-- inventing one at view-definition time would be worse than keeping the
-- totals honestly separate.
drop view if exists v_monthly_spend;

create view v_monthly_spend with (security_invoker = on) as
select
    user_id,
    date_trunc('month', occurred_at at time zone 'Asia/Kathmandu') as month,
    category_id,
    currency,
    sum(amount_paisa) filter (where direction = 'DEBIT')  as spent_paisa,
    sum(amount_paisa) filter (where direction = 'CREDIT') as received_paisa,
    count(*)                                              as txn_count
from transactions
where not excluded_from_spend
group by 1, 2, 3, 4;

-- ------------------------------------------------------- #2: merchant_rules
--
-- The phone has had insert on merchant_rules since the initial schema (the
-- recategorize correction loop, plan section 10) but never update or
-- delete. One mistapped category in the recategorize sheet writes a rule
-- that silently miscategorises that merchant on every future sync, with no
-- way from the app to see it happened, let alone fix it.
create policy "update own" on merchant_rules
    for update using (auth.uid() = user_id)
                with check (auth.uid() = user_id);

create policy "delete own" on merchant_rules
    for delete using (auth.uid() = user_id);

-- learned_from_user, hit_count, and created_at stay worker/trigger-owned --
-- editing a rule from the app changes what it matches or where it files,
-- not its provenance or its hit history.
grant update (pattern, category_id, counterparty_label, priority)
      on merchant_rules to authenticated;
grant delete on merchant_rules to authenticated;

-- ========================================================
-- Migration: 20260909000000_daily_spend_view.sql
-- ========================================================
-- Powers the GitHub-contributions-style spend heatmap on the dashboard.
-- See docs/APP_IMPROVEMENTS.md section 3.1.
--
-- Grouped by currency for the same reason v_monthly_spend is (migration
-- 20260908020000): no exchange rate exists anywhere in this pipeline, so
-- currencies are never silently combined. The mobile client filters to
-- primaryCurrency ('NPR') before bucketing into the heatmap, same as the
-- monthly totals do.
create view v_daily_spend with (security_invoker = on) as
select
    user_id,
    (occurred_at at time zone 'Asia/Kathmandu')::date as day,
    currency,
    sum(amount_paisa) filter (where direction = 'DEBIT')  as spent_paisa,
    count(*) filter (where direction = 'DEBIT')           as txn_count
from transactions
where not excluded_from_spend
group by 1, 2, 3;

-- `at time zone 'Asia/Kathmandu'` before the ::date cast, not after --
-- invariant 2 (time is stored UTC, displayed Asia/Kathmandu). A payment at
-- 00:30 Kathmandu time must land on that day, not the UTC day before it.

-- ========================================================
-- Migration: 20260911010000_category_groups.sql
-- ========================================================
-- Category groups.
--
-- categories.parent_id has existed since the initial schema but nothing used
-- it. This turns the flat starter list into groups (parent rows) holding the
-- categories transactions are actually filed under. transactions and
-- merchant_rules reference category ids, so existing rows are renamed and
-- reparented in place rather than replaced -- every row pointing at them
-- carries over.
--
-- A group is any category some other category points at. Transactions still
-- pointing at a row that became a group (old "Health", "Shopping", ...) are
-- moved to a child by `expense-tracker categorize --all`, not here -- which
-- child is a per-transaction judgement.

-- ------------------------------------------------------------ 1. renames
-- Same meaning, new name. Health, Shopping, Transport and Travel keep their
-- names and simply become groups in step 2.
update categories set name = 'Restaurants'     where name = 'Food';
update categories set name = 'Bank Fees'       where name = 'Fees';
update categories set name = 'Movies & Events' where name = 'Entertainment';
update categories set name = 'Tuition & Fees'  where name = 'Education';
update categories set name = 'Home & Bills'    where name = 'Bills';

-- ------------------------------------------------------------ 2. groups
insert into categories (user_id, name, is_spend)
select u.user_id, g.name, g.is_spend
from (select distinct user_id from categories) u
cross join (values
    ('Food & Drink',       true),
    ('Health',             true),
    ('Home & Bills',       true),
    ('Transport',          true),
    ('Shopping',           true),
    ('Subscriptions',      true),
    ('Travel',             true),
    ('Education',          true),
    ('Fun & Social',       true),
    ('Family & People',    true),
    ('Fees & Cash',        true),
    ('Investments',        false),
    ('Income & Transfers', false)
) as g(name, is_spend)
on conflict (user_id, name) do update set is_spend = excluded.is_spend, parent_id = null;

-- ------------------------------------------------------------ 3. categories
-- Existing leaves (Groceries, Restaurants, Salary, ...) hit the conflict and
-- just get their group. "Other" stays ungrouped, as the catch-all.
insert into categories (user_id, name, is_spend, parent_id)
select u.user_id, c.name, grp.is_spend, grp.id
from (select distinct user_id from categories) u
cross join (values
    ('Groceries',                'Food & Drink'),
    ('Restaurants',              'Food & Drink'),
    ('Cafe & Bakery',            'Food & Drink'),
    ('Khaja & Snacks',           'Food & Drink'),
    ('Bars & Drinks',            'Food & Drink'),
    ('Food Delivery',            'Food & Drink'),

    ('Medicine & Pharmacy',      'Health'),
    ('Hospital & Doctor',        'Health'),
    ('Lab Tests',                'Health'),
    ('Dental & Eye',             'Health'),
    ('Supplements & Nutrition',  'Health'),
    ('Health Insurance',         'Health'),
    ('Gym & Fitness',            'Health'),

    ('Rent',                     'Home & Bills'),
    ('Electricity',              'Home & Bills'),
    ('Water',                    'Home & Bills'),
    ('Internet',                 'Home & Bills'),
    ('Mobile Recharge',          'Home & Bills'),
    ('Cooking Gas',              'Home & Bills'),
    ('Home Repairs',             'Home & Bills'),
    ('Household Supplies',       'Home & Bills'),

    ('Ride-hailing',             'Transport'),
    ('Fuel',                     'Transport'),
    ('Bus & Public Transport',   'Transport'),
    ('Vehicle Service',          'Transport'),

    ('Clothing & Shoes',         'Shopping'),
    ('Electronics & Gadgets',    'Shopping'),
    ('Online Shopping',          'Shopping'),
    ('Personal Care & Cosmetics','Shopping'),

    ('AI Tools',                 'Subscriptions'),
    ('Cloud & Hosting',          'Subscriptions'),
    ('Streaming & Apps',         'Subscriptions'),

    ('Travel Tickets',           'Travel'),
    ('Hotels & Stays',           'Travel'),
    ('Trip Activities',          'Travel'),

    ('Tuition & Fees',           'Education'),
    ('Courses & Books',          'Education'),

    ('Movies & Events',          'Fun & Social'),
    ('Gifts & Donations',        'Fun & Social'),
    ('Festivals & Puja',         'Fun & Social'),

    ('Family Support',           'Family & People'),
    ('Sent to Friends',          'Family & People'),

    ('Bank Fees',                'Fees & Cash'),
    ('Cash Withdrawal',          'Fees & Cash'),

    ('IPO & Shares',             'Investments'),
    ('Mutual Funds & SIP',       'Investments'),
    ('Savings & Deposits',       'Investments'),

    ('Salary',                   'Income & Transfers'),
    ('Dividends & Interest',     'Income & Transfers'),
    ('Refunds & Cashback',       'Income & Transfers'),
    ('Transfer',                 'Income & Transfers')
) as c(name, group_name)
join categories grp on grp.user_id = u.user_id and grp.name = c.group_name
on conflict (user_id, name) do update set parent_id = excluded.parent_id, is_spend = excluded.is_spend;

-- ------------------------------------------------------------ 4. merchant_rules
-- A rule filing into a row that just became a group would keep putting new
-- transactions on the group itself. Point those at the specific category.
update merchant_rules r
set category_id = leaf.id
from (values
    ('GOOGLE \*CLAUDE',                                   'AI Tools'),
    ('OPENAI \*CHATGPT',                                  'AI Tools'),
    ('PAYPAL \*CONTABO',                                  'Cloud & Hosting'),
    ('EXAMPLE HEALTH CARE',                                 'Hospital & Doctor'),
    ('EXAMPLE PHARMACY',                                'Medicine & Pharmacy'),
    ('^CASBA allot',                                      'IPO & Shares'),
    ('MPAY EXAMPLEBK;55500000044,00100002234567,laptop,S', 'Electronics & Gadgets')
) as m(pattern, leaf_name)
join categories leaf on leaf.name = m.leaf_name
where leaf.user_id = r.user_id and r.pattern = m.pattern;

-- ========================================================
-- Migration: 20260913000000_manual_entries_and_gap_fill.sql
-- ========================================================
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

-- ========================================================
-- Migration: 20260913010000_laxmi_account.sql
-- ========================================================
-- A Laxmi Bank account row, so manual entries can be filed against it.
--
-- Accounts are normally created by the worker the first time a parser sees a
-- transaction from one (store/supabase.py::get_or_create_account). Laxmi is
-- the one institution where that never happens: it sends no email at all
-- (plan section 8.5), its SMS templates haven't been captured yet, and
-- parsers/sms.py still has the Laxmi slot empty pending fixtures. So the
-- account that would be created by the first parsed Laxmi transaction does
-- not exist, and until the parser lands there is nothing to select in the
-- app's manual-entry form.
--
-- That is exactly backwards for the account most in need of manual entry:
-- Laxmi is currently 100% invisible to the pipeline, so every Laxmi
-- transaction is one the user has to type in themselves.
--
-- ----------------------------------------------------------------- the mask
--
-- Inserted with mask = '' rather than NULL, matching get_or_create_account's
-- own coercion -- the unique (user_id, institution, mask) constraint cannot
-- dedupe on NULL, because Postgres NULLs are never equal to each other.
--
-- WHEN THE LAXMI SMS PARSER LANDS, CHECK THIS. If those templates turn out to
-- carry an account mask, get_or_create_account will look for
-- (LAXMI, '0123...') , not find this row, and create a *second* Laxmi
-- account -- leaving manual entries on one and parsed ones on the other, and
-- the balance reconciler running over two half-chains that each look full of
-- gaps. The fix at that point is to repoint this row's mask and merge, not
-- to let both stand. If the templates carry no mask, this row is the one the
-- parser will find and nothing needs doing.

-- kind is cast explicitly: INSERT ... SELECT does not coerce a bare string
-- literal to an enum the way INSERT ... VALUES does against the target
-- column, and without it this fails with "column kind is of type
-- account_kind but expression is of type text".
insert into accounts (user_id, kind, institution, mask, display_name, currency)
select distinct c.user_id, 'BANK'::account_kind, 'LAXMI', '', 'Laxmi Bank', 'NPR'
from categories c
on conflict (user_id, institution, mask) do nothing;

-- ========================================================
-- Migration: 20260913020000_transaction_filter_indexes.sql
-- ========================================================
-- Indexes for the transaction list's filters and search.
--
-- docs/APP_IMPROVEMENTS.md names both of these as prerequisites of the
-- features they support: section 2.2 ("Filtering by category or status
-- across a date range will want (user_id, category_id, occurred_at desc)")
-- and section 2.3 (pg_trgm over the text columns the search reads).
--
-- At today's row count none of this matters -- a sequential scan over a few
-- hundred rows is instant, and Postgres will rightly ignore every index
-- below. They are here because the queries that need them now exist, and
-- because the moment they *do* matter is a year of daily syncs from now,
-- long after anyone would think to come back and add them.

-- ------------------------------------------------------------------ filters
-- The initial schema has (user_id, account_id, occurred_at desc) and
-- (user_id, status). Category is the one dimension the new filter bar can
-- narrow on that had no index reaching occurred_at, which is always in the
-- query as a range and always the sort key.
create index if not exists transactions_user_category_occurred_idx
    on transactions (user_id, category_id, occurred_at desc);

-- "Uncategorized only" is the most-used filter on that screen and is a
-- different query shape: category_id IS NULL rather than = something.
-- Partial, so it indexes only the rows it can ever return.
create index if not exists transactions_user_uncategorized_idx
    on transactions (user_id, occurred_at desc)
    where category_id is null;

-- Transfers hidden/only, which is an equality on a boolean with very low
-- cardinality -- worth indexing only for the 'only' case, which is the
-- small side.
create index if not exists transactions_user_transfers_idx
    on transactions (user_id, occurred_at desc)
    where excluded_from_spend;

-- ------------------------------------------------------------------ search
-- Trigram, not full-text. Section 2.3's reasoning: tsvector tokenising
-- fights the bank's own formatting -- FONEPAY/BHATBHATENI is one token to a
-- human and several to a tokeniser -- where trigrams handle partial merchant
-- names and embedded punctuation without any of that.
--
-- gin_trgm_ops is what makes the app's `ilike %term%` sargable; a btree
-- index cannot serve a leading-wildcard LIKE at all.
create extension if not exists pg_trgm;

create index if not exists transactions_description_trgm_idx
    on transactions using gin (description_raw gin_trgm_ops);

create index if not exists transactions_counterparty_trgm_idx
    on transactions using gin (counterparty gin_trgm_ops);

-- user_note is searched alongside the other two (the search box says
-- "description, merchant or note"), so it needs the same treatment or it
-- becomes the one term that forces a scan.
create index if not exists transactions_user_note_trgm_idx
    on transactions using gin (user_note gin_trgm_ops);

-- ========================================================
-- Migration: 20260913030000_cash_account.sql
-- ========================================================
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

-- ========================================================
-- Migration: 20260915000000_nabil_sms_cross_transport.sql
-- ========================================================
-- Nabil reports each transaction over two transports. Make them collapse
-- onto one row instead of two, and repair any that already doubled.
--
-- Background: nabil.sms_alert (parsers/nabil_sms.py) reports the same
-- transactions the existing nabil.txn_alert email already does. The two
-- transports disagree about almost everything except the money:
--
--     email  "001#####234567"  minute precision  remarks <= 50 chars  WITH balance
--     SMS    "001##34567"      second precision  remarks == 18 chars  no balance
--
-- Left alone that is two rows in `accounts` for one real account, two
-- different dedupe_keys for one real transaction, and therefore every Nabil
-- transaction counted twice. Both parsers now reduce each report to what the
-- transports actually agree on: a canonical mask (first 3 + last 5 digits),
-- the timestamp truncated to the minute, and a fingerprint of the first 18
-- characters of the remarks -- 18 being the entire overlap, since that is
-- where the SMS cuts.
--
-- This migration brings rows already in the database onto that scheme. It has
-- to do two things, because a database that has already run a sync with the
-- new parsers holds both problems at once:
--
--   1. rewrite every Nabil account-alert key to the new formula, and
--   2. merge the groups that turn out to be the same transaction, keeping
--      whichever row carries the most information.
--
-- Step 2 is not optional. Rewriting alone would violate the unique constraint
-- the moment two rows computed the same key, and skipping those rows would
-- leave the duplicates on screen forever.
--
-- Scope: only nabil.txn_alert / nabil.sms_alert rows. nabil.card_txn keeps
-- the raw card mask and its own formula -- a card is not a bank account, has
-- no second transport, and reducing "XXXX2496" to digits could collide with
-- one. It is excluded by shape: card keys carry a bare date, account keys
-- carry a date *and* a time.

-- ---------------------------------------------------------------- helpers
-- Deliberately temporary: these make the statements below readable and are
-- dropped at the end. parsers/nabil.py holds the real definitions -- a
-- permanent second implementation in SQL would be two things to keep in step.

create or replace function pg_temp.nabil_canonical_mask(mask text)
returns text language sql immutable as $fn$
    select case
        when length(regexp_replace(coalesce(mask, ''), '\D', '', 'g')) < 8
            then mask
        else substring(regexp_replace(mask, '\D', '', 'g') from 1 for 3)
             || right(regexp_replace(mask, '\D', '', 'g'), 5)
    end
$fn$;

-- Nabil appends a standing advert to every SMS. An earlier parser version
-- stored it as part of the remarks, so rows already in the database carry it
-- and it must come off before the fingerprint is taken.
-- Matched by shape, not by listing the adverts: three variants are in
-- circulation ("Download App: <url>", "For A/C Balance: <url>", "Activate
-- <shortlink> for a/c balance") and enumerating them means the next one Nabil
-- invents silently starts duplicating transactions again. A trailing line
-- carrying a URL is never part of a bank remark. Mirrors _TRAILER_RE in
-- parsers/nabil_sms.py.
create or replace function pg_temp.nabil_strip_trailer(remarks text)
returns text language sql immutable as $fn$
    select btrim(regexp_replace(coalesce(remarks, ''),
        '\s*([^\n]*https?://\S+|Activate\s+\S+(\s+for\s+a/c\s+balance)?|-\s*Nabil\s*Bank.*)\s*$',
        '', 'gi'))
$fn$;

-- sha256() is a CORE Postgres function (11+); sha1 would mean depending on
-- pgcrypto, which Supabase installs into a separate `extensions` schema where
-- a bare digest() call may not resolve. Matches parsers/nabil.py, which chose
-- sha256 for exactly this reason. The left(.., 18) is the load-bearing part:
-- that is where the SMS cuts, so it is the most either transport can agree on.
create or replace function pg_temp.nabil_remarks_fingerprint(remarks text)
returns text language sql immutable as $fn$
    select substring(
        encode(sha256(convert_to(
            regexp_replace(
                upper(left(pg_temp.nabil_strip_trailer(remarks), 18)),
                '[^A-Z0-9]', '', 'g'),
            'UTF8')), 'hex')
        from 1 for 8)
$fn$;

-- --------------------------------------------- 0. scrub stored adverts
-- An earlier parser version stored Nabil's advert as part of the remarks. Do
-- this before anything else reads description_raw: it is what the ledger
-- displays, what merchant rules match against, and what the fingerprint below
-- is computed from. Rows whose SMS has no email counterpart never merge into
-- anything, so this is their only chance to be cleaned.
update transactions t
set description_raw = pg_temp.nabil_strip_trailer(t.description_raw)
from accounts a
where a.id = t.account_id
  and a.institution = 'NABIL'
  and t.description_raw is distinct from pg_temp.nabil_strip_trailer(t.description_raw)
  -- never blank the column out: it is NOT NULL, and a remark that is nothing
  -- but an advert is better left visible than silently emptied
  and length(pg_temp.nabil_strip_trailer(t.description_raw)) > 0;

-- ------------------------------------------------------- 1. merge accounts
-- Point the account at its canonical mask so both legs resolve to one row.
-- If both spellings already exist (a sync ran before this migration did),
-- move the duplicate's rows across first -- otherwise the unique
-- (user_id, institution, mask) constraint rejects the update below.
-- One survivor per canonical mask, chosen deterministically. A naive
-- self-join emits each pair in BOTH directions -- (A,B) and (B,A) -- so the
-- second iteration tries to merge into an account the first already deleted,
-- and the run dies on a foreign key violation. first_value() over the group
-- picks exactly one target and makes every other row merge into it.
do $blk$
declare
    survivor  uuid;
    duplicate uuid;
begin
    for survivor, duplicate in
        with grouped as (
            select id,
                   first_value(id) over (
                       partition by user_id, institution, kind,
                                    pg_temp.nabil_canonical_mask(mask)
                       -- prefer a row that already reads as canonical, then
                       -- the lowest id, so the choice never depends on
                       -- scan order
                       order by (mask = pg_temp.nabil_canonical_mask(mask)) desc, id
                   ) as keep_id
            from accounts
            where institution = 'NABIL' and kind = 'BANK'
        )
        select keep_id, id from grouped where id <> keep_id
    loop
        update transactions set account_id = survivor where account_id = duplicate;
        update ledger_gaps   set account_id = survivor where account_id = duplicate;
        delete from accounts where id = duplicate;
    end loop;
end $blk$;

update accounts
set mask = pg_temp.nabil_canonical_mask(mask)
where institution = 'NABIL'
  and kind = 'BANK'
  and mask is distinct from pg_temp.nabil_canonical_mask(mask);

-- ------------------------------------------- 2. what each row's key becomes
-- Built from the row's own stored columns rather than by re-parsing the
-- archive, so this works on a machine whose raw/ cache has been pruned.
create temporary table nabil_rekey as
select
    t.id,
    t.user_id,
    'nabil:' || pg_temp.nabil_canonical_mask(a.mask) || ':'
        || to_char(t.occurred_at at time zone 'Asia/Kathmandu', 'YYYY-MM-DD"T"HH24:MI') || ':'
        || t.direction || ':' || t.amount_paisa || ':'
        || pg_temp.nabil_remarks_fingerprint(t.description_raw) as new_key
from transactions t
join accounts a on a.id = t.account_id
where a.institution = 'NABIL'
  and t.entry_source <> 'MANUAL'
  and t.dedupe_key like 'nabil:%'
  and t.dedupe_key ~ '^nabil:[^:]*:\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:(DEBIT|CREDIT):\d+:[0-9a-f]{8}$';

-- ------------------------------------------------ 3. merge the duplicates
-- Rows that now share a key are one transaction reported twice. Keep the
-- best-informed one and fold the rest into it.
--
-- Survivor preference, in order: has a balance (only the email carries one,
-- and reconciliation is blind without it), then oldest. Everything the user
-- put on a losing row -- category, confirmation, note, transfer link -- is
-- carried across first: rows categorised by hand before the duplication was
-- noticed must not lose that work.
create temporary table nabil_merge as
with ranked as (
    select r.new_key, r.user_id, t.id,
           row_number() over (
               partition by r.user_id, r.new_key
               order by (t.balance_after_paisa is null), t.created_at, t.id
           ) as rank
    from nabil_rekey r
    join transactions t on t.id = r.id
)
select w.new_key, w.user_id,
       (select id from ranked k
         where k.user_id = w.user_id and k.new_key = w.new_key and k.rank = 1) as keep_id,
       w.id as drop_id
from ranked w
where w.rank > 1;

-- Fold every loser into the survivor.
--
-- Aggregated first, deliberately. `UPDATE ... FROM` matching several source
-- rows to one target does NOT apply once per source -- Postgres picks one
-- arbitrarily and silently discards the rest. With three rows collapsing into
-- one (old-format email, new-format email, SMS) that meant the hand-applied
-- category on the SMS row was thrown away whenever the arbitrary pick landed
-- on an uncategorised sibling.
with folded as (
    select m.keep_id,
           max(src.balance_after_paisa) as balance_after_paisa,
           (array_agg(src.reference)         filter (where src.reference         is not null))[1] as reference,
           (array_agg(src.counterparty)      filter (where src.counterparty      is not null))[1] as counterparty,
           (array_agg(src.channel)           filter (where src.channel           is not null))[1] as channel,
           (array_agg(src.user_note)         filter (where src.user_note         is not null))[1] as user_note,
           (array_agg(src.transfer_group_id) filter (where src.transfer_group_id is not null))[1] as transfer_group_id,
           bool_or(src.excluded_from_spend) as excluded_from_spend,
           bool_or(src.status = 'CONFIRMED') as any_confirmed,
           (array_agg(src.description_raw order by length(src.description_raw) desc))[1] as longest_description
    from nabil_merge m
    join transactions src on src.id = m.drop_id
    group by m.keep_id
),
-- the category, its source and its confidence must come from the SAME row,
-- so they are picked together rather than column by column
best_category as (
    select distinct on (m.keep_id)
           m.keep_id, src.category_id, src.category_source, src.category_confidence
    from nabil_merge m
    join transactions src on src.id = m.drop_id
    where src.category_id is not null
    order by m.keep_id, src.created_at, src.id
)
update transactions keep set
    balance_after_paisa = coalesce(keep.balance_after_paisa, f.balance_after_paisa),
    reference           = coalesce(keep.reference, f.reference),
    counterparty        = coalesce(keep.counterparty, f.counterparty),
    channel             = coalesce(keep.channel, f.channel),
    user_note           = coalesce(keep.user_note, f.user_note),
    transfer_group_id   = coalesce(keep.transfer_group_id, f.transfer_group_id),
    excluded_from_spend = keep.excluded_from_spend or f.excluded_from_spend,
    category_id         = coalesce(keep.category_id, bc.category_id),
    category_source     = coalesce(keep.category_source, bc.category_source),
    category_confidence = coalesce(keep.category_confidence, bc.category_confidence),
    status              = case when keep.status = 'CONFIRMED' or f.any_confirmed
                               then 'CONFIRMED'::txn_status else keep.status end,
    -- the email's fuller remarks beat the SMS's 18-character cut, but only
    -- when one genuinely extends the other
    description_raw     = case when length(f.longest_description) > length(keep.description_raw)
                                and f.longest_description like keep.description_raw || '%'
                               then f.longest_description else keep.description_raw end
from folded f
left join best_category bc on bc.keep_id = f.keep_id
where keep.id = f.keep_id;

-- ledger_gaps points at transactions by FK; repoint before deleting.
update ledger_gaps g set after_txn_id  = m.keep_id from nabil_merge m where g.after_txn_id  = m.drop_id;
update ledger_gaps g set before_txn_id = m.keep_id from nabil_merge m where g.before_txn_id = m.drop_id;

delete from transactions t using nabil_merge m where t.id = m.drop_id;

-- A gap whose two ends merged into one row is not a gap any more.
delete from ledger_gaps where after_txn_id = before_txn_id;

-- ---------------------------------------------------- 4. rewrite the keys
-- Only survivors remain, so every key in nabil_rekey is now unique.
update transactions t
set dedupe_key = r.new_key
from nabil_rekey r
where t.id = r.id
  and t.dedupe_key is distinct from r.new_key;

drop table nabil_rekey;
drop table nabil_merge;
drop function if exists pg_temp.nabil_canonical_mask(text);
drop function if exists pg_temp.nabil_strip_trailer(text);
drop function if exists pg_temp.nabil_remarks_fingerprint(text);

