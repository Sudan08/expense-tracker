from datetime import datetime, timedelta, timezone

from expense_tracker.ingest.watermark import resolve_watermark


def test_uses_account_start_when_no_prior_run():
    account_start = datetime(2025, 1, 1, tzinfo=timezone.utc)
    since = resolve_watermark(None, account_start)
    assert since == account_start - timedelta(days=3)


def test_uses_last_completed_run_with_three_day_overlap():
    account_start = datetime(2025, 1, 1, tzinfo=timezone.utc)
    last_completed = datetime(2026, 8, 20, tzinfo=timezone.utc)
    since = resolve_watermark(last_completed, account_start)
    assert since == last_completed - timedelta(days=3)


def test_laptop_off_for_three_weeks_still_resolves_correctly():
    account_start = datetime(2025, 1, 1, tzinfo=timezone.utc)
    last_completed = datetime(2026, 8, 1, tzinfo=timezone.utc)
    since = resolve_watermark(last_completed, account_start)
    assert since == datetime(2026, 7, 29, tzinfo=timezone.utc)
