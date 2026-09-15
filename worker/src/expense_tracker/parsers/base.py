"""Shared parser contract. Pure and offline: no network, no DB, no config."""

from __future__ import annotations

from datetime import datetime
from email.message import EmailMessage
from typing import ClassVar, Literal, Protocol

from pydantic import BaseModel

Direction = Literal["DEBIT", "CREDIT"]
TimePrecision = Literal["SECOND", "MINUTE", "DAY"]


class NormalizedTxn(BaseModel):
    template_key: str
    parser_version: int

    institution: str  # 'NABIL' | 'ESEWA'
    account_mask: str | None = None

    occurred_at: datetime  # tz-aware, Asia/Kathmandu
    occurred_precision: TimePrecision
    direction: Direction

    # Smallest unit of `currency` (paisa for NPR, cents for USD). The column
    # this maps to is named amount_paisa in the schema, which predates
    # non-NPR templates like nabil.card_txn; the name is a historical
    # misnomer, not a claim that the value is always NPR paisa.
    amount_paisa: int
    balance_after_paisa: int | None = None
    currency: str = "NPR"

    reference: str | None = None
    description_raw: str
    counterparty: str | None = None
    channel: str | None = None

    message_id: str
    dedupe_key: str


class Parser(Protocol):
    template_key: ClassVar[str]
    parser_version: ClassVar[int]

    def matches(self, message: EmailMessage) -> bool: ...
    def parse(self, message: EmailMessage) -> list[NormalizedTxn]: ...
