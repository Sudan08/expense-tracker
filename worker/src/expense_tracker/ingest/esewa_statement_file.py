"""Reads an eSewa 'Statement' export (.xls, from Profile -> Statement in the
app -- see parsers/esewa_statement.py's module docstring for why this exists
at all: eSewa sends no email or SMS for a wallet-to-wallet transfer, only
this on-demand export carries every transaction type plus a running
balance) and turns it into the rows the statement parser expects.

Pure file I/O plus row-shaping -- the reference->NormalizedTxn mapping stays
in parsers/esewa_statement.py, same separation email/SMS parsing already
keeps from their own staging code.
"""

from __future__ import annotations

import base64
import hashlib
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

import xlrd

from expense_tracker.parsers.esewa_statement import SENDER

# The sheet's own header row, in column order. Located by content rather
# than an assumed row offset -- see rows_from_sheet_values.
_HEADER = [
    "Reference Code", "Date Time", "Description", "Dr.", "Cr.", "Status",
    "Balance (NPR)", "Channel",
]


@dataclass(frozen=True)
class StatementRow:
    reference: str
    datetime_str: str
    description: str
    dr: str
    cr: str
    balance: str
    channel: str


def rows_from_workbook_bytes(data: bytes) -> list[StatementRow]:
    """The .xls's own bytes -> StatementRows, no temp file needed (xlrd reads
    straight out of memory via file_contents). What EsewaStatementFileParser
    calls after base64-decoding a staged raw_messages body.
    """
    book = xlrd.open_workbook(file_contents=data)
    sheet = book.sheet_by_index(0)
    return rows_from_sheet_values([sheet.row_values(r) for r in range(sheet.nrows)])


def read_statement_rows(path: Path) -> list[StatementRow]:
    """Every COMPLETE transaction row in a local export -- what the CLI
    import command uses to print a friendly row count before staging."""
    return rows_from_workbook_bytes(path.read_bytes())


def rows_from_sheet_values(all_rows: list[list]) -> list[StatementRow]:
    """The xlrd-independent half of the read path: turns whatever
    `sheet.row_values(r)` returned for every row into StatementRows. Split
    out so tests can hand this plain Python lists instead of authoring a
    real .xls fixture, the same reason parsers/base.py stays pure and offline.

    A real export has a report header above the table (From/To Date,
    Generated On, ...) and a totals/per-status-count footer below it -- the
    header row itself is found by content rather than an assumed offset,
    since a different date-range or status filter changes how many lines
    precede it. The table ends at the first row whose reference cell is
    blank or "Total".
    """
    header_row = None
    for r, values in enumerate(all_rows):
        if [str(c).strip() for c in values[: len(_HEADER)]] == _HEADER:
            header_row = r
            break
    if header_row is None:
        raise ValueError("esewa statement: header row not found")

    rows: list[StatementRow] = []
    for values in all_rows[header_row + 1 :]:
        reference = str(values[0]).strip()
        if not reference or reference == "Total":
            break
        status = str(values[5]).strip()
        if status != "COMPLETE":
            # PENDING/CANCELED/TIMED OUT never moved money -- nothing to
            # record, and no balance to chain reconciliation against.
            continue
        rows.append(
            StatementRow(
                reference=reference,
                datetime_str=str(values[1]).strip(),
                description=str(values[2]).strip(),
                dr=str(values[3]),
                cr=str(values[4]),
                balance=str(values[6]),
                channel=str(values[7]).strip(),
            )
        )
    return rows


def whole_file_raw_message_fields(file_bytes: bytes) -> dict:
    """sender/body/received_at/content_hash for Store.insert_raw_message,
    staging the entire export as one row (see parsers/esewa_statement.py's
    module docstring for why one row per file, not one per transaction).

    content_hash is sha256 of the raw file bytes. Two exports covering an
    overlapping date range will *not* share a hash (eSewa's own "Generated
    On" timestamp is baked into the file), so both get staged and both get
    parsed -- harmless, since every row's insert still collides on
    dedupe_key at the transactions table. What this hash *does* make
    idempotent is staging the exact same download twice by accident (the
    phone re-uploading after a retry, say).

    received_at is upload time, not a date pulled from the spreadsheet: the
    file covers many transactions with many different timestamps, and
    nothing downstream orders on it the way the SMS watermark does -- there
    is no incremental "since" cursor for statement uploads, only an explicit
    user action each time.
    """
    return {
        "sender": SENDER,
        "body": base64.b64encode(file_bytes).decode("ascii"),
        "received_at": datetime.now(timezone.utc),
        "content_hash": hashlib.sha256(file_bytes).hexdigest(),
    }
