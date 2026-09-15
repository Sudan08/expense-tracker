"""Window specs: what the user types on the prompt, turned into a datetime.

These are the only place the "how much mail?" vocabulary is defined, so the
cases that matter are the malformed ones -- a window silently resolving to
the wrong date means either a re-fetch of nothing or a surprise year-long
download.
"""

from __future__ import annotations

from datetime import datetime, timezone

import pytest

from expense_tracker.ingest.window import (
    PRESETS,
    InvalidWindow,
    describe,
    parse_window,
)

NOW = datetime(2026, 9, 15, 12, 0, tzinfo=timezone.utc)
ACCOUNT_START = datetime(2025, 1, 1, tzinfo=timezone.utc)


def resolve(spec: str) -> datetime:
    return parse_window(spec, account_start=ACCOUNT_START, now=NOW)


@pytest.mark.parametrize(
    "spec,expected_days_back",
    [("1d", 1), ("7d", 7), ("30d", 30), ("2w", 14), ("3m", 93), ("1y", 366)],
)
def test_durations_count_back_from_now(spec, expected_days_back):
    assert (NOW - resolve(spec)).days == expected_days_back


def test_duration_is_case_insensitive_and_tolerates_a_space():
    assert resolve("3M") == resolve("3m") == resolve("3 m")


def test_all_means_account_start():
    assert resolve("all") == ACCOUNT_START
    assert resolve("ALL") == ACCOUNT_START


def test_iso_date_is_taken_as_midnight_utc():
    assert resolve("2026-01-01") == datetime(2026, 1, 1, tzinfo=timezone.utc)


@pytest.mark.parametrize("spec", ["", "   ", "3x", "last week", "2026-13-01", "-7d", "d7"])
def test_nonsense_is_rejected_rather_than_guessed(spec):
    with pytest.raises(InvalidWindow):
        resolve(spec)


def test_zero_length_window_is_rejected_with_a_usable_suggestion():
    """`0d` is almost certainly a typo for "today", and resolving it to `now`
    would fetch nothing while reporting success -- the worst outcome."""
    with pytest.raises(InvalidWindow, match="1d"):
        resolve("0d")


def test_every_preset_in_the_menu_actually_parses():
    """The menu and the parser are separate lists; this is the seam where a
    typo'd preset would otherwise only show up in front of a user."""
    for preset in PRESETS:
        assert isinstance(resolve(preset.spec), datetime)


@pytest.mark.parametrize(
    "spec,phrase",
    [("1d", "1 day back"), ("7d", "7 days back"), ("30d", "4 weeks back"),
     ("3m", "3 months back"), ("1y", "12 months back")],
)
def test_describe_rounds_to_the_unit_a_human_would_use(spec, phrase):
    assert phrase in describe(resolve(spec), now=NOW)


def test_describe_switches_to_years_only_past_the_month_scale():
    far_back = datetime(2024, 1, 1, tzinfo=timezone.utc)
    assert "years back" in describe(far_back, now=NOW)


def test_describe_leads_with_the_exact_date():
    assert describe(resolve("7d"), now=NOW).startswith("2026-09-08")
