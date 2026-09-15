"""since = (last successful sync_runs.completed_at or account_start) - 3 days.

No IMAP UID cursor -- UIDVALIDITY resets break it, and a resettable cursor
across multi-week gaps is exactly where silent data loss lives. A three-day
overlap window, deduped by Message-ID, costs a handful of redundant `stat`
calls; a missed cursor costs transactions you never notice.
See docs/EXPENSE_TRACKER_PLAN.md section 6.2.
"""

from __future__ import annotations

from datetime import datetime, timedelta

OVERLAP = timedelta(days=3)


def resolve_watermark(last_completed_at: datetime | None, account_start: datetime) -> datetime:
    base = last_completed_at or account_start
    return base - OVERLAP
