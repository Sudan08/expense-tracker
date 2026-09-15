# CLI reference

```bash
cd worker
.venv/bin/expense-tracker --help
```

All commands read `~/.expense-tracker/config.toml` and `~/.expense-tracker/.env`
(see [SETUP.md](SETUP.md#5-mail-credentials)). Add `--verbose` before the
command for debug logging.

---

## Choosing how much mail to fetch

`sync` resolves its own start date from the last successful run. That is right
for a scheduled daily job and wrong for every other situation — a first
backfill, a re-pull after fixing a parser, a laptop that's been off for
months. Three commands exist to make that choice explicit.

### `inbox` — how much is there?

```bash
expense-tracker inbox [--last WINDOW]
```

Counts what a fetch *would* return, without returning any of it. This is an
IMAP `SEARCH`: one round trip per sender regardless of how wide the window,
no message bodies, no database, no writes.

```console
$ expense-tracker inbox --last 1y
window: since 2025-09-15 (about 12 months back)
  esewa.com.np                 214 message(s)
  nabilbank.com                487 message(s)
  total                        701 message(s)

To ingest these: expense-tracker backfill --last 1y
(already-seen messages are deduped, so overlapping runs are free)
```

Run it first when you have no idea whether a year of mail means 40 messages
or 4,000. Defaults to `--last 30d`.

### `backfill` — pick a window, then sync it

```bash
expense-tracker backfill [--last WINDOW] [--max-emails N] [--yes] [--no-ollama]
```

With no flags it prompts:

```console
$ expense-tracker backfill
How far back should I fetch email from?

  1) Last 7 days
  2) Last 30 days
  3) Last 3 months
  4) Last 6 months
  5) Last 1 year
  6) Everything since account_start
  c) Custom -- a duration (e.g. 45d, 8w) or an ISO date (2026-01-01)

Choice [2]: 5

Window: since 2025-09-15 (about 12 months back)
  esewa.com.np                 214 message(s)
  nabilbank.com                487 message(s)
  total                        701 message(s)

Download and parse 701 message(s)? [Y/n]:
```

It shows the cost before fetching, and `--yes` skips the confirmation for
scripts. Typing a window (`3m`) straight past the menu works too.

Because every step is idempotent, **choosing too wide a window is free** — the
re-fetched messages are deduped and insert nothing new. When in doubt, go
wider.

### Window specs

Anywhere `WINDOW` appears:

| Form | Meaning |
| --- | --- |
| `7d`, `45d` | days back from now |
| `2w`, `8w` | weeks back |
| `3m`, `6m` | months back (31 days each) |
| `1y`, `2y` | years back (366 days each) |
| `2026-01-01` | from this ISO date |
| `all` | from `worker.account_start` in `config.toml` |

Months and years are approximated in days on purpose: the only consumer is an
IMAP `SINCE` search whose resolution is a whole day, and overshooting slightly
is the safe direction — extra overlap is deduped by `Message-ID`.

### Taking a big backfill in bites

`--max-emails N` caps how many messages one run downloads, newest first:

```bash
expense-tracker backfill --last all --max-emails 200
```

Newest-first matters: the recent months — the ones you actually look at —
arrive first, instead of the ledger filling in from years ago forward.

**One sharp edge, which the CLI warns about.** A successful run advances the
watermark, so a later plain `sync` starts from *now* and will not pick up the
older remainder. Pass the window explicitly each time:

```console
$ expense-tracker backfill --last all --max-emails 200
fetched=200 parsed=196 failed=0 ignored=4 txns_inserted=196 still_review=31
Stopped at the cap, so older mail in this window is still unfetched.
Run `expense-tracker backfill --last all --max-emails 200` again to take the next bite.
```

---

## `sync`

```bash
expense-tracker sync [--since DATE] [--last WINDOW] [--max-emails N] [--no-ollama]
```

The unattended run: fetch, archive, parse, dedupe, match transfers, reconcile
balances, categorize, push. This is what the launchd agent and systemd timer
call, with no arguments.

With no window flags it starts from `(last successful run − 3 days)`, or
`account_start` on a first run. The three-day overlap is deliberate — there is
no IMAP UID cursor, because `UIDVALIDITY` resets break cursors and a broken
cursor is exactly where silent data loss lives. Redundant messages are deduped
by `Message-ID`.

It refuses to run twice concurrently (a lock file in `~/.expense-tracker/`).
An unreachable IMAP host or database is not treated as a failure: it retries
three times, then exits **0** quietly and lets the next scheduled run catch up.
Any other error exits non-zero.

`--no-ollama` skips the local LLM fallback; rules-based categorization still
runs and unmatched rows land in the review queue.

## `status`

```console
$ expense-tracker status
last sync (laptop, OK): 2026-09-15T21:30:04+00:00 fetched=12 parsed=11 failed=0 inserted=11
unparsed emails (FAILED): 0
open ledger gaps: 3
```

- **FAILED** — a parser matched and raised. Nothing was dropped; the error is
  stored. Fix the parser, then `reparse`.
- **open ledger gaps** — consecutive balances that don't add up, meaning a
  transaction the pipeline never saw. Fill these in from the app.

## `review`

```bash
expense-tracker review [--limit N]
```

Terminal queue for transactions no rule matched. Assigning a category also
writes a `merchant_rules` row, so the next sync matches it locally without
consulting the model. Enter skips, `s` stops.

## `categorize`

```bash
expense-tracker categorize [--limit N] [--all] [--no-ollama]
```

Runs categorization over existing rows without a sync. `--all` re-files every
transaction, keeping categories you picked yourself — use it after changing
the category list.

## `reparse`

```bash
expense-tracker reparse [--template KEY]
```

Re-runs current parsers over the local `.eml` archive. No IMAP fetch, so it is
fast and free — this is the loop to use while iterating on a parser.
`--template nabil.txn_alert` narrows it to one template.

## `import-esewa-statement`

```bash
expense-tracker import-esewa-statement ~/Downloads/statement.xls
```

Stages an eSewa statement export (Profile → Statement → Excel) for the next
`sync` to parse. eSewa emails nothing for wallet-to-wallet transfers, so this
is the only way that transaction type enters the ledger. Safe to re-run over
overlapping exports.

## `retention`

```bash
expense-tracker retention
```

Deletes raw `.eml` files older than the retention window whose transactions
are all `CONFIRMED`. Never touches the database — only the local cache. Not
scheduled automatically; run it occasionally.
