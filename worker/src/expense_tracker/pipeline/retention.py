"""Drops local raw .eml files old enough, and fully confirmed enough, that
Gmail remains the only copy that matters. See docs/EXPENSE_TRACKER_PLAN.md
section 11.3.

Deliberately conservative: only PARSED emails with at least one transaction,
where every transaction from that email has been reviewed to CONFIRMED, are
eligible. This never touches processed_emails or transactions -- those stay
forever. Only the raw archive file, the reparse-cache copy, is deleted.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from pathlib import Path

from expense_tracker.ingest import archive
from expense_tracker.store.base import Store

RETENTION_DAYS = 365


def run_retention(
    store: Store, user_id: str, archive_dir: Path, *, now: datetime | None = None
) -> int:
    """Returns the count of raw files actually deleted."""
    now = now or datetime.now(timezone.utc)
    cutoff = now - timedelta(days=RETENTION_DAYS)
    deleted = 0
    for message_id, received_at in store.fetch_retention_candidates(user_id, cutoff):
        path = archive.archive_path(archive_dir, message_id, received_at)
        if path.exists():
            path.unlink()
            deleted += 1
    return deleted
