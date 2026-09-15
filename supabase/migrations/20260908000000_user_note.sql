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
