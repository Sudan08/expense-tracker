# Contributing

The most valuable contribution is **a parser for a bank this doesn't read
yet** — see [docs/ADDING_A_PARSER.md](docs/ADDING_A_PARSER.md). Bug reports
about wrong ledgers are a close second.

## Before anything else: never commit real financial data

The fixture corpus in this repository is synthetic. Keep it that way.

A real bank email carries your name, address, account number, card digits and
running balance, and git history is forever — a redaction commit does not
remove what an earlier commit published. Redact fixtures *before* the first
commit that contains them, using the table in
[ADDING_A_PARSER.md](docs/ADDING_A_PARSER.md#1-capture-a-real-email-as-a-fixture).

This applies to issues too: `status` output and worker logs contain
counterparty names and amounts.

## Getting set up

No credentials, database or network needed to work on the worker:

```bash
cd worker
python3 -m venv .venv
.venv/bin/pip install -e '.[dev]'
.venv/bin/python -m pytest      # 140 passed, 21 skipped
```

The 21 skips are integration tests wanting a real Postgres:

```bash
createdb expense_tracker_test
EXPENSE_TRACKER_TEST_DB_URL=postgresql://localhost/expense_tracker_test \
  .venv/bin/python -m pytest
```

They apply the migrations themselves. Point this at a throwaway database, not
the one holding your ledger.

For the app: `cd mobile && flutter pub get && flutter test`.

## What the code values

This codebase is opinionated, and reviews will hold to it.

**Correctness over features.** The product is the line
`email → correct transaction → no duplicates → no double-counted transfers →
no silently missing rows → sensible category`. A change that makes the
dashboard prettier and that line weaker will not be merged.

**Don't revisit the [invariants](docs/EXPENSE_TRACKER_PLAN.md#2-invariants).**
Integer paisa, UTC storage, idempotency by database constraint, transfers
excluded from spend, nothing silently dropped. If you think one is wrong,
open an issue and argue it before writing code.

**Idempotency belongs in the schema.** Enforce uniqueness with a constraint,
not with an application-level "have I seen this?" check. Application logic
cannot survive two machines, a crash mid-run, or a three-week gap; a unique
index can.

**Fail loudly, record quietly.** A parser that can't understand a message must
raise. The pipeline catches it, writes a `FAILED` row with the error, and
carries on — so the failure is visible in `status` and fixable by `reparse`,
rather than being a silent hole in the ledger.

**Comments explain *why*.** The existing code documents the reasoning behind
non-obvious decisions — why there is no IMAP UID cursor, why `logout()` is
suppressed, why the bookkeeping write in a `finally` must not raise. Several
of those comments are load-bearing bug fixes. Match that: explain the
reasoning a future reader won't reconstruct, not what the line does.

**Keep the layers pure.** Parsers take a message and return transactions — no
network, no database, no config, no clock. `store/` is the only package that
knows Postgres exists. That separation is why the tests run offline in under a
second.

## Tests

Every change needs one. In particular:

- a new parser needs a redacted fixture plus a hand-written entry in
  `expected.yaml` — derived by reading the email, not by running the parser
  and pasting its output
- a bug fix needs a test that fails before it
- pipeline changes should use the offline fake-store pattern
  (`tests/test_fetch_limit.py`, `tests/test_sync_failure_reporting.py`) rather
  than requiring Postgres, where that's possible

## Pull requests

- One concern per PR.
- Say what you verified and how. "Ran `reparse` over 300 archived emails, 0
  FAILED" is worth more than a description of the diff.
- Note explicitly if you touched anything that changes parser output —
  `parser_version` exists so that "reparse everything the v3 Nabil parser
  touched" is one query, and it needs bumping when output changes.
- Migrations are append-only. Add a new timestamped file; don't edit one that
  has shipped.

## Design documentation

[docs/EXPENSE_TRACKER_PLAN.md](docs/EXPENSE_TRACKER_PLAN.md) is the full design
document — the data model, every template spec, and the reasoning behind the
architecture. It is long, but if you are wondering "why is it done *this*
way", the answer is almost certainly in there.
