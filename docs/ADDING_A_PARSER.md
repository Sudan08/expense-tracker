# Adding a parser for your bank

Out of the box this reads eSewa, Nabil Bank (email) and Laxmi Sunrise (SMS).
Adding another is the most useful contribution you can make, and it is
deliberately a small job: one module, one fixture, one expectation.

Parsers are **pure** — no network, no database, no config, no clock. They take
an `EmailMessage` and return a list of `NormalizedTxn`. That is the whole
contract, and it is why the entire parser test suite runs offline in under a
second.

---

## 1. Capture a real email as a fixture

In Gmail, open a transaction notification → ⋮ → **Show original** → **Download
Original**. Save it under `worker/tests/fixtures/emails/<bank>/`, named
`<bank>_<template>_<date>.eml`.

**Redact it before you commit it.** A real notification carries your name,
email address, account number and running balance. The fixtures in this repo
are synthetic for exactly this reason. Replace:

| Field | Use instead |
| --- | --- |
| Your email address | `fixtureuser@example.com` |
| Your name | `TEST USER` |
| Account number / mask | `001#####234567` |
| Card last-4 | `XXXX4321` |
| Balances | any plausible fictional figure |
| Phone numbers | `98000000NN` |
| Counterparties that identify you | `EXAMPLE PHARMACY`, etc. |

Keep the *structure* exactly as the bank sends it — the HTML shape, the table
columns, the encoding. That is what the parser is being tested against.

## 2. Write the parser

One module per institution in `worker/src/expense_tracker/parsers/`. A parser
is any class satisfying the `Parser` protocol in
[`parsers/base.py`](../worker/src/expense_tracker/parsers/base.py):

```python
class Parser(Protocol):
    template_key: ClassVar[str]      # 'yourbank.txn_alert'
    parser_version: ClassVar[int]    # bump when output changes

    def matches(self, message: EmailMessage) -> bool: ...
    def parse(self, message: EmailMessage) -> list[NormalizedTxn]: ...
```

A minimal one:

```python
class YourBankAlertParser:
    template_key = "yourbank.txn_alert"
    parser_version = 1

    def matches(self, message: EmailMessage) -> bool:
        if "yourbank.com" not in str(message.get("From", "")):
            return False
        return "Transaction Alert" in _html_body(message)

    def parse(self, message: EmailMessage) -> list[NormalizedTxn]:
        body = _html_body(message)
        ...
        return [NormalizedTxn(
            template_key=self.template_key,
            parser_version=self.parser_version,
            institution="YOURBANK",
            account_mask=account_mask,
            occurred_at=occurred_at,          # tz-aware, Asia/Kathmandu
            occurred_precision="MINUTE",      # what the source actually gave
            direction=direction,              # 'DEBIT' | 'CREDIT'
            amount_paisa=amount_paisa,        # integer subunits, never float
            balance_after_paisa=balance,      # if the mail states one
            description_raw=description_raw,  # verbatim, unparsed
            message_id=str(message["Message-ID"]),
            dedupe_key=dedupe_key,
        )]
```

Register it in [`parsers/registry.py`](../worker/src/expense_tracker/parsers/registry.py).
`route()` returns the first parser whose `matches()` is true, so order matters
when two templates from one bank overlap — put the more specific first.

Add the institution to `ACCOUNT_KIND` in
[`pipeline/sync.py`](../worker/src/expense_tracker/pipeline/sync.py)
(`"YOURBANK": "BANK"` or `"WALLET"`), and its domain to `[senders]` in
`config.toml`.

### The rules that actually matter

**Money is integer subunits.** Parse `"1,234.50"` to `123450` with
`parsers.money.parse_subunit`. Never build an amount through a float.

**`occurred_precision` must be honest.** Record what the source gave you —
`SECOND`, `MINUTE` or `DAY`. Transfer matching uses it to decide how wide a
time window two legs may span; claiming more precision than you have causes
real transfers to go unmatched.

**`dedupe_key` is the idempotency guarantee.** It is a unique constraint in
the database, which is what makes running the worker twice a no-op. Build it
from fields the bank will reproduce identically in a re-sent email:

```python
dedupe_key = f"yourbank:{mask}:{occurred_at:%Y-%m-%dT%H:%M}:{direction}:{amount_paisa}:{sha1(description)[:8]}"
```

If the mail carries a real transaction reference, use that instead — it is
strictly better than a hash. Never include anything that varies between
deliveries of the same notification.

**`description_raw` stays verbatim.** Categorization rules and the local LLM
both read it, and a rule the user writes against what they saw in their inbox
should match. Clean it up in `counterparty`, not here.

**Raise on anything unexpected.** A parser that guesses produces a wrong
ledger; a parser that raises produces a `FAILED` row with the error attached,
which is visible in `expense-tracker status` and fixable by `reparse`. Failing
loudly is the designed behaviour (invariant 6 — nothing is silently dropped).

## 3. State the expected output

Add an entry to
[`worker/tests/fixtures/expected.yaml`](../worker/tests/fixtures/expected.yaml),
keyed by the fixture's path relative to `fixtures/emails/`:

```yaml
yourbank/yourbank_txn_alert_2026-03-15.eml:
  template_key: "yourbank.txn_alert"
  occurred_at: "2026-03-15T15:19:00+05:45"
  occurred_precision: "MINUTE"
  direction: "DEBIT"
  amount_paisa: 1250000
  balance_after_paisa: 18543055
  currency: "NPR"
  description_raw: "QR-Pay,EXAMPLE STORE"
  dedupe_key: "yourbank:001#####234567:2026-03-15T15:19:DEBIT:1250000:a1b2c3d4"
```

Write these by hand from what the email says, not by running the parser and
pasting its output — the point is to catch the parser being wrong, and a
self-generated expectation cannot.

`test_parsers.py` picks it up automatically: every fixture must parse to its
stated expectation, or be explicitly marked `ignore`. Nothing in between.

## 4. Run the tests

```bash
cd worker
.venv/bin/python -m pytest
```

Then confirm against your real mailbox without writing anything:

```bash
.venv/bin/expense-tracker inbox --last 3m       # is the sender matching?
.venv/bin/expense-tracker backfill --last 7d    # small window first
.venv/bin/expense-tracker status                # any FAILED rows?
```

`reparse` re-runs your parser over the local `.eml` archive with no IMAP
fetch, which makes iterating on a template cheap once the mail is downloaded.

## SMS parsers

Same shape, but simpler — SMS bodies are plain text staged into `raw_messages`
by the phone. Parsers live in `parsers/sms.py` and route via `route_sms()`;
[`parsers/laxmi.py`](../worker/src/expense_tracker/parsers/laxmi.py) is the
worked example. Fixtures are `.txt` files under `tests/fixtures/sms/<bank>/`.

The SMS path is deliberately re-scannable: a message the phone backfills from
six months ago is picked up on the next run rather than skipped for arriving
late, because `status = 'PENDING'` is the whole cursor.

## Checklist

- [ ] Fixture committed, fully redacted, structure intact
- [ ] Parser is pure — no network, DB, config or `datetime.now()`
- [ ] Amounts are integer subunits
- [ ] `occurred_precision` matches what the source gave
- [ ] `dedupe_key` is stable across re-sends of the same email
- [ ] Registered in `registry.py`; institution in `ACCOUNT_KIND`
- [ ] Expectation added to `expected.yaml`, written by hand
- [ ] `pytest` passes
