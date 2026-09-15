# Automatic Expense Tracker — Project Plan

> **This is the design document, not the getting-started guide.** It records
> the data model, every template spec, and the reasoning behind each
> architectural decision. For installing and running the project see
> [SETUP.md](SETUP.md); for the commands see [CLI.md](CLI.md); for teaching it
> a new bank see [ADDING_A_PARSER.md](ADDING_A_PARSER.md).
>
> It is written as a forward-looking plan, in phases. Phases 0-6 are built and
> shipped -- where the text says "next" or "not yet", read it as the record of
> a decision made at the time rather than as current status.

**Owner:** project maintainer
**Version:** v2 — local batch worker, cloud read-only
**Last updated:** 2026-09-07

An expense tracker for Nepal that ingests transaction notification emails from
eSewa and Nabil Bank, turns them into a correct ledger, and shows where the money
went — without manual entry, without a server, and without your email bodies
leaving your laptop.

---

## 0. The one thing to keep in mind

The dashboard is not the product. Anyone can build the dashboard in a weekend.

The product is this:

```
email  →  correct transaction  →  no duplicates  →  no double-counted transfers
       →  no silently missing rows  →  sensible category
```

Every phase below is ordered by how much it contributes to that line.

---

## 1. The model

There is no backend server. There are exactly three pieces:

**1. A local batch worker** on your laptop. Runs once a day, whenever the machine
happens to be awake. Talks to Gmail, parses, normalizes, categorizes, and pushes
finished rows to Supabase. If the laptop is off for a week, the next run catches up.

**2. Supabase** as the shared ledger. It holds structured financial data only —
no email bodies. It is the single source of truth for the phone.

**3. A mobile client** that reads Supabase directly through the Supabase SDK.
No API layer, no custom endpoints.

The split that makes this work:

| Lives on your laptop | Lives in Supabase |
|---|---|
| Raw `.eml` archive | `accounts`, `transactions`, `categories` |
| All HTML parsing | `merchant_rules`, `transfer_groups`, `ledger_gaps` |
| Transfer matching, reconciliation | `processed_emails` (metadata only, no bodies) |
| Ollama categorization | `sync_runs` |
| Gmail credentials, `service_role` key | Aggregate views the phone reads |

Everything interpretive happens locally. Supabase never sees an email, a subject
line body, or a Gmail credential. It sees rows.

**Gmail is your durable archive.** The local `raw/` directory is a cache that makes
reparsing cheap. If the laptop dies, you re-fetch from Gmail and rebuild — the
`dedupe_key` constraint means the rebuild is safe to run against the existing data.

---

## 2. Invariants

Decide these once, never revisit.

1. **Money is `bigint` paisa.** Never float. `NPR 10,000.00` → `1000000`. Format
   only at the render boundary.
2. **Time is `timestamptz`, stored UTC, displayed `Asia/Kathmandu`.** Also record
   the *precision* the source gave: eSewa gives seconds, Nabil gives minutes.
   Transfer matching needs to know which.
3. **Raw email never leaves the laptop.** Only normalized rows go to Supabase.
4. **Every parser run is versioned.** `parser_version` on transactions, so
   "reparse everything the v3 Nabil parser touched" is one query.
5. **Every run is idempotent.** Running the worker twice, or on two machines,
   or after a three-week gap, changes nothing that shouldn't change. Enforced by
   unique constraints in the database, not by application logic.
6. **Nothing is silently dropped.** An email that doesn't parse becomes a `FAILED`
   row in `processed_emails` with the error attached.
7. **A transfer is not an expense.** Your own money moving between your own
   accounts nets to zero and is excluded from spend totals.
8. **The phone never writes parser-derived facts.** *(Amended 2026-09-13 --
   see below for what it used to say and why it changed.)* It can
   recategorize, confirm, and attach its own note. It may stage *raw
   material* -- bank SMS text into `raw_messages` (section 8.5) -- because
   raw text is not a fact about the ledger until a parser has read it, and
   only the worker runs parsers. It may also record its **own assertions**:
   a transaction the user typed themselves, tagged `entry_source = 'MANUAL'`
   (section 9.2). It can never **edit or delete** any transaction, manual
   ones included, and it can never make a row it wrote look like one a
   parser produced.

   > **What this used to say, and why it changed.** The original read "the
   > phone never writes financial facts... it cannot insert or delete
   > transactions." That was right while every row came from a parser. But
   > section 7.3's reconciler exists precisely because the ledger *isn't*
   > complete: `ledger_gaps` is a list of transactions the bank definitely
   > made and the pipeline definitively never saw, and before this the only
   > thing the app could do with that list was display it. Nothing recovers
   > those rows except a human reading their bank app.
   >
   > The property worth protecting was never "the phone cannot insert" -- it
   > was "the phone cannot rewrite history, and cannot pass its guesses off
   > as the bank's statements." Both survive, enforced by the database rather
   > than by the app: a `MANUAL` row cannot reference a source message, its
   > `parser_version` is pinned to 0 and the column isn't granted, its
   > `dedupe_key` must live in the `manual:` namespace so it can never
   > swallow a real transaction still in flight, and `authenticated` still
   > holds no `delete` and no `update` on amount, date, or direction.
   >
   > What it does widen: a stolen phone can now add plausible-looking rows.
   > It still cannot alter or remove a single existing one, which is the
   > property that actually protects the history. Accepted deliberately.
9. **The bank's words and the user's words are different columns.**
   `description_raw` belongs to the parser and a reparse overwrites it;
   `user_note` belongs to the human and nothing in the worker touches it.

---

## 3. Architecture

```
                        ┌──────────────────────────────┐
                        │        Your laptop           │
                        │   (Arch / MacBook, daily)    │
   Gmail ──── IMAP ────▶│                              │
   eSewa                │  1. fetch unseen messages    │
   Nabil                │  2. archive raw .eml locally │
                        │  3. parse → NormalizedTxn[]  │
                        │  4. dedupe                   │
                        │  5. match transfers          │
                        │  6. reconcile balances       │
                        │  7. categorize (rules→Ollama)│
                        │  8. push rows                │
                        └──────────────┬───────────────┘
                                       │  service_role key
                                       ▼
                        ┌──────────────────────────────┐
                        │          Supabase            │
                        │   Postgres + RLS + Realtime  │
                        │                              │
                        │  transactions, accounts,     │
                        │  categories, rules, views    │
                        └──────────────┬───────────────┘
                                       │  anon key + RLS
                        ┌──────────────┴───────────────┐
                        ▼                              ▼
                 Mobile client                  Web (optional)
                 read + recategorize            same SDK
```

Local archive layout:

```
~/.expense-tracker/
├── raw/
│   └── 2026/08/
│       ├── 3f9a1c...e2.eml      # filename = sha256(Message-ID)
│       └── b71d04...9a.eml
├── config.toml
└── .env                          # IMAP app password, service_role key
```

No local database. The filename *is* the index — an existence check is one `stat`.
`processed_emails` in Supabase records *why* something was skipped, which is the
only thing the filesystem can't tell you.

---

## 4. Supabase or Firebase

**Supabase.** Not close.

| | Supabase | Firebase |
|---|---|---|
| Data model | Postgres — the schema in §9 runs as-is | Firestore documents; no joins, no `GROUP BY` |
| Monthly spend by category | one SQL view | denormalize and maintain aggregate docs by hand |
| Transfer groups, FK integrity | native | application-enforced, i.e. eventually wrong |
| Reparse / bulk correction | one `UPDATE` | batched writes, 500 per batch |
| Access control | RLS, column-level grants | security rules, coarser |
| Local worker access | `psycopg` or the Python SDK | Admin SDK |

Your data is relational and your queries are analytical. Firestore is the wrong
shape for both, and you'd spend the project fighting it.

**You can still use Firebase Cloud Messaging for push.** FCM is independent of
Firestore. Phase 6 uses Supabase for data and FCM for notifications, and that's a
normal combination.

---

## 5. Stack

| Layer | Choice | Note |
|---|---|---|
| Worker | Python 3.12, CLI (Typer or argparse) | Not FastAPI. There is no server. |
| Mail | `imap-tools` + Gmail app password | App passwords still work on personal accounts with 2FA. Behind a `MailSource` protocol. |
| HTML parsing | `selectolax` or BeautifulSoup + lxml | Not regex over raw HTML. |
| Validation | Pydantic v2 | Also validates Ollama output. Never trust raw model JSON. |
| DB client | `supabase-py`, or `psycopg` straight to the Postgres connection string | `psycopg` is better for bulk upserts. |
| Migrations | Supabase CLI (`supabase migration new`) | Keeps schema in git. |
| Scheduling | `systemd --user` timer (Arch) / `launchd` (macOS) | Both re-run missed jobs on wake. See §6.4. |
| Local LLM | Ollama | Same machine as the worker. No networking problem to solve. |
| Mobile | Flutter + `supabase_flutter` | Phase 6. |
| Web (optional) | Next.js + `@supabase/supabase-js` | Phase 5 if you want a desktop view sooner. |

Dropped from v1 of this plan: FastAPI, the VPS, Render, Neon, any API layer.

---

## 6. The daily sync run

This is now the heart of the system. Get it right and everything else is UI.

### 6.1 The run

```
expense-tracker sync
```

```
 1. acquire local flock            → refuse to run twice concurrently
 2. resolve watermark
 3. IMAP SEARCH since watermark, from esewa.com.np / nabilbank.com
 4. for each message:
        skip if raw/<hash>.eml already exists
        write raw .eml to local archive
        route by (from, subject, body marker) → parser
        parse → NormalizedTxn[]   |   record FAILED with the error
 5. upsert transactions           → ON CONFLICT (dedupe_key) DO NOTHING
 6. upsert processed_emails       → metadata only
 7. transfer matcher over the last 60 days
 8. balance reconciler per bank account → ledger_gaps
 9. categorize NEEDS_REVIEW       → rules, then Ollama if available
10. write sync_runs row: counts, errors, duration
11. release lock
```

Other subcommands worth having from the start:

```
expense-tracker status                    # last run, unparsed count, open gaps
expense-tracker sync --since 2025-01-01   # backfill
expense-tracker reparse --template nabil.txn_alert   # re-run parsers over local raw/
expense-tracker review                    # TUI for the NEEDS_REVIEW queue
expense-tracker retention                 # drop raw/ files past the 12mo/CONFIRMED bar, section 11.3
```

`reparse` works entirely offline against the local archive. That's the payoff for
keeping raw `.eml` around.

### 6.2 The watermark

Do **not** use an IMAP UID cursor. `UIDVALIDITY` resets break it, and a resettable
cursor across multi-week gaps is exactly where silent data loss lives.

```
since = (last successful sync_runs.completed_at  or  account_start) − 3 days
```

A three-day overlap window, then dedupe by Message-ID. Overlap costs a handful of
redundant `stat` calls. A missed cursor costs you transactions you never notice.

Laptop off for three weeks? `since` is three weeks ago. IMAP handles the range
fine at these volumes.

### 6.3 Running on two machines

You have an Arch laptop and a MacBook. Both may run the worker. That's fine and
requires no coordination — the unique constraints on `dedupe_key` and
`processed_emails.message_id` make concurrent runs safe. The second machine will
just insert nothing.

The only asymmetry: each machine builds its own local `raw/` archive. If you care,
`rsync` them occasionally; if not, either one can rebuild from Gmail.

### 6.4 Scheduling

Both of these re-run a missed job when the machine next wakes, which is the exact
semantic you want.

**Arch (systemd user timer):**

```ini
# ~/.config/systemd/user/expense-sync.timer
[Timer]
OnCalendar=*-*-* 10:30:00
OnCalendar=*-*-* 21:30:00
Persistent=true        # ← runs on next boot if the machine was off
```

**macOS (launchd):**

```xml
<key>StartCalendarInterval</key>
<array>
  <dict><key>Hour</key><integer>10</integer><key>Minute</key><integer>30</integer></dict>
  <dict><key>Hour</key><integer>21</integer><key>Minute</key><integer>30</integer></dict>
</array>
```

launchd fires a missed `StartCalendarInterval` job on wake. Note the **array**:
a bare `<dict>` is the single-run form, and two `Hour` keys inside one dict is
silently last-wins rather than an error.

**Why twice, and why 21:30.** The morning run catches overnight email. The
evening run exists for the phone: it refreshes `ledger_gaps` half an hour
before the app's 22:00 reminder fires (section 9.2), so the list of gaps you
sit down to fill in is tonight's rather than this morning's. A second run
costs nothing — invariant 5 means the same emails insert nothing the second
time.

Add `--if-network` behaviour: if IMAP is unreachable, exit 0 quietly and let the
next run pick it up. A failed sync is not an error condition, it's Tuesday.

**What "unreachable" has to cover** (learned the hard way, 2026-09-07). Both
legs of a run can be unreachable, and both are routine:

- **IMAP.** Not just a connection that never opens. A connection that dies
  *mid-fetch* is the common case, because launchd fires the missed job the
  instant the machine wakes and wifi has not associated yet. `imaplib` signals
  that with `IMAP4.abort` ("socket error: EOF", "Broken pipe"), which is **not**
  an `OSError` -- catching only `OSError` let it escape as a crash. `IMAP4.error`
  (its parent) stays uncaught: that is a real protocol or credential problem.
- **Postgres.** One connection is held across the whole run, including a slow
  IMAP fetch and a slower Ollama pass, so Supabase's pooler drops it and a wake
  invalidates it. Every statement reconnects once (`store/supabase.py`
  `_execute`); plain INSERTs with no `ON CONFLICT` opt out, since a retry could
  double-insert. Client-side failures (no SQLSTATE) are `StoreUnavailable`;
  server-side refusals (SQLSTATE set, e.g. a bad password) stay loud.

Three supporting rules:

- **Wait the network out before giving up.** One attempt at wake fails every
  time and forfeits the day, so `sync` retries the whole run 3x, 30s apart,
  before taking the quiet exit 0. Retrying is safe: the pipeline is idempotent
  by DB constraint (invariant 5) and unavailability is raised before any message
  is processed.
- **Closing out the `sync_runs` row must never become the failure.** It runs in
  a `finally`, i.e. exactly when the run has already blown up, so it is the next
  thing to hit the dead connection -- and its exception replaces the real cause.
  Log it and move on. (Before this, failed runs left rows with both
  `completed_at` and `error` NULL: the error was lost.)
- **Every log line carries a timestamp.** The agent's stdout/stderr go to an
  append-only file that is never rotated, so without one there is no way to tell
  from the log whether a given day's run happened at all.

---

## 7. The three hard problems

### 7.1 Duplicates

Two guards, both database-enforced:

- `processed_emails.message_id` unique — a message is never processed twice.
- `transactions.dedupe_key` unique — a transaction is never created twice, even
  from two different emails or a reparse.

Key construction:

```
esewa   →  esewa:{reference}                       # e.g. esewa:1PWB11H
nabil   →  nabil:{mask}:{occurred_at:%Y-%m-%dT%H:%M}:{direction}:{amount_paisa}:{sha1(remarks)[:8]}
```

Nabil gives no reference number, so the composite is the best available. The
remarks hash matters — two identical-amount transactions in the same minute are
rare but not impossible.

### 7.2 Transfers — the one that silently corrupts your totals

Your 31 Aug example, concretely:

```
09:45:53  eSewa   CREDIT  NPR 1,000  "fund load from NABIL BANK LTD."   ref 1PWB11H
~09:45    Nabil   DEBIT   NPR 1,000  remarks likely containing ESEWA/FONEPAY/IPS
```

One movement of NPR 1,000. Not NPR 2,000 of activity, and NPR 0 of spending.
Per-source dedup will never catch this — different sources, unrelated references.

```
candidate pair (A, B) where
    A.direction = DEBIT  and  B.direction = CREDIT
    A.amount_paisa = B.amount_paisa
    A.account_id  ≠ B.account_id
    |A.occurred_at − B.occurred_at| ≤ 30 min
```

Score it, don't just accept it:

- `+0.5` base for a candidate pair
- `+0.3` if either side's text names the other's institution
  (the eSewa row literally says `NABIL BANK LTD.`)
- `+0.2` if the gap is under 5 minutes
- `−0.3` if more than one candidate matches

`≥ 0.8` → auto-link into a `transfer_group`, set `excluded_from_spend = true` on
both legs. Below that → review queue. Never silently guess with your own money.

Batch processing makes this *easier*, not harder — the matcher sees both legs in
the same run instead of having to wait for the second one to arrive.

### 7.3 Missing emails

Nabil's Available Balance turns the ledger into a checkable chain. Per bank
account, ordered by time, over consecutive rows that both carry a balance:

```
expected = prev.balance_after_paisa + (curr.direction = CREDIT ? +amt : −amt)
if expected ≠ curr.balance_after_paisa:
    → a transaction is missing; the gap is exactly (curr.balance_after − expected)
```

This matters more in a daily-batch design than it did in a streaming one. You are
now relying on a once-a-day process to have seen everything, so you want an
independent check that says so. Write failures to `ledger_gaps` and surface the
count on the dashboard.

**Closing a gap** (added 2026-09-13). Detection was only ever half of it:
nothing wrote `ledger_gaps.resolved`, so a gap stayed open forever even after
the transaction it was about turned up. `reconcile_and_record_gaps` now treats
the freshly-detected set as authoritative and closes any open row whose pair is
no longer a gap. That covers both ways it happens — the late email finally
parsed, or the user filling it by hand in the app, which inserts a `MANUAL`
transaction *between* the two rows the gap names, carrying the balance that
makes the chain add up.

The nice property of doing it that way: the app doesn't have to be right. If
the amount entered is wrong, the original pair still dissolves, but the two new
pairs around the manual row don't reconcile — so the next run records *those*.
A wrong answer becomes a smaller, more specific question instead of a silently
closed one.

eSewa carries no balance, so wallet accounts don't get this. Fine — the bank side
is where the money actually is.

---

## 8. Parser spec for the two known templates

> **Important:** the HTML captured so far came from the Gmail *web client*. The
> `googleusercontent.com` proxied images, `data-saferedirecturl`, `class="CToWUd"`
> and `jsaction` attributes are injected by Gmail's frontend and **do not exist in
> the real message**. Capture fixtures via "Show original" or straight from IMAP.
> Never match on a Google-injected attribute.

### 8.1 `nabil.txn_alert`

| Field | Extraction |
|---|---|
| Route | sender contains `nabilbank.com`; body contains `Transaction Alert` |
| Account mask | regex `account number ([0-9#]+)` → `001#####234567` |
| Table | the `<table border="1">`; row 0 is the header row |
| Column map | build from header cell text; do **not** hardcode indices |
| Date | `%Y-%m-%d %H:%M` in `Asia/Kathmandu`; `precision = MINUTE` |
| Direction | the *Transaction Type* cell (`Debit`/`Credit`). **Not** the row's red styling. |
| Amount | strip `,` → `Decimal` → ×100 → int. `10,000.00` → `1000000` |
| Balance after | same treatment. `1,083,132.90` → `108313290` |
| Description | the *Remarks* cell, verbatim |
| Reference | none — synthesize the dedupe key |

The table can contain more than one data row. **Loop.** Do not take `rows[1]`.

### 8.2 `esewa.fund_load`

| Field | Extraction |
|---|---|
| Route | sender contains `esewa.com.np`; body contains `Your fund load from bank details` |
| Table | `table[border="1"]`, **not** "first table with a `<thead>`" — the real HTML nests this table inside a `<p>`, which an HTML5 parser fosters out into a second, malformed table whose rows concatenate the entire email body. `border="1"` is specific enough to skip that artifact. Column map from `<th>` text. |
| Date | `%d %b %Y, %I:%M:%S %p` in `Asia/Kathmandu`; `precision = SECOND` |
| Amount | plain float string, **no** thousand separators. `1000.0` → `100000` |
| Reference | *Reference Code* cell → `1PWB11H`; also appears in the statement link |
| Counterparty | *Bank Name* cell → `NABIL BANK LTD.` |
| Direction | `CREDIT` into the eSewa wallet account |
| Channel | `WALLET_LOAD` |
| Transfer | **always** a transfer candidate, never spend |

### 8.2a `esewa.payment_success`

Captured once a real sample turned up in the mailbox (was listed in 8.4 as
"the actual spending case, and the one you have zero samples of right now").
Same bordered-table shape as 8.2, different columns and direction.

| Field | Extraction |
|---|---|
| Route | sender contains `esewa.com.np`; body contains `Thank you for the payment` |
| Table | `table[border="1"]`, same fostering hazard as 8.2 — column map from `<th>` text |
| Date | `%d %b %Y, %I:%M:%S %p` in `Asia/Kathmandu` (*Transaction Date* cell); `precision = SECOND` |
| Amount | plain float string, **no** thousand separators (*Transaction Amount (NPR)* cell) |
| Reference | *Transaction Code* cell, e.g. `1Q5D142` |
| Counterparty | *Merchant Name* cell — observed value `Fonepay Payment` is eSewa's own gateway label, not necessarily the real end merchant |
| Direction | `DEBIT` out of the eSewa wallet account |
| Channel | `WALLET_PAYMENT` |
| Transfer | never a transfer candidate — real spend |
| Dedupe key | `esewa:{reference}`, same formula as 8.2 (same institution, same code-uniqueness assumption) |

### 8.3 `nabil.card_txn`

Captured and parsed as of Phase 1 (4 fixtures — Google, OpenAI ×2, PayPal, all
foreign-currency purchases on the linked debit card).

| Field | Extraction |
|---|---|
| Route | sender is `card-no-reply@nabilbank.com`, or subject contains "debit and credit txn" (case-insensitive) |
| Body | plain text, not HTML — single regex over the whole message |
| Pattern | `Your Debit Card {mask} was used at {description} for Purchase of {currency} {amount} on {date}` |
| Date | `%d-%b-%y` (e.g. `18-AUG-26`) in `Asia/Kathmandu`; **`precision = DAY`** — no time of day is given |
| Amount | plain decimal, no thousand separators, in the *foreign* currency named in the body (observed: always `USD`) |
| Description | everything between "was used at" and "for Purchase of", verbatim (merchant + location) |
| Counterparty | description, truncated at the first `;` |
| Direction | always `DEBIT` — this template only fires for card purchases |
| Channel | `CARD_FX` |
| Currency caveat | **breaks the §2 money invariant.** `amount_paisa` is documented as NPR paisa everywhere else; here it holds USD cents. The `transactions.currency` column already exists to disambiguate — the worker just needs to stop assuming NPR when it writes this row. No schema change needed, only a reminder for whoever writes `store/supabase.py`. |
| Dedupe key | `nabil:{mask}:{occurred_at:%Y-%m-%d}:DEBIT:{amount_subunit}:{sha1(description)[:8]}` — day-precision, not minute, since that's all the source gives |

### 8.4 Templates still to capture

Each is a separate `template_key` with its own parser and fixtures:

- `esewa.money_received`
- `esewa.money_sent`
- `esewa.cashback` / rewards
- `nabil.txn_alert` credit variant (salary, inbound IPS) — confirmed as of
  Phase 1: same column set and row structure as the debit variant, styled
  with `color:red` for debit rows vs the default (unstyled/green) for
  credit — do not parse direction from styling, section 8.1 already warns why.

Channel values observed in Nabil `txn_alert` remarks, beyond the original
`ATM`, `FONEPAY`, `IPS`, `CONNECTIPS`, `POS`, `MOBILE_BANKING`, `CHARGE`,
`INTEREST` list (all confirmed against real fixtures in Phase 0, matched by
remarks prefix — see `worker/src/expense_tracker/parsers/nabil.py:guess_channel`):

| Remarks prefix | Channel | Note |
|---|---|---|
| `salary for {month}` | `SALARY` | inbound credit |
| `C-ASBA Fee - IPO...` | `CHARGE` | flat NPR 5 fee, very frequent |
| `CASBA allot of IPO...` | `IPO_ALLOTMENT` | share allotment debit |
| `eSewa Load {phone}, {ref}` or `ESW DLA:{code}` | `ESEWA_LOAD` | **not necessarily a self-transfer.** `eSewa Load {phone}, {ref}` names a *phone number* — checked during Phase 3, and in the two real examples on file (9800000003, 9800000002) neither matches the account owner's own eSewa ID (9800000001, confirmed via a separate "Notification ID Verification" email). Those are loads to *someone else's* wallet — real spending, not a transfer to exclude. `ESW DLA:{code}` carries no phone number and may still be a genuine self-load. The transfer matcher (section 7.2) doesn't need to special-case this: it only links a pair when a matching `esewa.fund_load` CREDIT actually exists in the data, so a same-owner-only debit with no real counterpart correctly falls through as ordinary spend on its own. But don't have `categorize` (Phase 4) auto-label every `ESEWA_LOAD` row as Transfer/is_spend=false — check the phone number against the owner's own eSewa ID first. |
| `MPAY FPQR,...` | `FONEPAY` | |
| `MPAY {other}` | `MOBILE_BANKING` | in-app P2P/bill pay, not FonePay QR |
| `ATM WDL...` | `ATM` | |

These are still `channel_guess`-quality (regex on remarks text, not a bank
enum) — good enough for Phase 1 parsing, not yet promoted to a hard
categorization rule.

---

### 8.5 Laxmi Bank — SMS, not email

Laxmi sends no email at all. The transport for it is the phone:

```
Laxmi SMS ─▶ handset inbox ─▶ Flutter app (whitelisted senders only)
          ─▶ raw_messages (Supabase, status = PENDING)
          ─▶ next worker run parses ─▶ transactions
```

**Why a staging table rather than forwarding SMS to Gmail.** A forwarder app
(MacroDroid, Tasker) would need no architecture change at all, and that was
the tempting option. It loses on durability: a forwarder killed by Android's
battery optimisation drops messages permanently, and nothing downstream can
tell. The handset's own SMS inbox, by contrast, keeps every message
indefinitely and can be re-scanned on demand — so a gap is recoverable. That
makes the SMS inbox the equivalent of what Gmail is for the email path
(section 1: "Gmail is your durable archive"), and `raw_messages` the
equivalent of `raw/`: keeping the body means reparsing costs nothing and
never involves the phone a second time.

**What this does and does not relax.** Invariant 8 still holds — the phone
writes text, the worker writes transactions. The phone's `insert` grant on
`raw_messages` is column-level and excludes `status`, `txn_count`, and
`error`, so it cannot claim a message was handled. Provenance stays explicit:
`transactions` now carries both `source_message_id` (email) and
`source_raw_message_id` (SMS) with a check constraint requiring exactly one.

**Default deny on sender.** The app uploads only messages whose sender
matches the `SMS_SENDERS` whitelist in the app's `.env`. Unset means upload
nothing. Your inbox also holds OTPs and personal messages, and "upload
everything, let the parser sort it out" would push all of it into a cloud
database.

**No background SMS receiver.** The app scans on open and on demand, not via
a broadcast receiver. The worker only runs daily anyway, so near-real-time
capture buys nothing, and a background handler would need its own Supabase
client and its own failure modes. Re-scan covers everything a receiver would
have caught.

**Not gated by the watermark.** Section 6.2's watermark answers "how far back
must I ask Gmail?" — a question about an expensive remote fetch.
`raw_messages` is already in the database and carries its own `status`, so
`status = 'PENDING'` is the whole cursor. A message backfilled from six
months ago is therefore picked up on the next run rather than skipped for
arriving late, which is the entire point of making the inbox re-scannable.

**The parser is still outstanding.** Phase 0 applies unchanged: collect real
Laxmi SMS bodies first, write `expected.yaml`, then write the parser. Until
`SMS_PARSERS` is non-empty, staged messages land as `IGNORED` with the reason
recorded (invariant 6) and the bodies wait in `raw_messages` for the parser
to arrive.


---

## 9. Schema (Supabase)

Every table carries `user_id` even though you're the only user. Retrofitting RLS
onto a schema without it is miserable, and it costs nothing now.

```sql
create type account_kind   as enum ('BANK','WALLET');
create type direction      as enum ('DEBIT','CREDIT');
create type email_status   as enum ('PARSED','FAILED','IGNORED');
create type txn_status     as enum ('NEEDS_REVIEW','CATEGORIZED','CONFIRMED');
create type time_precision as enum ('SECOND','MINUTE','DAY');

-- ------------------------------------------------------------ ingest metadata
-- No bodies. Only enough to answer "have I seen this, and what happened to it?"

create table processed_emails (
    message_id     text primary key,               -- RFC 5322 Message-ID
    user_id        uuid not null references auth.users(id),
    received_at    timestamptz not null,
    from_addr      text not null,
    template_key   text,
    parser_version int,
    status         email_status not null,
    error          text,
    txn_count      int not null default 0,
    processed_at   timestamptz not null default now()
);
create index on processed_emails (user_id, received_at desc);
create index on processed_emails (user_id, status);

create table sync_runs (
    id            uuid primary key default gen_random_uuid(),
    user_id       uuid not null references auth.users(id),
    machine       text not null,                   -- 'arch-laptop' | 'macbook'
    started_at    timestamptz not null,
    completed_at  timestamptz,
    since         timestamptz not null,
    fetched       int not null default 0,
    parsed        int not null default 0,
    failed        int not null default 0,
    txns_inserted int not null default 0,
    error         text
);
create index on sync_runs (user_id, completed_at desc);

-- ------------------------------------------------------------ ledger

create table accounts (
    id           uuid primary key default gen_random_uuid(),
    user_id      uuid not null references auth.users(id),
    kind         account_kind not null,
    institution  text not null,                    -- 'NABIL', 'ESEWA'
    mask         text,                             -- '001#####234567'
    display_name text not null,
    currency     char(3) not null default 'NPR',
    unique (user_id, institution, mask)
);

create table categories (
    id        uuid primary key default gen_random_uuid(),
    user_id   uuid not null references auth.users(id),
    name      text not null,
    parent_id uuid references categories(id),
    is_spend  boolean not null default true,       -- false for Transfer, Salary
    unique (user_id, name)
);

create table transfer_groups (
    id                uuid primary key default gen_random_uuid(),
    user_id           uuid not null references auth.users(id),
    confidence        numeric(4,3) not null,
    confirmed_by_user boolean not null default false,
    created_at        timestamptz not null default now()
);

create table transactions (
    id                  uuid primary key default gen_random_uuid(),
    user_id             uuid not null references auth.users(id),
    account_id          uuid not null references accounts(id),
    source_message_id   text not null references processed_emails(message_id),

    occurred_at         timestamptz not null,
    occurred_precision  time_precision not null,
    direction           direction not null,
    amount_paisa        bigint not null check (amount_paisa > 0),
    balance_after_paisa bigint,
    currency            char(3) not null default 'NPR',

    reference           text,
    description_raw     text not null,             -- Remarks / bank name, verbatim
    counterparty        text,                      -- normalized merchant
    channel             text,                      -- ATM | FONEPAY | IPS | POS | …

    category_id         uuid references categories(id),
    category_source     text,                      -- 'rule' | 'llm' | 'user'
    category_confidence numeric(4,3),

    transfer_group_id   uuid references transfer_groups(id),
    excluded_from_spend boolean not null default false,

    status              txn_status not null default 'NEEDS_REVIEW',
    dedupe_key          text not null,
    parser_version      int not null,
    created_at          timestamptz not null default now(),

    unique (user_id, dedupe_key)
);
create index on transactions (user_id, account_id, occurred_at desc);
create index on transactions (user_id, status);
create index on transactions (transfer_group_id);

create table merchant_rules (
    id                 uuid primary key default gen_random_uuid(),
    user_id            uuid not null references auth.users(id),
    pattern            text not null,              -- regex over description_raw
    category_id        uuid not null references categories(id),
    counterparty_label text,
    priority           int not null default 100,
    learned_from_user  boolean not null default false,
    hit_count          int not null default 0,
    created_at         timestamptz not null default now()
);

create table ledger_gaps (
    id            uuid primary key default gen_random_uuid(),
    user_id       uuid not null references auth.users(id),
    account_id    uuid not null references accounts(id),
    after_txn_id  uuid not null references transactions(id),
    before_txn_id uuid not null references transactions(id),
    missing_paisa bigint not null,                 -- signed
    detected_at   timestamptz not null default now(),
    resolved      boolean not null default false
);
```

### 9.1 Views for the phone

Without an API layer, the phone must not pull 5,000 rows to sum them. Push
aggregation into Postgres.

```sql
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
```

> **`security_invoker = on` is not optional.** A view created without it runs as
> its owner and **bypasses RLS entirely** — every user would read every row. This
> is the single easiest way to leak a financial database on Supabase.

> **`currency` is in the `group by`, not converted away.** Migration
> `20260908020000_currency_fix_and_merchant_rules_rw.sql` added it after
> `nabil.card_txn`'s foreign-currency parsing meant this view was quietly
> summing USD cents into an NPR total. There is no exchange rate anywhere in
> this pipeline, so the fix is to keep currencies separate rather than invent
> a rate — callers that want one number per category (`MonthTotals` in the
> mobile app) must pick a currency explicitly rather than let the view do it
> for them.

For anything more complex, use an RPC function and call it via `supabase.rpc()`.

---

### 9.2 Manual entries and filling a gap *(added 2026-09-13)*

Migration `20260913000000_manual_entries_and_gap_fill.sql`. See the amended
invariant 8 in section 2 for the argument; this is the shape.

```sql
transactions.entry_source  text not null default 'PARSED'   -- 'PARSED' | 'MANUAL'

-- a MANUAL row has neither source column; a PARSED row has exactly one
constraint transactions_source_shape check (
    case entry_source
        when 'MANUAL' then num_nonnulls(source_message_id, source_raw_message_id) = 0
        else               num_nonnulls(source_message_id, source_raw_message_id) = 1
    end)

constraint transactions_manual_has_no_parser_version
    check (entry_source <> 'MANUAL' or parser_version = 0)

-- parsers emit 'nabil:' / 'esewa:' keys, so a manual entry can never occupy
-- the dedupe slot of a real transaction that hasn't arrived yet
constraint transactions_manual_dedupe_namespace
    check (case entry_source when 'MANUAL' then dedupe_key like 'manual:%'
                             else dedupe_key not like 'manual:%' end)

ledger_gaps.resolved_at, .resolved_by, .resolution_note
    -- resolved_by: 'MANUAL_ENTRY' | 'RECONCILER' | 'DISMISSED'
```

Plus `v_open_ledger_gaps`, which joins each unresolved gap to the two
transactions bracketing it. The fill form needs their timestamps (the entry
must land *inside* the window or the reconciler won't order it into the chain)
and the earlier one's `balance_after_paisa` (the entry chains forward from it).

**Two arithmetic facts the form depends on.**

1. `missing_paisa` is signed. Negative means a `DEBIT` is missing — money left
   with nothing recorded. Positive means a `CREDIT` is.
2. The entry must carry a balance, or nothing changes. `reconcile.py` *skips*
   rows with `balance_after_paisa is null`, so an entry without one leaves the
   very gap it was meant to close still open. The form computes it as
   `after_txn.balance_after_paisa + signed(amount)`.

A free-standing manual entry (cash, no gap) carries **no** balance, and that is
correct rather than lazy: an invented balance on a bank account would
manufacture two gaps where there were none.

**Scheduling.** The worker's 21:30 run refreshes gaps; the app's local
notification fires at 22:00 (`mobile/lib/core/notifications/daily_reminder.dart`).
Local, not FCM: section 14 already rules out pretending there's an always-on
component, and a nightly nudge to one phone doesn't justify Firebase, a
device-token table, and credentials on the worker. The cost is that the text is
fixed when scheduled, so it reports counts as of the last time the app was open
— the copy says "as of your last check" rather than implying a live number, and
the app reschedules on every resume.

---

## 10. Categorization

Rules first. The model is a fallback, not the engine.

```
transaction
    │
    ├─ matches a merchant_rule?  ──yes──▶  category, source='rule', confidence=1.0
    │
    └─ no ──▶ Ollama, structured JSON, Pydantic-validated
                 confidence ≥ 0.85 → CATEGORIZED
                 below            → NEEDS_REVIEW
```

Ollama now runs on the same machine as the worker, in the same run, with no
network hop. The awkward "cloud backend can't reach `localhost:11434`" problem in
the earlier design simply doesn't exist here — that tension was an artifact of
having a server at all.

If Ollama isn't running, skip it and leave rows as `NEEDS_REVIEW`. Never fail a
sync because a model was unavailable.

When you recategorize in the app, the phone writes a `merchant_rules` row. Next
sync, the rule fires locally and the model isn't consulted. That's the whole
feedback loop, and it's why the model matters less every week.

Send the model the smallest possible payload — normalized counterparty and amount.
Never the raw email.

Starting categories are grouped through `categories.parent_id` (full list in
`supabase/seed.sql`): Food & Drink, Health, Home & Bills, Transport, Shopping,
Subscriptions, Travel, Education, Fun & Social, Family & People, Fees & Cash,
Investments, Income & Transfers, plus an ungrouped `Other`. Groups are headings;
transactions are filed under the categories inside them, and the model is only
offered those. Mark the Investments and Income & Transfers groups and their
categories `is_spend = false`. After changing the list, `expense-tracker
categorize --all` re-runs the model over every existing transaction.

---

## 11. Security

Direct database access from a phone means RLS is not a nice-to-have — it is the
only thing standing between your bank balance and the internet.

### 11.1 Keys

| Key | Where it lives | Powers |
|---|---|---|
| `service_role` | Laptop `.env` only. Never in git, never in the app, never in a build. | Bypasses RLS entirely. |
| `anon` | Shipped in the mobile app. Assume it is public. | Nothing without a valid session + RLS policy. |
| Gmail app password | Laptop `.env` only. | Read your mail. |

Anyone who extracts the `anon` key from your APK should be able to do exactly
nothing. That property comes from RLS, not from hiding the key.

### 11.2 RLS

Enable on **every** table. Default deny.

```sql
alter table transactions      enable row level security;
alter table accounts          enable row level security;
alter table categories        enable row level security;
alter table merchant_rules    enable row level security;
alter table transfer_groups   enable row level security;
alter table ledger_gaps       enable row level security;
alter table processed_emails  enable row level security;
alter table sync_runs         enable row level security;

create policy "read own" on transactions
    for select using (auth.uid() = user_id);

create policy "update own" on transactions
    for update using (auth.uid() = user_id)
                with check (auth.uid() = user_id);
```

Then restrict *which columns* the phone may write, so "recategorize" can't become
"rewrite the amount":

```sql
revoke update on transactions from authenticated;
grant  update (category_id, category_source, status, excluded_from_spend)
       on transactions to authenticated;
```

No `insert` or `delete` grant on `transactions` for `authenticated`, ever. Only
the worker writes financial facts.

`merchant_rules` is the one table the phone gets `insert` on — that's the
correction loop.

**Manual entries** *(2026-09-13, migration `20260913000000`)*. One new insert
policy and one new column grant list:

```sql
create policy "insert own manual" on transactions
    for insert with check (auth.uid() = user_id and entry_source = 'MANUAL');

grant insert (user_id, account_id, occurred_at, occurred_precision, direction,
              amount_paisa, balance_after_paisa, currency, reference,
              description_raw, counterparty, channel, user_note, category_id,
              category_source, excluded_from_spend, status, dedupe_key,
              entry_source) on transactions to authenticated;
```

Absent by design, and each for a reason: `parser_version` (pinned to 0 by the
column default plus a check constraint, so the phone cannot forge provenance),
`source_message_id` / `source_raw_message_id` (a manual row must have neither),
`transfer_group_id` (the worker's matcher owns it), `category_confidence`,
`created_at`. `authenticated` still holds **no delete** on `transactions`, and
still cannot `update` amount, date, or direction — on a manual row either.

`ledger_gaps` gains `update` on `(resolved, resolved_at, resolved_by,
resolution_note)` only: the phone may **close** a gap, never open one, and
never edit the amount or the transaction pair that defines it.

The refusals above are covered by `worker/tests/test_manual_entries.py`, which
runs as the `authenticated` role rather than as the owner — as the superuser
every one of them succeeds, because RLS and column grants are exactly what a
superuser bypasses.

### 11.3 The rest

- `.env` in `.gitignore` from the first commit, plus a pre-commit hook so it isn't
  a matter of remembering.
- Never log amounts, balances, or account numbers. Log `message_id` and
  `template_key`; look the rest up when debugging.
- Keep account numbers masked exactly as the bank sends them (`001#####234567`).
  You never need the full number.
- `~/.expense-tracker/raw/` is your entire financial email history in plaintext on
  disk. Full-disk encryption on both machines, and a retention job that drops raw
  files older than 12 months whose transactions are `CONFIRMED`.
- Turn on Supabase's daily backups. There's no VPS snapshot to fall back on now.

---

## 12. Roadmap

Each phase has a definition of done. Don't start the next one early.

### Phase 0 — Fixture corpus *(no code)*
Export real emails as `.eml` via Gmail's "Show original".

- **DoD:** ≥ 30 messages in `tests/fixtures/emails/`, every observed template
  represented at least 3 times, plus `expected.yaml` mapping each file to its
  hand-written expected output. Writing that YAML by hand is the point — it's how
  you find the edge cases.
- Weight toward eSewa *payment* emails. That's where the spending is and you have
  no sample of it.

### Phase 1 — Parsers *(pure, offline)*
`parse(raw_mime) → list[NormalizedTxn]`. No network, no DB, no config.

- **DoD:** `pytest` green across every fixture. Each one either parses to the
  expected output or is explicitly marked `ignore`. Nothing in between.
- Days, not weeks. If it's taking weeks, the fixtures are telling you something.

### Phase 2 — Supabase schema + `sync` command
Schema, migrations, RLS policies, IMAP fetch, local archive, upsert.

- **DoD:** run `sync` twice; the second run inserts zero rows. Kill it mid-run and
  restart; still zero duplicates. Run it on both laptops; still zero duplicates.

### Phase 3 — Normalization
Transfer matching, balance reconciliation, gap detection.

- **DoD:** the 31 Aug eSewa NPR 1,000 load and its Nabil counterpart collapse into
  one `transfer_group`, both legs excluded from spend, and the monthly total is
  unchanged by that pair. The balance chain runs clean or reports specific gaps.

### Phase 4 — Categorization + `review` TUI
Rules engine, seed rules, terminal review queue, optional Ollama.

- **DoD:** ≥ 80% of the last three months auto-categorized by rules alone, with
  the Ollama path disabled.

### Phase 5 — Scheduling + hardening *(code-complete)*
systemd timer and launchd agent, `status` command, `reparse`, retention job.

- **DoD:** you haven't run `sync` by hand in two weeks and the data is still right.
- Code and tests are done (`worker/tests/test_network.py`,
  `worker/tests/test_status_and_retention.py`); the DoD itself can only be
  confirmed after the timer/agent has actually been installed and run
  unattended for two weeks, which needs `scripts/setup-wizard.sh` stage 9
  against a real machine.

### Phase 6 — Mobile client *(Flutter + `supabase_flutter`)*
Auth, month view, category breakdown, transaction list and detail, recategorize,
review queue. Local cache (Drift or `sqflite`) so the app works offline — you read
straight from Supabase, so without a cache the app is a blank screen on a plane.

- **DoD:** you check it instead of opening your bank app.

### Phase 7 — Push and extras
FCM digest at end of sync ("14 transactions since your last sync, 3 need review"),
deep links to a transaction, budgets, recurring detection, trends, CSV export.

---

## 13. Repo layout

```
expense-tracker/
├── worker/
│   ├── src/expense_tracker/
│   │   ├── cli.py                 # sync | status | reparse | review | backfill
│   │   ├── config.py
│   │   ├── parsers/
│   │   │   ├── base.py            # NormalizedTxn, Parser protocol, PARSER_VERSION
│   │   │   ├── registry.py        # (from, subject, body) → parser
│   │   │   ├── sms.py             # SmsMessage, SmsParser protocol, route_sms
│   │   │   ├── esewa.py
│   │   │   ├── nabil.py
│   │   │   ├── laxmi.py           # SMS-only bank (section 8.5) — awaiting fixtures
│   │   │   ├── money.py           # paisa conversion, one place only
│   │   │   └── dates.py           # Asia/Kathmandu, precision handling
│   │   ├── ingest/
│   │   │   ├── source.py          # MailSource protocol
│   │   │   ├── imap.py
│   │   │   ├── archive.py         # raw/ read+write, sha256(Message-ID) naming
│   │   │   └── watermark.py
│   │   ├── pipeline/
│   │   │   ├── dedupe.py
│   │   │   ├── transfers.py
│   │   │   ├── reconcile.py
│   │   │   └── categorize.py
│   │   ├── store/
│   │   │   └── supabase.py        # bulk upserts, nothing else knows about the DB
│   │   └── scheduling/
│   │       ├── expense-sync.timer
│   │       ├── expense-sync.service
│   │       └── com.expensetracker.sync.plist
│   ├── tests/
│   │   └── fixtures/
│   │       ├── emails/{esewa,nabil}/*.eml
│   │       └── expected.yaml
│   └── pyproject.toml
├── supabase/
│   ├── migrations/
│   └── seed.sql                   # categories, starter merchant_rules
├── mobile/                        # Flutter, Phase 6
└── docs/
    └── EXPENSE_TRACKER_PLAN.md    # this file
```

---

## 14. What this architecture gives up

Worth naming so you're not surprised later.

- **No real-time alerts.** You learn about a transaction at the next sync, not when
  it happens. Push becomes a daily digest, not a transaction alert. Getting
  instant alerts back requires an always-on component, which is the thing you just
  removed on purpose.
- **Freshness tracks your laptop.** Off for a week, data is a week stale. The app
  should show "last synced 6 days ago" prominently rather than implying it's live.
- **The phone can't trigger a sync.** A pull-to-refresh only re-reads Supabase; it
  can't make the laptop wake up and check Gmail. Label the button honestly.
- **Query logic lives in two places.** Views and RPCs in SQL, plus whatever the
  Flutter client composes. Without an API layer there's no single place to put
  business logic — keep anything non-trivial in Postgres, not Dart.

If any of these start to bite, the escape hatch is small: move the worker to your
VPS on an hourly cron and keep everything else identical. Nothing else in the
design changes. But start local — the daily batch is almost certainly enough for
a personal expense tracker, and it's a fraction of the moving parts.

---

## 15. Open decisions

| Decision | Recommendation |
|---|---|
| Supabase vs Firebase | Supabase. §4. |
| Local DB alongside the raw archive | Not needed. The filename is the index; `processed_emails` records the rest. Add SQLite only if you want offline `reparse` bookkeeping. |
| Mobile-first or web-first | Mobile, per your preference. A Next.js view over the same SDK is a weekend's work later if you want one. |
| Android SMS as a second source | Not in v1. Bank SMS is faster than email but `READ_SMS` is effectively unpublishable on Play Store — fine for a sideloaded build, dead end for a product. Purely additive later. |
| Multi-user | Assume no. But keep `user_id` and RLS from day one anyway — it costs nothing now and is painful to retrofit. |

---

## Next action

Run `scripts/setup-wizard.sh` once to provision the real Supabase project,
apply the migration there, create your auth user + seed categories, generate
a Gmail app password, write `~/.expense-tracker/config.toml` + `.env`, and
(stage 9) install and enable the systemd `--user` timer or launchd agent so
`sync` actually runs daily without you. Then `cd worker &&
.venv/bin/expense-tracker sync` for a real first run. Re-run the wizard on
the second machine (MacBook/Arch laptop, section 6.3) when you set that one
up too -- stage 9 is per-machine, since each one schedules its own local
worker.

After that, let it run unattended for two weeks to actually close out the
Phase 5 DoD, and start running `expense-tracker retention` occasionally (it
isn't scheduled automatically; the wizard prints the reminder). Then Phase
6: the Flutter mobile client.

Still open from Phase 0/1, not blocking Phase 5 but needed before the fixture
corpus is complete: real `esewa.payment_success` samples (zero exist in the
mailbox right now — you have to actually spend from the eSewa wallet to
generate one), and a Nabil credit-side `txn_alert` fixture beyond salary (an
inbound IPS transfer, say) to confirm the column set matches. Also still
missing: a real Nabil-side counterpart for the 31 Aug eSewa load (checked via
Gmail search during Phase 3 — doesn't exist in the mailbox yet) and a real
`esewa.fund_load` credit for either of the two "eSewa Load" Nabil debits Phase
0 turned up (18 May, NPR 3,000; 17 Apr, NPR 650) — worth checking whether
those ever generate a matching eSewa email at all, since eSewa may not always
send a "Bank Load" notification for every top-up path.
