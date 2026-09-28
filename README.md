# Expense Tracker

An automatic expense tracker for Nepal. It reads the transaction-notification
emails and SMS your bank already sends you, turns them into a correct ledger,
and shows where the money went — with no manual entry, no server to run, and
no email bodies leaving your laptop.

Built around eSewa, Nabil Bank and Laxmi Sunrise, but the parser layer is the
extension point: [adding your own bank](docs/ADDING_A_PARSER.md) is a single
file and a fixture.

Where a bank reports the same transaction over both email and SMS — Nabil does
— both are read, and they **collapse onto one transaction** rather than
double-counting it. See [Two transports, one
transaction](docs/EXPENSE_TRACKER_PLAN.md#two-transports-one-transaction).

> **Status:** working personal project, published so others can run and extend
> it. It is not a hosted service and there is nothing to sign up for — you run
> the worker on your own machine against your own Supabase project.

---

## How it works

There is no backend server. Three pieces, and a deliberate split between them:

```
  ┌─────────────┐   IMAP    ┌──────────────────────┐   rows    ┌──────────┐
  │    Gmail    │──────────▶│   Local batch worker │──────────▶│ Supabase │
  └─────────────┘           │   (your laptop)      │           │ (ledger) │
                            │                      │           └─────┬────┘
  ┌─────────────┐  staged   │  parse · dedupe      │                 │ reads
  │  Bank SMS   │──────────▶│  match transfers     │                 ▼
  │  (phone)    │           │  reconcile · label   │           ┌──────────┐
  └─────────────┘           └──────────────────────┘           │  Flutter │
                                                               │   app    │
                                                               └──────────┘
```

| Stays on your laptop | Goes to Supabase |
| --- | --- |
| Raw `.eml` archive | `accounts`, `transactions`, `categories` |
| All HTML parsing | `merchant_rules`, `transfer_groups`, `ledger_gaps` |
| Transfer matching, reconciliation | `processed_emails` (metadata only — no bodies) |
| Local LLM categorization (Ollama) | `sync_runs`, aggregate views the phone reads |
| Gmail credentials | *(never)* |

Everything interpretive happens locally. Supabase never sees an email body, a
subject line, or a mail credential — it sees rows.

## What makes it more than a dashboard

Anyone can build the dashboard. The work is in the line underneath it:

> email → correct transaction → no duplicates → no double-counted transfers →
> no silently missing rows → sensible category

So the project takes some firm positions, documented as
[invariants](docs/EXPENSE_TRACKER_PLAN.md#2-invariants):

- **Money is integer paisa**, never float.
- **Every run is idempotent**, enforced by database constraints rather than
  application logic — run it twice, on two machines, after a three-week gap;
  nothing changes that shouldn't.
- **A transfer is not an expense.** Money moving between your own accounts
  nets to zero and is excluded from spend totals.
- **Nothing is silently dropped.** An email that doesn't parse becomes a
  `FAILED` row with the error attached, not a gap in your ledger.
- **Balance reconciliation.** Consecutive balances that don't add up mean a
  transaction the pipeline never saw; those become `ledger_gaps` you can fill
  in by hand rather than a total that's quietly wrong.
- **One transaction, however many times the bank tells you about it.** The SMS
  and the email are reconciled into a single row by database constraint, with
  each contributing what the other lacks.

## Repository layout

```
worker/         Python batch worker — IMAP, parsers, pipeline, CLI
  src/expense_tracker/
    ingest/       IMAP fetch, archive, watermark, backfill windows
    parsers/      one module per bank template  ← add your bank here
    pipeline/     dedupe, transfers, reconcile, categorize
    store/        the only code that knows about Postgres
  tests/          offline tests + a real-shaped fixture corpus
supabase/       migrations and seed data
mobile/         Flutter client (reads Supabase directly, no API layer)
scripts/        setup-wizard.sh — walks you through provisioning
docs/           setup, CLI reference, parser guide, full design doc
```

## Getting started

Full walkthrough: **[docs/SETUP.md](docs/SETUP.md)**. The short version:

```bash
git clone https://github.com/<you>/expense-tracker.git
cd expense-tracker

# 1. Worker
cd worker
python3 -m venv .venv && .venv/bin/pip install -e '.[dev]'
.venv/bin/python -m pytest          # 157 tests, fully offline

# 2. Provision Supabase + credentials (interactive, ~10 minutes)
cd .. && ./scripts/setup-wizard.sh

# 3. See how much mail is there, then pull it
cd worker
.venv/bin/expense-tracker inbox --last 1y
.venv/bin/expense-tracker backfill
```

The test suite needs no network, no database, and no credentials — clone and
run it to see the parsers work before setting anything up.

## The CLI

Full reference: **[docs/CLI.md](docs/CLI.md)**.

| Command | What it does |
| --- | --- |
| `inbox --last 1y` | How many emails are in a window — a SEARCH, downloads nothing |
| `backfill` | Asks how far back to pull, shows the cost, then syncs |
| `sync` | The unattended daily run; resolves its own window |
| `status` | Last run, unparsed count, open ledger gaps |
| `review` | Terminal queue for transactions needing a category |
| `reparse` | Re-run current parsers over the local archive, offline |
| `retention` | Delete raw `.eml` past the retention window |

Deciding how much to fetch is its own step, on purpose:

```console
$ expense-tracker inbox --last 1y
window: since 2025-09-15 (about 12 months back)
  esewa.com.np                 214 message(s)
  nabilbank.com                487 message(s)
  total                        701 message(s)

$ expense-tracker backfill --last 1y --max-emails 200
```

## Adding your own bank

The parser layer is deliberately small and pure — no network, no database, no
config. A parser is a class with `matches()` and `parse()`, plus one real
email saved as a fixture. See
**[docs/ADDING_A_PARSER.md](docs/ADDING_A_PARSER.md)**.

## Privacy

This code handles your financial data, so the design is explicit about where
everything lives. See [SECURITY.md](SECURITY.md). In short: raw mail never
leaves your machine, Supabase holds normalized rows behind row-level security,
and the fixture corpus in this repo is synthetic — no real account data ships
with the project.

## Contributing

Bug reports and bank parsers are both very welcome. See
[CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE).
