"""How far back to ask the mail server for -- parsing, presets, and prompting.

`sync` has always resolved its own start date from the watermark (section
6.2), which is the right default for an unattended daily run but a poor fit
for the two questions a human actually asks: "how much is even there?" and
"pull me the last three months". Both need a window chosen at the prompt
rather than derived from the last successful run, and both want to say it the
short way -- `3m`, not a computed ISO date.

Nothing here talks to IMAP or the database. It turns what the user typed into
a `datetime`, so the commands in cli.py stay about orchestration.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone

# Calendar months and years are deliberately approximated in days. The only
# consumer is an IMAP `SINCE` search whose own resolution is a whole day, and
# a backfill window is a "roughly this far back" instruction -- landing on the
# 28th rather than the 30th changes nothing a user would notice, and the
# alternative drags in a calendar library for no gain. Overshooting slightly
# is the safe direction: an extra day of overlap is deduped by Message-ID.
_UNIT_DAYS = {"d": 1, "w": 7, "m": 31, "y": 366}

_DURATION_RE = re.compile(r"^(\d+)\s*([dwmy])$", re.IGNORECASE)

ALL = "all"


@dataclass(frozen=True)
class Preset:
    """One row of the `backfill` menu."""

    key: str
    label: str
    spec: str


# Ordered cheapest-to-most-expensive, so the fast answer is the first one.
PRESETS: tuple[Preset, ...] = (
    Preset("1", "Last 7 days", "7d"),
    Preset("2", "Last 30 days", "30d"),
    Preset("3", "Last 3 months", "3m"),
    Preset("4", "Last 6 months", "6m"),
    Preset("5", "Last 1 year", "1y"),
    Preset("6", "Everything since account_start", ALL),
)


class InvalidWindow(ValueError):
    """What the user typed isn't a duration, a date, or `all`."""


def parse_window(spec: str, *, account_start: datetime, now: datetime | None = None) -> datetime:
    """Resolve a window spec to the UTC instant to fetch from.

    Accepts a duration (`7d`, `2w`, `3m`, `1y`), an ISO date (`2026-01-01`),
    or `all` -- which means `account_start`, the earliest date the config
    says this account has any history at all.

    Raises InvalidWindow with a message meant to be shown to the user as-is.
    """
    spec = (spec or "").strip()
    if not spec:
        raise InvalidWindow("no window given")

    if spec.lower() == ALL:
        return account_start

    match = _DURATION_RE.match(spec)
    if match:
        count, unit = int(match.group(1)), match.group(2).lower()
        if count == 0:
            raise InvalidWindow("a window of 0 covers nothing -- use 1d for today")
        now = now or datetime.now(timezone.utc)
        return now - timedelta(days=count * _UNIT_DAYS[unit])

    try:
        parsed = date.fromisoformat(spec)
    except ValueError:
        raise InvalidWindow(
            f"don't understand {spec!r} -- expected a duration like 7d/2w/3m/1y, "
            f"an ISO date like 2026-01-01, or 'all'"
        ) from None
    return datetime.combine(parsed, datetime.min.time(), tzinfo=timezone.utc)


def describe(since: datetime, *, now: datetime | None = None) -> str:
    """'2026-06-17 (about 3 months back)' -- for echoing a choice back."""
    now = now or datetime.now(timezone.utc)
    days = max((now - since).days, 0)
    if days == 0:
        rough = "today"
    elif days < 14:
        rough = f"about {days} day{'s' if days != 1 else ''} back"
    elif days < 70:
        rough = f"about {round(days / 7)} weeks back"
    elif days < 400:
        rough = f"about {round(days / 30)} months back"
    else:
        rough = f"about {days / 365:.1f} years back"
    return f"{since:%Y-%m-%d} ({rough})"
