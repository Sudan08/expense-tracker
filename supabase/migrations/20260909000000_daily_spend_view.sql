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
