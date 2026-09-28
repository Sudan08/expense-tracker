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
