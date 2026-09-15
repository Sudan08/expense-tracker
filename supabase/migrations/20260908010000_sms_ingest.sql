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
