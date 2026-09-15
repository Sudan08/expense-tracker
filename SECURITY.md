# Security and privacy

This project handles bank transaction data, so it is worth being precise about
where everything lives and what each credential can do.

## Reporting a vulnerability

Please open a [security advisory](../../security/advisories/new) rather than a
public issue. If that isn't available to you, open an issue saying only that
you have a security concern and how to reach you — no details.

## Where your data lives

| | Stays on your machine | Goes to Supabase |
| --- | --- | --- |
| Raw `.eml` bodies | ✅ `~/.expense-tracker/raw/` | ❌ never |
| Subject lines, sender addresses | ✅ | ❌ never |
| Mail app password | ✅ `~/.expense-tracker/.env` | ❌ never |
| Database URL | ✅ same file | — |
| Normalized transactions | ✅ archive cache | ✅ |
| Email *metadata* (message id, parse status) | ✅ | ✅ no bodies |

All HTML parsing, transfer matching, reconciliation and LLM categorization
happen locally. Supabase receives rows, never prose.

The local LLM fallback is [Ollama](https://ollama.com), running on your own
machine. No transaction text is sent to a hosted model. Run with `--no-ollama`
to disable it entirely; rules-based categorization still works and anything
unmatched lands in the review queue.

## Credentials, and what each one can do

**Gmail app password** — read access to your mailbox, over IMAP only. It is
not your account password, it is individually revocable at
[myaccount.google.com/apppasswords](https://myaccount.google.com/apppasswords),
and it does not grant access to anything else in your Google account. Stored
in `~/.expense-tracker/.env`; `chmod 600` it.

**Supabase database URL** — contains the Postgres password and full write
access to your ledger. Laptop only. Never put it in the mobile app.

**Supabase anon key** — ships inside the mobile app, and that is fine by
design: it grants nothing on its own. Row-level security is what protects the
data, and every table is keyed to `auth.uid()`. A user can only ever read and
write their own rows.

**Android signing keystore** — kept outside the repository entirely.
`key.properties`, `*.jks` and `*.keystore` are gitignored as defence in depth.

## What the phone is allowed to write

The mobile client talks to Supabase directly, with no API layer in between,
so its permissions are enforced as database policy rather than as application
logic. It may:

- recategorize, confirm, and attach its own notes
- stage raw bank SMS text into `raw_messages` — raw text is not a fact about
  the ledger until a parser has read it, and only the worker runs parsers
- record its own assertions: a transaction you typed yourself, tagged
  `entry_source = 'MANUAL'`

It may **not** edit or delete any transaction — manual ones included — and it
cannot make a row it wrote look like one a parser produced.

## SMS collection is default-deny

`SMS_SENDERS` in `mobile/.env` is empty by default, and an empty value means
the app uploads no SMS at all. You must explicitly list bank sender IDs. Your
inbox also holds OTPs and personal messages, so keep that list to banks.

## Nothing personal ships in this repository

The email and SMS fixtures under `worker/tests/fixtures/` are synthetic. Names,
addresses, account numbers, card digits, balances, phone numbers and
counterparties are all fabricated; only the structural shape of each bank's
message is real, because that is what the parsers are tested against.

**If you contribute a fixture, redact it first** — see
[docs/ADDING_A_PARSER.md](docs/ADDING_A_PARSER.md#1-capture-a-real-email-as-a-fixture)
for the field-by-field list. A pull request containing real account data will
be closed rather than merged, because a merge is unrevokable.

The same goes for `expense-tracker status` output and logs: they carry
counterparty names and amounts. Redact before pasting into an issue.
