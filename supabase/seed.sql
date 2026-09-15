-- Starter categories. See docs/EXPENSE_TRACKER_PLAN.md section 10.
-- Run once per user_id after their first auth signup (categories.user_id has
-- no default -- this is a template to adapt with the real user_id, not a
-- script that runs as-is against a fresh project).
--
-- :'user_id' is a psql variable. Two ways to supply it:
--
--   psql "$EXPENSE_TRACKER_DB_URL" -v user_id=<your-auth-uuid> -f supabase/seed.sql
--
-- or, in the Supabase dashboard's SQL editor (which cannot bind variables),
-- replace every :'user_id' with your quoted UUID before running:
--
--   sed "s/:'user_id'/'<your-auth-uuid>'/g" supabase/seed.sql | pbcopy
--
-- Grouped via parent_id: groups are headings, and transactions are filed
-- under the categories inside them. "Other" is the one ungrouped catch-all.
-- Mirrors migrations/20260911010000_category_groups.sql, which converted an
-- existing flat list to this shape.

insert into categories (user_id, name, is_spend) values
    (:'user_id', 'Food & Drink',       true),
    (:'user_id', 'Health',             true),
    (:'user_id', 'Home & Bills',       true),
    (:'user_id', 'Transport',          true),
    (:'user_id', 'Shopping',           true),
    (:'user_id', 'Subscriptions',      true),
    (:'user_id', 'Travel',             true),
    (:'user_id', 'Education',          true),
    (:'user_id', 'Fun & Social',       true),
    (:'user_id', 'Family & People',    true),
    (:'user_id', 'Fees & Cash',        true),
    (:'user_id', 'Investments',        false),
    (:'user_id', 'Income & Transfers', false),
    (:'user_id', 'Other',              true);

insert into categories (user_id, name, is_spend, parent_id)
select grp.user_id, c.name, grp.is_spend, grp.id
from (values
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
join categories grp on grp.user_id = :'user_id' and grp.name = c.group_name;

-- Starter merchant_rules. Every pattern below was checked against a real
-- remarks/counterparty string from the Phase 0 fixture corpus
-- (worker/tests/fixtures/expected.yaml) -- see docs/EXPENSE_TRACKER_PLAN.md
-- section 8.4's channel table for where each one came from. These are an
-- example starting set, not universal Nabil/eSewa rules -- e.g. the
-- "NABIL BANK LTD." rule only makes sense if Nabil is your linked bank, and
-- the EXAMPLE * patterns are placeholders matching the test fixture corpus.
-- Expect to replace most of these with your own merchants; `expense-tracker
-- review` writes new ones for you as you categorize.
--
-- Deliberately NOT seeded: a blanket rule for "eSewa Load {phone}" or
-- "ESW DLA:" -> Transfer. Phase 3 found that at least two real "eSewa Load"
-- debits go to a phone number that isn't the account owner's own eSewa ID --
-- i.e. real spending, not a transfer. Categorizing those as Other (below)
-- keeps them counted as spend (safe default) rather than silently
-- mislabeling them Transfer and hiding them from totals; a confirmed
-- self-transfer still gets correctly excluded from spend by the transfer
-- matcher (section 7.2) regardless of category, since excluded_from_spend
-- and category are independent fields.

insert into merchant_rules (user_id, pattern, category_id, priority, learned_from_user)
select :'user_id', pattern, (select id from categories where user_id = :'user_id' and name = category_name), priority, false
from (values
    ('^ATM WDL',                       'Cash Withdrawal',     100),
    ('^C-ASBA Fee',                    'Bank Fees',           100),
    ('^CASBA allot',                   'IPO & Shares',        100),
    ('^salary for',                    'Salary',              100),
    ('eSewa Load|^ESW DLA:',           'Other',               100),
    ('GOOGLE \*CLAUDE',                'AI Tools',            100),
    ('OPENAI \*CHATGPT',               'AI Tools',            100),
    ('PAYPAL \*CONTABO',               'Cloud & Hosting',     100),
    ('EXAMPLE EDUCATION',           'Tuition & Fees',      100),
    ('EXAMPLE HEALTH CARE',              'Hospital & Doctor',   100),
    ('EXAMPLE PHARMACY',             'Medicine & Pharmacy', 100),
    ('NABIL BANK LTD\.',               'Transfer',            100)
) as starter_rules(pattern, category_name, priority);

-- ---------------------------------------------------------------- accounts
-- Only Laxmi. Nabil and eSewa accounts create themselves the first time the
-- worker parses a transaction from them (get_or_create_account), so seeding
-- those would just race the pipeline to the same row.
--
-- Laxmi is the exception because nothing will ever create it: it sends no
-- email (plan section 8.5) and its SMS parser is still awaiting fixtures, so
-- every Laxmi transaction is one you type in by hand -- which needs an
-- account to file against. See migration 20260913010000, including its note
-- about re-checking the mask once that parser lands.
insert into accounts (user_id, kind, institution, mask, display_name, currency) values
    (:'user_id', 'BANK',   'LAXMI', '', 'Laxmi Bank', 'NPR'),
    -- Cash: no parser will ever create this one, and it is what the
    -- manual-entry form exists for. WALLET rather than a third enum value --
    -- see migration 20260913030000 for why.
    (:'user_id', 'WALLET', 'CASH',  '', 'Cash',       'NPR')
on conflict (user_id, institution, mask) do nothing;
