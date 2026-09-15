"""match_rule/categorize_with_rules are pure and offline. categorize_with_ollama
is tested with a mocked HTTP layer -- no real Ollama server needed, matching
section 10: 'if Ollama isn't running, skip it... never fail a sync.'

The DoD test at the bottom reproduces supabase/seed.sql's starter rules in
Python and runs them against every real Phase 0 fixture's actual parsed
description_raw (via the real Phase 1 parsers, not expected.yaml's numbers)
to verify the Phase 4 roadmap target directly: '>= 80% of the last three
months auto-categorized by rules alone, with the Ollama path disabled.'
"""

from __future__ import annotations

import email
import email.policy
import json
import urllib.error
from pathlib import Path
from unittest.mock import MagicMock, patch

from expense_tracker.parsers.registry import route
from expense_tracker.pipeline.categorize import (
    CONFIDENCE_THRESHOLD,
    CategoryNode,
    MerchantRule,
    ReviewCandidate,
    categorize_with_ollama,
    categorize_with_rules,
    match_rule,
    model_label,
    recategorize_all,
)

FIXTURES_DIR = Path(__file__).parent / "fixtures" / "emails"

RULES = [
    MerchantRule("r1", r"^ATM WDL", "cat-cash-withdrawal", 100),
    MerchantRule("r2", r"^C-ASBA Fee", "cat-fees", 100),
    MerchantRule("r3", r"^CASBA allot", "cat-other", 100),
    MerchantRule("r4", r"^salary for", "cat-salary", 100),
    MerchantRule("r5", r"eSewa Load|^ESW DLA:", "cat-other", 100),
    MerchantRule("r6", r"GOOGLE \*CLAUDE", "cat-bills", 100),
    MerchantRule("r7", r"OPENAI \*CHATGPT", "cat-bills", 100),
    MerchantRule("r8", r"PAYPAL \*CONTABO", "cat-bills", 100),
    MerchantRule("r9", r"EXAMPLE EDUCATION", "cat-education", 100),
    MerchantRule("r10", r"EXAMPLE HEALTH CARE", "cat-health", 100),
    MerchantRule("r11", r"EXAMPLE PHARMACY", "cat-health", 100),
    MerchantRule("r12", r"NABIL BANK LTD\.", "cat-transfer", 100),
]


def test_match_rule_case_insensitive_search():
    rule = MerchantRule("r1", "atm wdl", "cat-1", 100)
    assert match_rule("ATM WDL -03051911-NABIL-NABIL", [rule]) is rule


def test_match_rule_returns_none_when_nothing_matches():
    assert match_rule("some unrelated remarks", RULES) is None


def test_lower_priority_number_wins_on_overlapping_patterns():
    broad = MerchantRule("broad", "PHARMACY", "cat-broad", 200)
    specific = MerchantRule("specific", "EXAMPLE PHARMACY", "cat-specific", 50)
    result = match_rule("EXAMPLE PHARMACY", [broad, specific])
    assert result is specific


def test_categorize_with_rules_returns_full_confidence_guess():
    guess = categorize_with_rules("ATM WDL -03051911-NABIL-NABIL", RULES)
    assert guess is not None
    assert guess.category_id == "cat-cash-withdrawal"
    assert guess.source == "rule"
    assert guess.confidence == 1.0


def test_categorize_with_rules_none_when_no_match():
    assert categorize_with_rules("totally unmatched text", RULES) is None


def _ollama_reply(category, confidence):
    fake_response = MagicMock()
    inner = json.dumps({"category": category, "confidence": confidence})
    fake_response.read.return_value = json.dumps({"response": inner}).encode()
    fake_response.__enter__.return_value = fake_response
    return fake_response


def test_ollama_unreachable_returns_none_not_an_exception():
    with patch("urllib.request.urlopen", side_effect=urllib.error.URLError("connection refused")):
        result = categorize_with_ollama("Some Merchant", 5000, {"Food": [], "Other": []})
    assert result is None


def test_ollama_malformed_json_returns_none():
    fake_response = MagicMock()
    fake_response.read.return_value = b"not json"
    fake_response.__enter__.return_value = fake_response
    with patch("urllib.request.urlopen", return_value=fake_response):
        result = categorize_with_ollama("Some Merchant", 5000, {"Food": [], "Other": []})
    assert result is None


def test_ollama_category_outside_allowed_list_returns_none():
    with patch("urllib.request.urlopen", return_value=_ollama_reply("MadeUpCategory", 0.9)):
        result = categorize_with_ollama("Some Merchant", 5000, {"Food": [], "Other": []})
    assert result is None


def test_ollama_valid_response_returns_category_and_confidence():
    with patch("urllib.request.urlopen", return_value=_ollama_reply("Food", 0.92)):
        result = categorize_with_ollama("Some Restaurant", 5000, {"Food": [], "Other": []})
    assert result == ("Food", 0.92)
    assert result[1] >= CONFIDENCE_THRESHOLD


def test_ollama_asks_group_then_category_within_it():
    sent = []
    replies = iter([_ollama_reply("Health", 0.95), _ollama_reply("Medicine & Pharmacy", 0.9)])

    def fake_urlopen(request, timeout):
        sent.append(json.loads(request.data))
        return next(replies)

    choices = {
        "Food & Drink": ["Groceries", "Restaurants"],
        "Health": ["Hospital & Doctor", "Medicine & Pharmacy"],
        "Other": [],
    }
    with patch("urllib.request.urlopen", side_effect=fake_urlopen):
        result = categorize_with_ollama("I.C.U. PHARMACY", 274000, choices, direction="DEBIT")

    assert result == ("Medicine & Pharmacy", 0.9)
    enums = [s["format"]["properties"]["category"]["enum"] for s in sent]
    assert enums == [["Food & Drink", "Health", "Other"], ["Hospital & Doctor", "Medicine & Pharmacy"]]
    assert "money paid out" in sent[0]["prompt"]


def test_model_label_pulls_merchant_and_note_out_of_nabil_remarks():
    assert model_label("MPAY FPQR,3247383ChKlH,MEGA MART TINCHULI 2,Remar", None) == "MEGA MART TINCHULI 2"
    assert model_label("MPAY FPQR,13377051psd0,Example Hospital,clinic visit", None) == "Example Hospital (note: clinic visit)"
    assert model_label("NQR-2835230,shoe-COSELI CHHALA JU NQR-2835230,sho", None) == "COSELI CHHALA JU (note: shoe)"
    assert model_label("ESW DLA:MB4YO7BY", None) == "eSewa wallet load"
    assert model_label("OPENAI *CHATGPT SUBSCR", None) == "OPENAI *CHATGPT SUBSCR"


class _RecategorizeStore:
    def __init__(self, txns, rules=()):
        self.txns = txns
        self.rules = list(rules)
        self.applied: dict[str, tuple[str, str]] = {}
        self.needs_review: list[str] = []

    def fetch_category_tree(self, user_id):
        return TREE

    def fetch_merchant_rules(self, user_id):
        return self.rules

    def fetch_recategorize_candidates(self, user_id):
        return self.txns

    def apply_category(self, txn_id, category_id, source, confidence):
        self.applied[txn_id] = (category_id, source)

    def mark_needs_review(self, txn_id):
        self.needs_review.append(txn_id)


TREE = [
    CategoryNode("g-health", "Health", None),
    CategoryNode("c-pharmacy", "Medicine & Pharmacy", "g-health"),
    CategoryNode("c-hospital", "Hospital & Doctor", "g-health"),
    CategoryNode("g-food", "Food & Drink", None),
    CategoryNode("c-restaurants", "Restaurants", "g-food"),
    CategoryNode("c-other", "Other", None),
]
MODEL = "expense_tracker.pipeline.categorize.categorize_with_ollama"


def _txn(txn_id, category_id, source, description="MPAY FPQR,SOME MERCHANT"):
    return ReviewCandidate(txn_id, description, None, 50000, "DEBIT", category_id, source)


def test_recategorize_all_keeps_a_user_pick_that_is_still_a_category():
    store = _RecategorizeStore([_txn("t1", "c-restaurants", "user")])
    with patch(MODEL) as model:
        counts = recategorize_all(store, "u1")
    model.assert_not_called()
    assert store.applied == {}
    assert counts["kept"] == 1


def test_recategorize_all_narrows_a_user_pick_that_became_a_group_to_that_group():
    store = _RecategorizeStore([_txn("t1", "g-health", "user")])
    with patch(MODEL, return_value=("Medicine & Pharmacy", 0.9)) as model:
        recategorize_all(store, "u1")
    assert model.call_args.args[2] == {"Health": ["Hospital & Doctor", "Medicine & Pharmacy"]}
    assert store.applied == {"t1": ("c-pharmacy", "llm")}


def test_recategorize_all_applies_a_matching_rule_before_asking_the_model():
    rule = MerchantRule("r1", "PHARMACY", "c-pharmacy", 100)
    store = _RecategorizeStore([_txn("t1", "g-health", "rule", description="EXAMPLE PHARMACY")], rules=[rule])
    with patch(MODEL) as model:
        recategorize_all(store, "u1")
    model.assert_not_called()
    assert store.applied == {"t1": ("c-pharmacy", "rule")}


def test_recategorize_all_offers_the_model_groups_and_ungrouped_categories():
    store = _RecategorizeStore([_txn("t1", "c-other", "llm")])
    with patch(MODEL, return_value=("Restaurants", 0.9)) as model:
        recategorize_all(store, "u1")
    assert model.call_args.args[2] == {
        "Food & Drink": ["Restaurants"],
        "Health": ["Hospital & Doctor", "Medicine & Pharmacy"],
        "Other": [],
    }
    assert store.applied == {"t1": ("c-restaurants", "llm")}


def test_recategorize_all_unsure_model_sends_only_rows_on_a_group_back_to_review():
    store = _RecategorizeStore([_txn("t1", "g-health", "llm"), _txn("t2", "c-other", "llm")])
    with patch(MODEL, return_value=None):
        counts = recategorize_all(store, "u1")
    assert store.applied == {}
    assert store.needs_review == ["t1"]
    assert counts == {"categorized_by_rule": 0, "categorized_by_llm": 0, "kept": 1, "needs_review": 1}


def test_recategorize_all_does_not_rewrite_a_category_that_would_not_change():
    rule = MerchantRule("r1", "SOME MERCHANT", "c-restaurants", 100)
    store = _RecategorizeStore([_txn("t1", "c-restaurants", "rule")], rules=[rule])
    counts = recategorize_all(store, "u1")
    assert store.applied == {}
    assert counts["kept"] == 1


def test_seed_rules_cover_at_least_80_percent_of_real_phase0_fixtures():
    fixtures = sorted(FIXTURES_DIR.glob("*/*.eml"))
    assert len(fixtures) == 31

    matched = 0
    for path in fixtures:
        raw = path.read_bytes()
        message = email.message_from_bytes(raw, policy=email.policy.default)
        parser = route(message)
        assert parser is not None, f"{path} didn't route to any parser"
        for txn in parser.parse(message):
            if categorize_with_rules(txn.description_raw, RULES) is not None:
                matched += 1

    coverage = matched / len(fixtures)
    assert coverage >= 0.80, f"only {coverage:.0%} auto-categorized by rules alone"
