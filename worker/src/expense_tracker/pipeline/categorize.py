"""Categorization. See docs/EXPENSE_TRACKER_PLAN.md section 10.

    transaction
        |
        +- matches a merchant_rule?  --yes--> category, source='rule', confidence=1.0
        |
        +- no --> Ollama, structured JSON, Pydantic-validated
                     confidence >= 0.85 -> CATEGORIZED
                     below              -> NEEDS_REVIEW

Rules first, the model is a fallback, never the reverse. If Ollama isn't
running, skip it and leave rows NEEDS_REVIEW -- never fail a sync because a
model was unavailable.

Categories are grouped (categories.parent_id). A group -- any category some
other category points at -- is a heading, not something a transaction is
filed under. The model is asked group first, then category; see
categorize_with_ollama for why.

Deliberately NOT done here: setting excluded_from_spend based on category.
That flag is owned entirely by pipeline/transfers.py's confirmed pairing
(section 7.2) -- a transaction merely *labeled* "Transfer" by a merchant rule
(no confirmed counterpart yet) must still count as spend. Silently excluding
it here would be exactly the kind of guess section 7.2 warns against;
category is a label, not a spend decision.
"""

from __future__ import annotations

import json
import os
import re
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import TYPE_CHECKING

from pydantic import BaseModel, Field, ValidationError

if TYPE_CHECKING:
    from expense_tracker.store.base import Store

CONFIDENCE_THRESHOLD = 0.85
OLLAMA_URL = "http://localhost:11434/api/generate"
OLLAMA_TIMEOUT_SECONDS = int(os.environ.get("EXPENSE_TRACKER_OLLAMA_TIMEOUT", "30"))
# Which model varies by machine (whatever's been `ollama pull`ed there), so
# it's an env var rather than hardcoded -- see EXPENSE_TRACKER_* in config.py.
OLLAMA_MODEL = os.environ.get("EXPENSE_TRACKER_OLLAMA_MODEL", "gemma4:12b")

# What each group and category covers, in the terms merchants actually show
# up as, keyed by the names supabase/seed.sql creates. A category without an
# entry (renamed, or added later) is still offered, just without a hint.
GROUP_HINTS = {
    "Food & Drink": "supermarkets, marts, kirana and cold stores, bakeries, cafes, khaja ghar, restaurants, bars, food delivery",
    "Health": "pharmacies, hospitals, clinics, lab tests, dental and eye care, supplements, gyms",
    "Home & Bills": "rent, electricity, water, internet, mobile top-up (Ncell, NTC), cooking gas, repairs, household supplies",
    "Transport": "Pathao and InDrive rides, petrol pumps, buses, vehicle servicing",
    "Shopping": "clothes, shoes, electronics and laptops, Daraz and online shopping, cosmetics",
    "Subscriptions": "ChatGPT, Claude and other AI tools, cloud hosting, streaming and app subscriptions",
    "Travel": "flight and bus tickets, hotels, trip activities",
    "Education": "school and college fees, courses, books",
    "Fun & Social": "movies, events, gifts, donations, festivals, puja",
    "Family & People": "money sent to family members or friends",
    "Fees & Cash": "bank and service fees, ATM cash withdrawals",
    "Investments": "IPO share allotments, shares, mutual funds, fixed deposits",
    "Income & Transfers": "salary, dividends, interest, refunds, moving money between your own accounts or wallets",
}
CATEGORY_HINTS = {
    "Groceries": "supermarkets, marts, kirana and cold stores",
    "Restaurants": "restaurants, dining out",
    "Cafe & Bakery": "cafes, bakeries, coffee",
    "Khaja & Snacks": "khaja ghar, momo, snacks, tea shops",
    "Bars & Drinks": "bars, lounges, pubs, alcohol",
    "Food Delivery": "Foodmandu, Pathao Food, delivery apps",
    "Medicine & Pharmacy": "pharmacies, medical stores, medicines",
    "Hospital & Doctor": "hospitals, clinics, health care centers, doctor visits",
    "Lab Tests": "pathology labs, diagnostics, x-ray",
    "Dental & Eye": "dentists, opticians, eye hospitals",
    "Supplements & Nutrition": "protein, vitamins, Ensure",
    "Health Insurance": "health insurance premiums",
    "Gym & Fitness": "gyms, yoga, sports",
    "Mobile Recharge": "Ncell and NTC top-ups",
    "Internet": "WorldLink, Vianet, internet bills",
    "Electricity": "NEA electricity bills",
    "Online Shopping": "Daraz and other online stores, ECOM purchases",
    "Electronics & Gadgets": "laptops, phones, electronics stores",
    "Clothing & Shoes": "clothes, shoes, fashion stores",
    "Personal Care & Cosmetics": "cosmetics, salons, grooming",
    "AI Tools": "ChatGPT, OpenAI, Claude",
    "Cloud & Hosting": "Contabo, AWS, servers, domains",
    "Streaming & Apps": "Netflix, Spotify, YouTube, app stores",
    "Bank Fees": "bank charges, IPS and transfer fees, card fees, ASBA fees",
    "Cash Withdrawal": "ATM cash withdrawals",
    "IPO & Shares": "IPO allotments, share purchases",
    "Dividends & Interest": "dividends, interest",
    "Transfer": "moving money between your own accounts or wallets",
    "Tuition & Fees": "school, college and educational institute fees",
    "Courses & Books": "online courses, books",
    "Other": "nothing else fits",
}

_ANSWER_FORMAT = 'Respond with JSON only: {"category": "...", "confidence": 0.0-1.0}'
_FILLER_REMARK = re.compile(r"^(remar|sales|$)", re.IGNORECASE)


@dataclass(frozen=True)
class MerchantRule:
    id: str
    pattern: str  # regex over description_raw
    category_id: str
    priority: int


@dataclass(frozen=True)
class ReviewCandidate:
    id: str
    description_raw: str
    counterparty: str | None
    amount_paisa: int
    direction: str | None = None  # 'DEBIT' | 'CREDIT'
    # Only filled for recategorize_all, which has to know what a row is
    # already filed under and who put it there.
    category_id: str | None = None
    category_source: str | None = None


@dataclass(frozen=True)
class CategoryNode:
    id: str
    name: str
    parent_id: str | None


@dataclass(frozen=True)
class CategoryGuess:
    category_id: str
    source: str  # 'rule' | 'llm'
    confidence: float


class _OllamaResponse(BaseModel):
    category: str
    confidence: float = Field(ge=0, le=1)


def match_rule(description_raw: str, rules: list[MerchantRule]) -> MerchantRule | None:
    """Rules assumed unsorted; lower `priority` wins on a tie for who
    matches first (matches the schema's `priority int default 100` -- room
    for rules more/less specific than the default)."""
    for rule in sorted(rules, key=lambda r: r.priority):
        if re.search(rule.pattern, description_raw, re.IGNORECASE):
            return rule
    return None


def categorize_with_rules(
    description_raw: str, rules: list[MerchantRule]
) -> CategoryGuess | None:
    rule = match_rule(description_raw, rules)
    if rule is None:
        return None
    return CategoryGuess(category_id=rule.category_id, source="rule", confidence=1.0)


def model_label(description_raw: str, counterparty: str | None) -> str:
    """What the model is shown for a transaction: the merchant, plus the
    payer's note when there is one. Nabil's remarks bury the merchant between
    terminal codes ("MPAY FPQR,3247383ChKlH,MEGA MART TINCHULI 2,Remar...")
    and a small model reads the codes, not the name.
    """
    if m := re.match(r"MPAY FPQR,[^,]*,([^,]+)(?:,(.*))?", description_raw):
        merchant, remark = m.group(1), m.group(2) or ""
    elif m := re.match(r"NQR-\d+,([^-]*)-(.+?)(?: NQR-|$)", description_raw):
        remark, merchant = m.group(1), m.group(2)
    elif description_raw.startswith("MPAY "):
        details = [f.strip() for f in description_raw.split(",")[2:] if f.strip() and not f.strip().isdigit()]
        return "mobile payment" + (f" ({', '.join(details)})" if details else "")
    elif description_raw.startswith("ESW DLA:"):
        return "eSewa wallet load"
    elif description_raw.startswith("eSewa Load"):
        return "eSewa wallet load to a phone number"
    else:
        return counterparty or description_raw
    merchant, remark = merchant.strip(), remark.split(";")[0].strip()
    return merchant if _FILLER_REMARK.match(remark) else f"{merchant} (note: {remark})"


def _ask_ollama(prompt: str, choices: list[str]) -> tuple[str, float] | None:
    """One question whose answer must be one of `choices`. None on any
    failure: Ollama not running, a bad response, whatever. Never raises."""
    model = os.environ.get("EXPENSE_TRACKER_OLLAMA_MODEL", OLLAMA_MODEL)
    timeout = int(os.environ.get("EXPENSE_TRACKER_OLLAMA_TIMEOUT", str(OLLAMA_TIMEOUT_SECONDS)))
    payload = json.dumps(
        {
            "model": model,
            "prompt": prompt,
            # A JSON schema rather than plain "json": the enum makes Ollama
            # constrain decoding to the exact names, instead of a paraphrase
            # ("Pharmacy" for "Medicine & Pharmacy") being thrown away below.
            "format": {
                "type": "object",
                "properties": {
                    "category": {"type": "string", "enum": choices},
                    "confidence": {"type": "number"},
                },
                "required": ["category", "confidence"],
            },
            "stream": False,
            # Reasoning models (e.g. qwen3.5) otherwise put the whole answer
            # in a separate "thinking" field and leave "response" empty.
            "think": False,
        }
    ).encode()

    try:
        request = urllib.request.Request(
            OLLAMA_URL, data=payload, headers={"Content-Type": "application/json"}
        )
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = json.loads(response.read())
        parsed = _OllamaResponse.model_validate_json(body["response"])
    except (
        urllib.error.URLError,
        TimeoutError,
        json.JSONDecodeError,
        ValidationError,
        KeyError,
    ):
        return None

    if parsed.category not in choices:
        return None
    return parsed.category, parsed.confidence


def _option_line(name: str) -> str:
    hint = GROUP_HINTS.get(name) or CATEGORY_HINTS.get(name)
    return f"- {name}: {hint}" if hint else f"- {name}"


def categorize_with_ollama(
    label: str,
    amount_paisa: int,
    choices: dict[str, list[str]],
    direction: str | None = None,
) -> tuple[str, float] | None:
    """Sends only the transaction's label (see model_label), amount, and
    direction -- never the raw email (section 10). Returns (category_name,
    confidence), or None if the model couldn't be reached or didn't answer.

    `choices` maps each group to its category names; a category with no group
    (e.g. "Other") maps to an empty list and is offered alongside the groups.

    Two questions -- which group, then which category in it -- because one
    question over ~50 names doesn't work on a small local model: llama3.2
    filed a supermarket, a bakery, and a shoe shop all under Cash Withdrawal.
    On 28 hand-labelled real transactions, a single question got 7 right;
    group-then-category with the hints above got 23.
    """
    flow = {"DEBIT": "money paid out", "CREDIT": "money received"}.get(direction or "")
    facts = (
        f"Transaction: {label}\n"
        f"Amount: NPR {amount_paisa / 100:.2f}\n"
        + (f"Direction: {flow}\n" if flow else "")
    )

    if len(choices) == 1:
        group, confidence = next(iter(choices)), 1.0
    else:
        answer = _ask_ollama(
            "Classify this Nepali bank transaction into one of these groups:\n"
            + "\n".join(_option_line(name) for name in choices)
            + f"\n\n{facts}{_ANSWER_FORMAT}",
            list(choices),
        )
        if answer is None:
            return None
        group, confidence = answer

    categories = choices[group]
    if not categories:
        return group, confidence
    answer = _ask_ollama(
        f"This Nepali bank transaction is {group}. Pick the specific category:\n"
        + "\n".join(_option_line(name) for name in categories)
        + f"\n\n{facts}{_ANSWER_FORMAT}",
        categories,
    )
    if answer is None:
        return None
    return answer[0], min(confidence, answer[1])


def _category_choices(
    nodes: list[CategoryNode],
) -> tuple[dict[str, list[str]], dict[str, str], dict[str, str]]:
    """-> (categorize_with_ollama's `choices`, category name -> id with groups
    excluded, group id -> group name). Groups come first, ungrouped
    categories last, each alphabetical."""
    parent_ids = {n.parent_id for n in nodes if n.parent_id is not None}
    groups = {n.id: n.name for n in nodes if n.id in parent_ids}
    choices: dict[str, list[str]] = {name: [] for name in sorted(groups.values())}
    category_ids: dict[str, str] = {}
    for n in sorted(nodes, key=lambda n: n.name):
        if n.id in groups:
            continue
        category_ids[n.name] = n.id
        if n.parent_id in groups:
            choices[groups[n.parent_id]].append(n.name)
        else:
            choices[n.name] = []
    return choices, category_ids, groups


def categorize_and_record(
    store: "Store", user_id: str, use_ollama: bool = False, limit: int = 500
) -> dict[str, int]:
    """Section 6.1 step 9. Runs over every NEEDS_REVIEW transaction. Returns
    counts: {"categorized_by_rule": N, "categorized_by_llm": N, "still_review": N}.
    """
    rules = store.fetch_merchant_rules(user_id)
    counts = {"categorized_by_rule": 0, "categorized_by_llm": 0, "still_review": 0}

    if use_ollama:
        choices, category_ids, _ = _category_choices(store.fetch_category_tree(user_id))

    for txn in store.fetch_needs_review_transactions(user_id, limit=limit):
        guess = categorize_with_rules(txn.description_raw, rules)
        if guess is not None:
            store.apply_category(txn.id, guess.category_id, guess.source, guess.confidence)
            counts["categorized_by_rule"] += 1
            continue

        if use_ollama:
            result = categorize_with_ollama(
                model_label(txn.description_raw, txn.counterparty),
                txn.amount_paisa,
                choices,
                direction=txn.direction,
            )
            if result is not None:
                name, confidence = result
                if confidence >= CONFIDENCE_THRESHOLD:
                    store.apply_category(txn.id, category_ids[name], "llm", confidence)
                    counts["categorized_by_llm"] += 1
                    continue

        counts["still_review"] += 1

    return counts


def recategorize_all(store: "Store", user_id: str) -> dict[str, int]:
    """`categorize --all`: re-file every transaction, not just the
    NEEDS_REVIEW pile -- for after the category list itself has changed.

    - A category the user picked themselves is kept, unless it has since
      become a group; then the model only chooses among that group's
      categories, so "Health" becomes a kind of health spend, not a new guess.
    - Everything else goes rules first, then the model -- the same order a
      sync uses.
    - When the model is unsure, a row still on a group goes back to
      NEEDS_REVIEW and any other row keeps what it had.
    - A row whose category wouldn't change isn't written, so a CONFIRMED row
      stays CONFIRMED.
    - Transfer-paired rows never come back from the store: pipeline/transfers.py
      owns those.
    """
    choices, category_ids, groups = _category_choices(store.fetch_category_tree(user_id))
    rules = store.fetch_merchant_rules(user_id)
    counts = {"categorized_by_rule": 0, "categorized_by_llm": 0, "kept": 0, "needs_review": 0}

    for txn in store.fetch_recategorize_candidates(user_id):
        on_group = txn.category_id in groups
        if txn.category_source == "user":
            if not on_group:
                counts["kept"] += 1
                continue
            group = groups[txn.category_id]
            options = {group: choices[group]}
        else:
            guess = categorize_with_rules(txn.description_raw, rules)
            if guess is not None and guess.category_id not in groups:
                if guess.category_id == txn.category_id:
                    counts["kept"] += 1
                else:
                    store.apply_category(txn.id, guess.category_id, guess.source, guess.confidence)
                    counts["categorized_by_rule"] += 1
                continue
            options = choices

        result = categorize_with_ollama(
            model_label(txn.description_raw, txn.counterparty),
            txn.amount_paisa,
            options,
            direction=txn.direction,
        )
        if result is not None and result[1] >= CONFIDENCE_THRESHOLD:
            if category_ids[result[0]] == txn.category_id:
                counts["kept"] += 1
            else:
                store.apply_category(txn.id, category_ids[result[0]], "llm", result[1])
                counts["categorized_by_llm"] += 1
        elif on_group:
            store.mark_needs_review(txn.id)
            counts["needs_review"] += 1
        else:
            counts["kept"] += 1

    return counts
