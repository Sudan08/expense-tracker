# Setup

End to end this takes about 30 minutes, most of it waiting on Supabase to
provision. You need a Google account with 2-Step Verification enabled, and
either macOS or Linux for the scheduled run.

There is a wizard that does steps 2–5 interactively:

```bash
./scripts/setup-wizard.sh
```

It is resumable — stop with Ctrl-C and re-run; it remembers what it already
saved. The manual equivalents are below, so you can see what it is doing.

---

## 1. The worker, offline

Nothing here needs credentials, so do it first and confirm the project works
before provisioning anything.

```bash
cd worker
python3 -m venv .venv
.venv/bin/pip install -e '.[dev]'
.venv/bin/python -m pytest
```

Expected: **157 passed, 26 skipped**. The skips are integration tests that
want a real Postgres; see [Running the database tests](#running-the-database-tests).

Requires Python 3.12+.

## 2. Create a Supabase project

Supabase is the shared ledger the phone reads. It stores structured rows only
— never email bodies, never your mail password.

1. Create a project at [supabase.com/dashboard](https://supabase.com/dashboard/projects).
   Any region; pick one near you.
2. Save the database password it shows you — it is not shown again.
3. Project Settings → General → copy the **Reference ID**.

## 3. Apply the schema

From Project Settings → Database, copy the **direct** connection URI (the
`URI` tab, *Direct connection* mode — not the transaction or session pooler;
the worker does bulk upserts with psycopg and wants the direct connection).

Pick whichever method is easiest:

- **Setup wizard (fastest):** `./scripts/setup-wizard.sh` applies all migrations automatically using your direct connection string.
- **Supabase CLI:**
  ```bash
  supabase link --project-ref <your-ref>
  supabase db push
  ```
- **Dashboard SQL Editor (zero install):**
  Open `supabase/schema.sql` (all migrations consolidated in order), copy its contents, paste into the Supabase SQL editor, and click **Run**.

## 4. Create your user and seed categories

Every table is keyed by `user_id` and protected by row-level security, even
for a single user.

1. Authentication → Users → **Add user** → Create new user. Any email and
   password; this account is only ever used by you.
2. Copy the new user's **UID** (a UUID).
3. Seed the starter categories and merchant rules:

```bash
psql "$EXPENSE_TRACKER_DB_URL" -v user_id=<your-uuid> -f supabase/seed.sql
```

The dashboard's SQL editor cannot bind psql variables, so if you use it
instead, substitute first:

```bash
sed "s/:'user_id'/'<your-uuid>'/g" supabase/seed.sql | pbcopy
```

The seeded `merchant_rules` are examples matching the test fixtures. Expect to
replace most of them with your own merchants — `expense-tracker review` writes
new rules for you as you categorize, so this list grows itself.

## 5. Mail credentials

The worker reads your inbox over IMAP with an **app password**, which is
separate from your normal password and revocable on its own.

1. Go to [myaccount.google.com/apppasswords](https://myaccount.google.com/apppasswords)
   (requires 2-Step Verification).
2. Create one named `expense-tracker` and copy the 16 characters.

Then write the two config files the worker reads. Secrets go in `.env`:

```bash
mkdir -p ~/.expense-tracker
cat > ~/.expense-tracker/.env <<'EOF'
EXPENSE_TRACKER_DB_URL=postgresql://user:pass@db.YOUR-PROJECT-REF.supabase.co:5432/postgres
EXPENSE_TRACKER_IMAP_PASSWORD=<16-char app password, no spaces>
EXPENSE_TRACKER_USER_ID=<your auth user UUID>
EOF
chmod 600 ~/.expense-tracker/.env
```

Everything non-secret goes in `config.toml`:

```toml
[worker]
machine = "laptop"                      # free-form label, shows up in `status`
archive_dir = "~/.expense-tracker/raw"
account_start = "2025-01-01"            # earliest date a first sync backfills to

[imap]
host = "imap.gmail.com"
username = "you@gmail.com"

[senders]
esewa = "esewa.com.np"
nabil = "nabilbank.com"
```

`[senders]` is matched as a substring against the `From` header. If your bank
mails from a different domain, put it here — and see
[ADDING_A_PARSER.md](ADDING_A_PARSER.md) to teach the worker to read it.

A copy of both files lives at [`worker/config.toml.example`](../worker/config.toml.example)
and [`worker/env.example`](../worker/env.example).

## 6. First sync

Check the size of the job before committing to it:

```bash
cd worker
.venv/bin/expense-tracker inbox --last 1y
```

This is an IMAP SEARCH — it downloads no message bodies and writes nothing.
Then pull it:

```bash
.venv/bin/expense-tracker backfill
```

`backfill` asks how far back to go, shows you the message count, and waits for
confirmation before fetching. On a large mailbox, take it in bites:

```bash
.venv/bin/expense-tracker backfill --last all --max-emails 200
```

Every step is idempotent, so overlapping windows and repeated runs are safe —
already-seen messages are deduped and insert nothing new.

Then check what landed:

```bash
.venv/bin/expense-tracker status
.venv/bin/expense-tracker review     # assign categories; each one writes a rule
```

## 7. Schedule it

The wizard installs these at stage 9; by hand:

**macOS (launchd).** Copy
`worker/src/expense_tracker/scheduling/com.expensetracker.sync.plist` to
`~/Library/LaunchAgents/`, substituting `__EXEC_PATH__`,
`__WORKING_DIRECTORY__` and `__LOG_DIR__` for real paths, then
`launchctl load -w ~/Library/LaunchAgents/com.expensetracker.sync.plist`.

**Linux (systemd --user).** Copy `expense-sync.service` and
`expense-sync.timer` from the same directory to `~/.config/systemd/user/`,
substitute `__WORKING_DIRECTORY__` and `__EXEC_START__`, then
`systemctl --user enable --now expense-sync.timer`.

Both run at 10:30 and 21:30 and re-run a missed job on wake. A run that finds
the network down exits quietly and lets the next one catch up, so a closed
laptop is not an error condition.

## 8. The mobile app

```bash
cd mobile
cp .env.example .env     # fill in SUPABASE_URL and SUPABASE_ANON_KEY
flutter pub get
flutter run
```

Both values come from Project Settings → API. The anon key is safe to ship in
the app — row-level security is what actually protects the data.

Sign in with the user you created in step 4.

To collect bank SMS on Android, set `SMS_SENDERS` in `mobile/.env` to a
comma-separated list of sender IDs (e.g. `SMS_SENDERS=NabilBank,LaxmiSunrise`).
It is **default-deny**: leave it empty and the app uploads no SMS at all. Your
inbox also holds OTPs and personal messages, so list only bank senders.

**List a bank here even if it also emails you.** Nabil sends both, and the two
are read together: the SMS arrives within seconds while the email only shows
up at the next worker sync, and the email is the one carrying the running
balance that gap detection needs. They collapse onto a single transaction
rather than double-counting — see
[plan section 8.6](EXPENSE_TRACKER_PLAN.md#two-transports-one-transaction).

The app scans the handset on launch and on every resume (throttled to once a
minute), so transactions appear shortly after you next open it. There is no
always-on component to do it on a schedule instead — the 22:00 reminder is
what makes sure you open the app at least once a day.

---

## Running the database tests

26 tests need a real Postgres — they exercise the unique constraints and the
`ON CONFLICT` behaviour that the dedupe guarantees actually live in, which
cannot be checked in Python. Point them at a throwaway database:

```bash
createdb expense_tracker_test
EXPENSE_TRACKER_TEST_DB_URL=postgresql://localhost/expense_tracker_test \
  .venv/bin/python -m pytest          # 183 passed, 0 skipped
```

No Postgres installed and don't want one? `pip install pgserver` ships its own
binaries, no system install or sudo:

```python
import pgserver, pathlib
srv = pgserver.get_server(pathlib.Path("/tmp/pgdata"), cleanup_mode=None)
srv.psql("create database et_test")
print(srv.get_uri().replace("/postgres?", "/et_test?"))
```

That build is minimal and lacks `pg_trgm`, so the one migration that adds
trigram indexes (`20260913020000`) won't apply — the indexes are a
performance concern only, and every other migration and test runs.

They apply the migrations themselves. Never point this at the database
holding your real ledger.

## Troubleshooting

**`config.toml not found`** — the worker reads `~/.expense-tracker/`, not the
repo. Re-check step 5.

**`inbox` reports 0 messages** — `[senders]` doesn't match your mail. Search
your inbox for a real notification and check its actual `From` domain.

**Emails fetched but `parsed=0`, `ignored=N`** — mail arrived but no parser
claimed it. That is the normal starting point for a new bank; see
[ADDING_A_PARSER.md](ADDING_A_PARSER.md).

**`failed=N`** — a parser matched and then threw. Nothing was dropped: those
are `FAILED` rows in `processed_emails` with the error attached. Fix the
parser and re-run `reparse`, which works offline against the local archive.

**A capped `backfill` won't continue** — a successful run advances the
watermark, so a later plain `sync` starts from now. Pass the window explicitly
(`backfill --last all --max-emails 200`) to take the next bite. The CLI says
so when a cap bites.
