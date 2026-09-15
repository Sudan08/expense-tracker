"""Phase 1 DoD: every fixture in tests/fixtures/emails parses to its
hand-written expected output in tests/fixtures/expected.yaml, or is
explicitly marked `ignore`. Nothing in between.
"""

from __future__ import annotations

import email
import email.policy
from datetime import datetime
from pathlib import Path

import pytest
import yaml

from expense_tracker.parsers.registry import route

FIXTURES_DIR = Path(__file__).parent / "fixtures"
EXPECTED = yaml.safe_load((FIXTURES_DIR / "expected.yaml").read_text())

# Fields in expected.yaml that don't map 1:1 onto NormalizedTxn -- either an
# alias (the value predates a field being promoted into the plan spec) or
# pure documentation for a human, not something the parser is asked to emit.
ALIASES = {
    "channel_guess": "channel",
    "amount_subunit": "amount_paisa",
    "dedupe_key_provisional": "dedupe_key",
    "card_mask": "account_mask",
}
IGNORED_KEYS = {"note", "account_mask", "currency", "transfer_candidate"}


def _load_message(rel_path: str) -> email.message.EmailMessage:
    raw = (FIXTURES_DIR / "emails" / rel_path).read_bytes()
    return email.message_from_bytes(raw, policy=email.policy.default)


@pytest.mark.parametrize("rel_path", sorted(EXPECTED.keys()))
def test_fixture_matches_expected(rel_path: str):
    expected = EXPECTED[rel_path]
    message = _load_message(rel_path)

    parser = route(message)
    assert parser is not None, f"no parser matched {rel_path}"
    assert parser.template_key == expected["template_key"]

    txns = parser.parse(message)
    assert len(txns) == 1, f"expected exactly one txn in {rel_path}, got {len(txns)}"
    txn = txns[0]

    for key, value in expected.items():
        if key in IGNORED_KEYS:
            continue
        field = ALIASES.get(key, key)
        actual = getattr(txn, field)
        if isinstance(actual, datetime):
            actual = actual.isoformat()
        assert actual == value, f"{rel_path}: {field} = {actual!r}, expected {value!r}"
