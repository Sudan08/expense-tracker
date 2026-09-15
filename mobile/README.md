# Expense Tracker — mobile client

Flutter app that reads the ledger directly from Supabase. There is no API
layer: the app talks to Postgres through the Supabase SDK, and row-level
security is what enforces access.

See the [root README](../README.md) for how this fits with the worker, and
[docs/SETUP.md](../docs/SETUP.md) for full setup.

## Running it

```bash
cp .env.example .env    # fill in from Supabase: Project Settings -> API
flutter pub get
flutter run
```

Without a populated `.env`, the app boots into a "not configured" screen
rather than crashing — so a fresh clone runs, it just has nothing to show.

`SUPABASE_ANON_KEY` is safe to ship in the app; RLS is the actual protection.
Never put the `service_role` key or the Postgres URL here.

## Structure

```
lib/
  core/        theme, router, money formatting, Supabase providers, caching
  data/        one repository per table — the only code that queries Supabase
  features/    one directory per screen, with its controller beside it
  models/      plain data classes mirroring the database rows
```

State is [Riverpod](https://riverpod.dev); navigation is `go_router`.
Repositories are the seam — widgets never query Supabase directly.

## What the app may write

The phone cannot write parser-derived facts. It can recategorize, confirm,
attach notes, stage raw bank SMS into `raw_messages`, and record manual
entries tagged `entry_source = 'MANUAL'`. It can never edit or delete a
transaction, nor make a row it wrote look like one a parser produced. See
[SECURITY.md](../SECURITY.md).

## SMS collection

Android only, and default-deny. Set `SMS_SENDERS` in `.env` to a
comma-separated list of bank sender IDs (matched case-insensitively as a
substring):

```
SMS_SENDERS=LaxmiBank,LaxmiSunrise
```

Leave it empty and no SMS is read or uploaded at all. Your inbox also holds
OTPs and personal messages, so list only banks.

## Tests

```bash
flutter test
```
