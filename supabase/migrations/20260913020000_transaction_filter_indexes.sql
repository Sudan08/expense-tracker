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
