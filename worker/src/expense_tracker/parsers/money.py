"""Money conversion. The only place that turns a decimal string into subunits."""

from __future__ import annotations

from decimal import Decimal


def parse_subunit(amount_str: str, decimals: int = 2) -> int:
    """'10,000.00' -> 1000000. '1000.0' -> 100000. Never float."""
    cleaned = amount_str.replace(",", "").strip()
    value = Decimal(cleaned) * (10**decimals)
    return int(value.to_integral_exact())
