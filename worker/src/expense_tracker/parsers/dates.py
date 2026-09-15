"""Asia/Kathmandu date parsing, one format per source template."""

from __future__ import annotations

from datetime import datetime
from zoneinfo import ZoneInfo

KATHMANDU = ZoneInfo("Asia/Kathmandu")


def parse_nabil_txn_alert(s: str) -> datetime:
    """'2026-08-10 17:33' -> tz-aware, MINUTE precision."""
    return datetime.strptime(s.strip(), "%Y-%m-%d %H:%M").replace(tzinfo=KATHMANDU)


def parse_esewa_fund_load(s: str) -> datetime:
    """'31 Aug 2026, 09:45:53 AM' -> tz-aware, SECOND precision."""
    return datetime.strptime(s.strip(), "%d %b %Y, %I:%M:%S %p").replace(tzinfo=KATHMANDU)


def parse_nabil_card_txn(s: str) -> datetime:
    """'18-AUG-26' -> tz-aware, DAY precision (no time given)."""
    return datetime.strptime(s.strip(), "%d-%b-%y").replace(tzinfo=KATHMANDU)


def parse_esewa_statement(s: str) -> datetime:
    """'2026-09-14 13:40:57.0' -> tz-aware, SECOND precision.

    The "Date Time" column of eSewa's own Profile -> Statement export
    (downloaded as .xls). The trailing single-digit fraction is a fixed
    ".0" in every row seen so far, not a real sub-second reading -- %f
    accepts 1-6 digits, so it parses without needing to strip it.
    """
    return datetime.strptime(s.strip(), "%Y-%m-%d %H:%M:%S.%f").replace(tzinfo=KATHMANDU)


def parse_laxmi_sms_alert(s: str) -> datetime:
    """'11/09/26' -> tz-aware, DAY precision (no time given).

    DD/MM/YY, not US-style MM/DD/YY -- the only fixture on file (11/09/26,
    a message received on 2026-09-11) would land in the future under
    MM/DD/YY (November). Revisit if a fixture ever shows day > 12.
    """
    return datetime.strptime(s.strip(), "%d/%m/%y").replace(tzinfo=KATHMANDU)
