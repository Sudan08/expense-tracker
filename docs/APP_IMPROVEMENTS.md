# Mobile app — proposed improvements

**Status: reviewed. Items 1–4 (the trust batch: §0, §2.1, §5, §5.1) are
built** — see the migration `20260908020000_currency_fix_and_merchant_rules_rw.sql`
and the `✅ Built` markers in section 8. Everything else below is still a
proposal.

This is a menu, not a plan. Read section 3 first if you only read one thing,
then argue with the ordering in section 8.

Every proposal below is written against three constraints that already exist
in this project, and each one says explicitly what it costs in each place:

1. **Aggregation happens in Postgres, not Dart.** Plan §9.1: "the phone must
   not pull 5,000 rows to sum them", and §14: "keep anything non-trivial in
   Postgres, not Dart." Any feature that implies a new number on screen
   probably implies a new view or RPC.
2. **Every new view needs `with (security_invoker = on)`.** Plan §9.1 calls
   this "the single easiest way to leak a financial database on Supabase".
   It is not optional and it is easy to forget on view number four.
3. **The phone reads; the worker writes facts.** Invariant 8. Features that
   need a new phone-writable column need a new column-level `grant`, and the
   question "what happens when a reparse runs?" has to be answered for each.

Cost is rated **S** (an evening), **M** (a weekend), **L** (more than that).

---

## 0. Read this first: a bug every new chart would inherit — ✅ Built

**Decision made:** kept separate, never converted. There is no exchange rate
anywhere in this pipeline, and this was the reasonable default rather than
inventing one. `v_monthly_spend` now groups by `currency`
(`20260908020000_currency_fix_and_merchant_rules_rw.sql`); `MonthlySpend`
carries it; the dashboard sums only `currency == 'NPR'` into the headline
totals and lists any other-currency spend in a separate, un-summed note. If
you'd rather have foreign-currency amounts converted to NPR at ingest, that's
still open — say so and it's a worker-side change (needs a rate source).

`v_monthly_spend` used to sum `amount_paisa` across currencies without
grouping by currency:

```sql
-- supabase/migrations/20260901000000_initial_schema.sql:141
sum(amount_paisa) filter (where direction = 'DEBIT') as spent_paisa
...
group by 1, 2, 3;   -- user_id, month, category_id -- no currency
```

`NormalizedTxn.amount_paisa` is documented as "smallest unit of `currency`
(paisa for NPR, cents for USD)", and `nabil.card_txn` really does parse a
foreign currency (`parsers/nabil.py:130`, `(?P<currency>[A-Z]{3})`). So a USD
20.00 card purchase enters the ledger as `2000` and the dashboard adds it to
your NPR total as **Rs. 20.00**. The Dart side compounds it: `MonthlySpend`
has no currency field at all, and `_TotalsRow` calls `formatPaisa` with the
default `NPR`.

This is small today because almost everything is NPR. It matters here because
**every visualisation proposed below reads from these same aggregates**, so
building charts on top of it multiplies one wrong number into ten.

**Fix before charts (S):** add `currency` to the view's `group by`, add it to
`MonthlySpend`, and decide the product question — either show NPR only and
list foreign-currency spend separately, or store an `amount_npr_paisa`
alongside at parse time using the rate on the statement. The second is more
honest for totals and is the only way a heatmap of "spend per day" can be
truthful across currencies.

---

## 1. Where the app is today

| Screen | Does | Doesn't |
|---|---|---|
| Dashboard | Current month totals, category bars, last-synced banner | Any other month; any time series; any comparison |
| Transactions | 100 most recent, tap for detail | Filter, search, paginate, group by day |
| Review | `NEEDS_REVIEW` queue, one at a time | Bulk actions, swipe, sort |
| Detail | Full row, recategorize + note, confirm | Split, see other transactions from the same merchant |
| Bank SMS | Enrol, scan, staged-message counts | — |

Three things exist in the schema that **no screen surfaces at all**:
`ledger_gaps`, `processed_emails` with `status = 'FAILED'`, and
`merchant_rules`. Section 5 is about that. *(Now built — see section 5.)*

---

## 2. Navigation and filtering

### 2.1 Month navigation — **S** — ✅ Built

`selectedMonthProvider` is now a `StateProvider<DateTime>`, with chevrons
either side of the month title on the dashboard. Forward navigation disables
at the current month rather than clamping silently. Backward clamping at
`account_start` was skipped — that value lives only in the worker's
`config.toml`, not in Supabase, so the app has no way to know it; going too
far back just shows an empty month, same as it always did. No month
picker/swipe yet — chevrons only.

`selectedMonthProvider` is already a `Provider<DateTime>` whose own comment
says: *"swapping this to a StateProvider is the whole job for adding month
navigation later."* It is the cheapest item in this document.

- `StateProvider<DateTime>`, chevrons either side of the month title, plus a
  year/month picker on tap of the title.
- Disable forward navigation past the current month.
- Clamp backwards at `worker.account_start` — before that, empty is a lie.

*Open question: horizontal swipe between months, or just the chevrons? Swipe
conflicts with the bottom nav's own gestures on some Android skins.*

### 2.2 Filters on the transaction list — **M** — ✅ Built

Shipped 2026-09-13. Search + a one-row chip bar over date range, category
(multi, plus an "uncategorized only" switch), account, direction, status,
transfers, and amount range. State lives in one immutable `TransactionFilter`
behind `transactionFilterProvider`, exactly so the export feature (§4) can
serialise the predicate rather than reimplement it. Paged via `.range()` with
infinite scroll, as this section insists. Indexes in migration
`20260913020000`. The list also now groups by day with pinned headers and a
per-day net — that, more than the filters, is what made it readable.

A filter bar over: category (multi), account, direction, status, date range,
amount range, and "transfers: hidden / shown / only".

This composes cleanly in PostgREST without new SQL — `.in_()`, `.gte()`,
`.eq()` — so it is mostly Dart. Two things make it more than trivial:

- **Pagination.** `fetchRecent(limit: 100)` is a hard cap with no paging
  today. With filters, "why is this transaction missing?" becomes a real
  support question you'll ask yourself. Add `.range()`-based infinite scroll
  as part of this item, not after it.
- **Indexes.** `transactions (user_id, account_id, occurred_at desc)` exists.
  Filtering by category or status across a date range will want
  `(user_id, category_id, occurred_at desc)`.

Filter state should live in a Riverpod `StateNotifier` shared with the export
feature (§6), so "export what I'm looking at" is free rather than a second
implementation of the same predicates.

### 2.3 Search — **S** — ✅ Built

Shipped alongside §2.2. `or(description_raw.ilike, counterparty.ilike,
user_note.ilike)` with the pg_trgm indexes below. One deviation from the
sketch: `%` and `_` in the query are stripped rather than backslash-escaped.
PostgREST has no escape for a LIKE wildcard inside a URL filter, so a
backslash is sent through literally and matches nothing — a silent wrong
answer, where dropping the character is at worst a slightly wider match.

Substring search over `description_raw`, `counterparty`, and `user_note`.

At personal scale, `pg_trgm` beats full-text search: it handles
`FONEPAY/BHATBHATENI` and partial merchant names, where `tsvector` tokenising
would fight the bank's formatting.

```sql
create extension if not exists pg_trgm;
create index on transactions using gin (description_raw gin_trgm_ops);
create index on transactions using gin (counterparty gin_trgm_ops);
```

Then `.or('description_raw.ilike.%x%,counterparty.ilike.%x%')` from the app.

---

## 3. Visualisations

### 3.1 The spend heatmap (GitHub-contributions style) — **M**

The headline request, and the one with the most design in it. A year of days
as a grid of squares, darker where you spent more, tap a day to open the
transaction list filtered to it.

**It needs a daily view:**

```sql
create view v_daily_spend with (security_invoker = on) as
select
    user_id,
    (occurred_at at time zone 'Asia/Kathmandu')::date       as day,
    currency,
    sum(amount_paisa) filter (where direction = 'DEBIT')    as spent_paisa,
    count(*) filter (where direction = 'DEBIT')             as txn_count
from transactions
where not excluded_from_spend
group by 1, 2, 3;
```

Note `at time zone 'Asia/Kathmandu'` before the `::date` cast — invariant 2.
A payment at 00:30 Kathmandu is the 15th, not the 14th, and getting this
wrong shifts squares by one for every late-night transaction. Note also
`currency` in the `group by`, per §0.

**Three design decisions that matter more than the widget:**

**(a) The colour scale must be quantile, not linear.** Personal spend is
heavy-tailed: one rent or IPO payment is 50× a normal day. On a linear
absolute scale that single day is black and all 364 others are the palest
shade — a graph that shows you nothing. Bucket by percentile of your own
non-zero days over a trailing window:

```sql
ntile(4) over (order by spent_paisa)   -- 4 buckets over non-zero days
```

giving five states: no spend, then quartiles 1–4. Compute this in the RPC,
not in Dart, so the transaction list and the heatmap agree on what "a heavy
day" means.

**(b) "No data" must not look like "spent nothing".** This is the important
one. If your laptop is off for a week, the worker doesn't run, and seven days
have no transactions. On a naive heatmap those render identically to seven
days of genuine thrift — the graph tells you a comforting lie, and this
project's whole design ethos (invariant 6, "nothing is silently dropped") is
against that.

Render three distinct states, not two:

| State | Meaning | Suggested rendering |
|---|---|---|
| Covered, no spend | The pipeline saw this day and there was nothing | Empty square with a border |
| Covered, spend | Normal | Filled, quartile shade |
| Not covered / uncertain | Before `account_start`, or inside an open `ledger_gap` | Hatched or dotted, never a colour on the spend ramp |

Coverage is a proxy, and worth stating as one: a day is uncertain if it falls
before `worker.account_start`, or between the two transactions of an
unresolved `ledger_gaps` row (which is exactly what that table detects — a
balance discontinuity meaning something is missing). It won't catch every
gap, but it converts the most common lie into a visible question mark.

**(c) Green is the wrong hue.** GitHub's ramp means "more is better".
Spending more is not an achievement, and colouring a heavy month in
celebratory green reads oddly once you notice it. A neutral single-hue
sequential ramp (slate → deep indigo, or amber) says "more" without saying
"good" or "bad". Avoid red-green entirely: it fails for colourblind viewers
and moralises. Both light and dark palettes need defining — the app is
theme-aware and a ramp tuned on white is illegible on the dark background in
your screenshot.

*Open questions: 12 months or 6 on a phone-width screen? (A year of squares
at 52 columns is ~6px per cell on a 360dp screen — legible but not tappable;
horizontal scroll at a comfortable cell size is probably better than
squeezing.) And should the ramp be per-day total, or per-day transaction
count like GitHub's actual commit graph?*

### 3.2 Spend over time — **S** (once `v_daily_spend` exists)

Two charts, both from the same view:

- **Daily bars for the selected month.** Answers "which days were heavy" at a
  glance and pairs naturally with the heatmap's tap-through.
- **Cumulative burn line, this month vs last.** Two lines from day 1, this
  month's stopping at today. This is the single most actionable chart in this
  document: "am I ahead of or behind where I was a month ago" is the question
  you actually have, and a total at month end answers it too late to act.

### 3.3 Category breakdown — **S** — ✅ Built (partly)

Rebuilt 2026-09-13. Tap-through to the filtered list is done (it lands on the
category *and* the month being viewed). Month-over-month delta is not.

The rebuild fixed a correctness bug this section didn't anticipate: rows in
non-spend categories (`is_spend = false` — transfers, income) were being
ranked as expenses, so "Income & Transfers — 30% of this month" appeared as a
spending line and every percentage on the card was computed against a
denominator that included it. Those now sit in a collapsed "Not counted as
spending" section with the reason, and the ranking's denominator is spend
only. Groups with a single category no longer render a one-bar bar chart, and
per-row transaction counts (previously printed under every row *and* on the
group line) are stated once.

The dashboard's bars are honestly fine and arguably better than a pie chart
for ranking. Worth adding rather than replacing:

- A **month-over-month delta** per category (`Food ▲ 18%`) — this is where
  the insight is, not in the absolute bar.
- Tap a category → transaction list filtered to it (needs §2.2).

*Recommendation: skip the donut chart. It ranks worse than the bars you
already have and costs a charting dependency.*

### 3.4 Counterparty / merchant view — **M**

`counterparty` is populated but never surfaced. A "top merchants this month"
list, and a per-merchant screen (total, count, trend, all transactions), is a
lot of value from a column that already exists.

```sql
create index on transactions (user_id, counterparty, occurred_at desc);
```

**Charting library note:** `fl_chart` covers 3.2 and 3.3. The heatmap should
be hand-rolled with `CustomPainter` — it's a grid of rounded rects, which is
less code than bending a charting library into that shape, and you need
custom hit-testing and the three-state rendering from 3.1(b) anyway.

---

## 4. Export — **M**

CSV and JSON of the current filter selection, out through the Android share
sheet (`share_plus`).

Details that will otherwise bite:

- **Emit paisa *and* a formatted decimal.** `amount_paisa,amount` as two
  columns. Invariant 1 says money is integer paisa; a CSV that only has
  `104.50` has already lost to float rounding by the time Excel opens it.
- **Include `currency` per row.** Per §0, a bare number is ambiguous.
- **Timestamps in `Asia/Kathmandu` with the offset written out**
  (`2026-09-05T14:32:00+05:45`), never naive local time.
- **Include `user_note` and `category_name`**, resolved — a UUID in a
  spreadsheet is useless.
- **Decide about `mask`.** Account masks (`001#####234567`) in a file headed
  for WhatsApp is a different exposure than in the app. Suggest excluding by
  default with an opt-in toggle.
- Suggested filename: `expenses-2026-09.csv`, so a folder of them sorts.

*Open question: is the target audience you-in-a-spreadsheet, or an accountant?
If the latter, a fixed column set beats "export what I'm looking at".*

---

## 5. Trust and data health — **S**, and higher value than it sounds — ✅ Built

> **Follow-up, 2026-09-13.** The gap list is no longer read-only. Tapping a
> gap opens a form pre-filled with the reconciler's arithmetic — account,
> window, exact amount, and the balance the entry has to carry — so it can be
> answered from the bank app in about a minute. See plan section 9.2 and the
> amended invariant 8. Gaps also *close* now, which nothing did before:
> `resolved` was written by no code path at all.

Built as `/data-health` (reachable from the app bar's overflow menu, not yet
from the dashboard banner as originally suggested — that's a follow-up, not
a blocker). Three sections, read-only, over the same read-own RLS these
tables already had: unresolved `ledger_gaps` (account, missing amount, the
transaction window either side, when it was detected), failed
`processed_emails`, and `raw_messages` in `FAILED` or `IGNORED`. Plus a
last-sync summary reusing the existing sync_runs read.

The architecture makes a strong promise — nothing is silently dropped — and
the app currently cannot show you a single one of the mechanisms that keep
it. Three tables have no UI:

- **`ledger_gaps`** — detected balance discontinuities, i.e. "money moved and
  I never saw the email." Unresolved gaps are the single most important thing
  the app could tell you and it says nothing.
- **`processed_emails` where `status = 'FAILED'`** — emails that arrived and
  didn't parse. Each one is a missing transaction with a recorded reason.
- **`raw_messages` where `status` is `FAILED` / `IGNORED`** — the same for
  SMS. The SMS screen shows counts; nothing shows *which*.

Proposal: one **Data health** screen — open gaps with the amount and the
window they fall in, failed parses with their error, and a "last successful
sync" line — reachable from the dashboard banner. It's a list view over
tables that already exist and already have RLS. Nearly free, and it's what
makes the heatmap's "uncertain day" state (§3.1b) explainable when you tap it.

### 5.1 Merchant rules manager — **S**, closer to a bug fix — ✅ Built

Built as `/merchant-rules`: list sorted by `hit_count` descending (so a rule
doing the most damage sorts to the top), tap to edit pattern/category/
counterparty label/priority in a bottom sheet, delete with a confirmation
dialog naming what stops happening. `learned_from_user`, `hit_count`, and
`created_at` stay worker-owned — editing a rule changes what it matches, not
its provenance or hit history, and the column-level grant only covers
`pattern, category_id, counterparty_label, priority`.

The phone can `insert` into `merchant_rules` and can never see, edit, or
delete them. One mis-tap in the recategorize sheet writes a rule that
silently miscategorises that merchant on **every future sync**, and there is
no way to find it from the app or know it happened.

That's a correctness hole in the correction loop, not a missing nicety. Needs
a list screen (pattern, category, hit count, learned-from-user), plus:

```sql
create policy "update own" on merchant_rules
    for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "delete own" on merchant_rules
    for delete using (auth.uid() = user_id);
grant update (pattern, category_id, counterparty_label, priority),
      delete on merchant_rules to authenticated;
```

`hit_count` is already in the schema and makes the list self-sorting by how
much damage a wrong rule is doing.

---

## 6. Control and correction

### 6.1 Bulk actions in the review queue — **S**

Multi-select, apply one category to all. Swipe-to-confirm on a tile. After a
month away the queue is dozens of rows and one-at-a-time is the reason it
doesn't get cleared.

Guard: bulk recategorize should write **one** merchant rule per distinct
`description_raw`, not one per transaction, or a bulk action poisons
`merchant_rules` with fifty near-identical rows.

### 6.2 Budgets — **M**

Monthly cap per category, shown as a target line on the existing dashboard
bars, plus "Rs. X left, Y days to go" pacing.

New table, phone-writable (this is a preference, not a financial fact, so it
doesn't strain invariant 8):

```sql
create table budgets (
    id          uuid primary key default gen_random_uuid(),
    user_id     uuid not null references auth.users(id),
    category_id uuid not null references categories(id),
    month       date,          -- null = the recurring default
    limit_paisa bigint not null check (limit_paisa > 0),
    currency    char(3) not null default 'NPR',
    unique (user_id, category_id, month)
);
```

The `month is null` row as the recurring default, with a dated row overriding
it, avoids regenerating twelve rows a year.

### 6.3 Splitting a transaction — **L**, and think twice

One payment covering two categories (groceries + household at Bhatbhateni).
Genuinely useful, and the most invasive item here: it needs a
`transaction_splits` table, every aggregate view rewritten to prefer splits
over the parent row, and a real answer to what a reparse does to a split
transaction. It also comes closest to the phone asserting a financial fact.

*Recommendation: not until you've wanted it three times. Note when you do.*

---

## 7. Worker-side ideas

### 7.1 Recurring / subscription detection — **M**

The transfer matcher (§7.2 of the plan) already does "find pairs of
transactions that are related by amount and time". Recurring detection is the
same machinery with a different predicate: same `counterparty`, similar
amount, roughly 28–31 days apart, three or more times.

Output a `recurring_series` row, and the app gains "Rs. 4,200/month in
subscriptions" and "Netflix charged you 12 days early". High value per line
of code because the hard part — normalised counterparties — is done.

### 7.2 Daily digest push — **M** — ⚠️ Built as a *local* notification, not push

Shipped 2026-09-13 as an on-device reminder at 22:00
(`mobile/lib/core/notifications/daily_reminder.dart`), with the worker moved
to a twice-daily schedule (10:30 and 21:30) so the evening run refreshes
`ledger_gaps` half an hour before it fires.

Why not FCM, which is what this section proposed: the value here is the
*nudge*, and a local notification delivers that with no Firebase project, no
`device_tokens` table, and no service-account credentials on the worker. The
honest cost is that the text is fixed when scheduled, so it reports counts as
of the last time the app was open rather than as of the 21:30 run — the copy
says "as of your last check" instead of implying otherwise, and the app
reschedules on every resume. If that staleness ever bites, FCM is still the
answer and this section still describes it.

Plan §12 Phase 7 and §14 already frame this correctly: a **digest after each
sync**, not a transaction alert, because there is no always-on component and
pretending otherwise would be dishonest. "14 new transactions, 3 need review,
1 new ledger gap" via FCM.

### 7.3 Account balances — **S**

`balance_after_paisa` is stored and never shown. The latest non-null value
per account is a current balance, and it's a `distinct on` query:

```sql
create view v_account_balance with (security_invoker = on) as
select distinct on (user_id, account_id)
       user_id, account_id, balance_after_paisa, occurred_at
from transactions
where balance_after_paisa is not null
order by user_id, account_id, occurred_at desc;
```

Caveat worth rendering in the UI: this is the balance **as of the last
transaction the pipeline saw**, not live — same honesty rule as the
last-synced banner.

---

## 8. Suggested order

Ordered by value per unit of work, not by what's most fun:

| # | Item | § | Cost | Why here |
|---|---|---|---|---|
| 1 | Currency in the aggregates | 0 | S | ✅ Built |
| 2 | Month navigation | 2.1 | S | ✅ Built |
| 3 | Merchant rules manager | 5.1 | S | ✅ Built |
| 4 | Data health screen | 5 | S | ✅ Built |
| 5 | Filters + pagination | 2.2 | M | Prerequisite for tap-through from every chart |
| 6 | `v_daily_spend` + heatmap | 3.1 | M | The headline feature |
| 7 | Cumulative burn vs last month | 3.2 | S | Most actionable chart; free once 6 lands |
| 8 | Export | 4 | M | Wants filters (5) to be worth much |
| 9 | Bulk review actions | 6.1 | S | Quality of life, scales with backlog |
| 10 | Counterparty view | 3.4 | M | New value from an existing column |
| 11 | Budgets | 6.2 | M | Only useful once categories are trustworthy |
| 12 | Recurring detection | 7.1 | M | Worker-side, independent of all the above |

Items 1–4 are all **S** and together they're roughly one weekend that makes
the app trustworthy before it becomes pretty. That's the argument for doing
them before the heatmap, even though the heatmap is the thing you asked for.

---

## 9. Deliberately not proposed

- **A donut/pie chart of categories.** Ranks worse than the bars already
  there and costs a dependency.
- **Manual transaction entry.** Breaks invariant 8, and every cash expense
  you add by hand is one the reconciler can't check against a bank balance.
  If you want cash tracking, it should be a visibly separate ledger.
- **A home-screen widget.** Flutter Android widgets are disproportionate
  effort for a glance you get by opening the app.
- **Real-time transaction alerts.** Plan §14 rules this out by construction —
  there's no always-on component. The digest (§7.2) is the honest version.
- **Offline caching of the ledger.** Tempting, but it means a second source
  of truth on the device and a staleness bug class. Revisit only if you're
  regularly opening the app without connectivity.

---

## 10. Questions for you

1. Foreign currency: convert to NPR at ingest, or never mix into one total?
   (§0 — blocks the ordering above.)
2. Heatmap: intensity by amount spent, or by transaction count like GitHub?
3. Heatmap window: 12 months with horizontal scroll, or 6 months fitted to
   screen width?
4. Export audience: you in a spreadsheet, or someone else?
5. Is there anything in §9 you actually want, that I've argued against?

---

*One correction to the main plan while you're reviewing: §15 lists "Android
SMS as a second source — Not in v1". That decision was reversed and shipped;
§8.5 is now the live description.*
