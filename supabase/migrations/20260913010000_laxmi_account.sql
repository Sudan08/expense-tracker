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
