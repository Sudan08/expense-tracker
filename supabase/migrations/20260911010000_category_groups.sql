-- Category groups.
--
-- categories.parent_id has existed since the initial schema but nothing used
-- it. This turns the flat starter list into groups (parent rows) holding the
-- categories transactions are actually filed under. transactions and
-- merchant_rules reference category ids, so existing rows are renamed and
-- reparented in place rather than replaced -- every row pointing at them
-- carries over.
--
-- A group is any category some other category points at. Transactions still
-- pointing at a row that became a group (old "Health", "Shopping", ...) are
-- moved to a child by `expense-tracker categorize --all`, not here -- which
-- child is a per-transaction judgement.

-- ------------------------------------------------------------ 1. renames
-- Same meaning, new name. Health, Shopping, Transport and Travel keep their
-- names and simply become groups in step 2.
update categories set name = 'Restaurants'     where name = 'Food';
update categories set name = 'Bank Fees'       where name = 'Fees';
update categories set name = 'Movies & Events' where name = 'Entertainment';
update categories set name = 'Tuition & Fees'  where name = 'Education';
update categories set name = 'Home & Bills'    where name = 'Bills';

-- ------------------------------------------------------------ 2. groups
insert into categories (user_id, name, is_spend)
select u.user_id, g.name, g.is_spend
from (select distinct user_id from categories) u
cross join (values
    ('Food & Drink',       true),
    ('Health',             true),
    ('Home & Bills',       true),
    ('Transport',          true),
    ('Shopping',           true),
    ('Subscriptions',      true),
    ('Travel',             true),
    ('Education',          true),
    ('Fun & Social',       true),
    ('Family & People',    true),
    ('Fees & Cash',        true),
    ('Investments',        false),
    ('Income & Transfers', false)
) as g(name, is_spend)
on conflict (user_id, name) do update set is_spend = excluded.is_spend, parent_id = null;

-- ------------------------------------------------------------ 3. categories
-- Existing leaves (Groceries, Restaurants, Salary, ...) hit the conflict and
-- just get their group. "Other" stays ungrouped, as the catch-all.
insert into categories (user_id, name, is_spend, parent_id)
select u.user_id, c.name, grp.is_spend, grp.id
from (select distinct user_id from categories) u
cross join (values
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
join categories grp on grp.user_id = u.user_id and grp.name = c.group_name
on conflict (user_id, name) do update set parent_id = excluded.parent_id, is_spend = excluded.is_spend;

-- ------------------------------------------------------------ 4. merchant_rules
-- A rule filing into a row that just became a group would keep putting new
-- transactions on the group itself. Point those at the specific category.
update merchant_rules r
set category_id = leaf.id
from (values
    ('GOOGLE \*CLAUDE',                                   'AI Tools'),
    ('OPENAI \*CHATGPT',                                  'AI Tools'),
    ('PAYPAL \*CONTABO',                                  'Cloud & Hosting'),
    ('EXAMPLE HEALTH CARE',                                 'Hospital & Doctor'),
    ('EXAMPLE PHARMACY',                                'Medicine & Pharmacy'),
    ('^CASBA allot',                                      'IPO & Shares'),
    ('MPAY EXAMPLEBK;55500000044,00100002234567,laptop,S', 'Electronics & Gadgets')
) as m(pattern, leaf_name)
join categories leaf on leaf.name = m.leaf_name
where leaf.user_id = r.user_id and r.pattern = m.pattern;
