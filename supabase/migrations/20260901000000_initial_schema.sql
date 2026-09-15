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
