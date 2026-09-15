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
