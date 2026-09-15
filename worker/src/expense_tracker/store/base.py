"""Store protocol. Nothing outside this package knows about the DB.
See docs/EXPENSE_TRACKER_PLAN.md section 13 (store/supabase.py).
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Protocol

from expense_tracker.parsers.base import NormalizedTxn
from expense_tracker.parsers.sms import SmsMessage
from expense_tracker.pipeline.categorize import CategoryNode, MerchantRule, ReviewCandidate
from expense_tracker.pipeline.reconcile import BalanceRow, LedgerGap
from expense_tracker.pipeline.transfers import TransferCandidate


class StoreUnavailable(Exception):
    """The database couldn't be reached at all -- DNS failure, connection
    refused, timeout, or an established connection dying mid-run (laptop
    wake, wifi handover, the Supabase pooler dropping an idle session).

    Deliberately the mirror of ingest.source.NetworkUnavailable, and for the
    same reason: section 6.4's "a failed sync isn't an error condition,
    it's Tuesday" applies just as much to the DB leg as to the IMAP leg.
    Distinct from a server-side refusal (bad password, missing table,
    constraint violation), which carries a SQLSTATE and is a real problem
    the user must see immediately rather than have silently retried.
    """


@dataclass(frozen=True)
class SyncRunSummary:
    machine: str
    started_at: datetime
    completed_at: datetime | None
    fetched: int
    parsed: int
    failed: int
    txns_inserted: int
    error: str | None


class Store(Protocol):
    def last_completed_sync_at(self, user_id: str) -> datetime | None: ...

    def fetch_last_sync_run(self, user_id: str) -> SyncRunSummary | None:
        """The most recent sync_runs row regardless of outcome -- unlike
        last_completed_sync_at (used only for watermark resolution), this
        surfaces a failed or still-running attempt too, which is the whole
        point of `status`."""
        ...

    def count_failed_emails(self, user_id: str) -> int:
        """processed_emails with status='FAILED' -- emails that were seen
        but didn't parse. Section 6.1's `status` subcommand: "unparsed
        count"."""
        ...

    def count_open_ledger_gaps(self, user_id: str) -> int:
        """ledger_gaps with resolved=false. Section 6.1's `status`
        subcommand: "open gaps"."""
        ...

    def fetch_retention_candidates(
        self, user_id: str, older_than: datetime
    ) -> list[tuple[str, datetime]]:
        """(message_id, received_at) for every PARSED email received before
        older_than whose transactions are all CONFIRMED -- section 11.3's
        retention job. Emails with no transactions (IGNORED/FAILED, or
        PARSED with zero rows) are never eligible; there is nothing to
        confirm."""
        ...

    def get_or_create_account(
        self, user_id: str, institution: str, mask: str | None, kind: str, currency: str
    ) -> str: ...

    def upsert_processed_email(
        self,
        user_id: str,
        message_id: str,
        received_at: datetime,
        from_addr: str,
        template_key: str | None,
        parser_version: int | None,
        status: str,
        error: str | None,
        txn_count: int,
    ) -> None: ...

    def upsert_transactions(
        self,
        user_id: str,
        account_id: str,
        txns: list[NormalizedTxn],
        *,
        source_message_id: str | None = None,
        source_raw_message_id: str | None = None,
    ) -> int:
        """Returns the number of rows actually inserted (0 if all were
        already present -- ON CONFLICT (user_id, dedupe_key) DO NOTHING).

        Exactly one of source_message_id (email) and source_raw_message_id
        (SMS) identifies where the row came from; the DB enforces that with
        a check constraint, not this signature."""
        ...

    def insert_raw_message(
        self,
        user_id: str,
        *,
        channel: str,
        sender: str,
        body: str,
        received_at: datetime,
        content_hash: str,
        device: str | None = None,
    ) -> bool:
        """Stage one row for the next sync's SMS leg to pick up (see
        parsers/sms.py's module docstring -- this is also how a downloaded
        eSewa statement gets in). Returns whether it was actually inserted;
        False means (user_id, content_hash) was already on file, which is
        what makes re-importing an overlapping export idempotent."""
        ...

    def fetch_pending_raw_messages(
        self, user_id: str, limit: int = 500
    ) -> list[SmsMessage]:
        """raw_messages rows the phone has uploaded that no run has parsed
        yet (status = 'PENDING'), oldest first."""
        ...

    def mark_raw_message(
        self,
        raw_message_id: str,
        status: str,
        template_key: str | None,
        parser_version: int | None,
        error: str | None,
        txn_count: int,
    ) -> None:
        """The SMS mirror of upsert_processed_email: record what happened to
        one uploaded message so nothing is silently dropped (invariant 6)."""
        ...

    def start_sync_run(
        self, user_id: str, machine: str, started_at: datetime, since: datetime
    ) -> str: ...

    def finish_sync_run(
        self,
        run_id: str,
        completed_at: datetime,
        fetched: int,
        parsed: int,
        failed: int,
        txns_inserted: int,
        error: str | None,
    ) -> None: ...

    def fetch_transfer_candidates(
        self, user_id: str, since: datetime
    ) -> list[TransferCandidate]:
        """Transactions not yet in a transfer_group, occurred_at >= since."""
        ...

    def create_transfer_group(self, user_id: str, confidence: float) -> str: ...

    def link_transfer_leg(
        self, transfer_group_id: str, txn_id: str, excluded_from_spend: bool
    ) -> None: ...

    def fetch_balance_rows_by_account(self, user_id: str) -> dict[str, list[BalanceRow]]:
        """All transactions, grouped by account_id, each list sorted by
        occurred_at. Rows from accounts that carry no balance (eSewa
        wallets) come back with balance_after_paisa = None -- reconcile.py
        skips those rather than treating them as breaks.

        Ties on occurred_at break by (created_at, id). Nabil reports to the
        minute, so two transactions in the same minute are ordinary, and
        without a tiebreak the reconciler's notion of "consecutive" -- and
        therefore which pair a gap names -- would vary between runs over
        identical data.
        """
        ...

    def insert_ledger_gap(self, user_id: str, gap: LedgerGap) -> bool:
        """Returns True if a new row was inserted, False if this exact gap
        (account_id, after_txn_id, before_txn_id) was already recorded."""
        ...

    def resolve_gaps_absent_from(
        self, user_id: str, detected: list[tuple[str, str, str]]
    ) -> int:
        """Close every open ledger_gaps row whose (account_id, after_txn_id,
        before_txn_id) is *not* in `detected` -- the set the reconciler just
        found. Returns how many were closed.

        Marked resolved_by = 'RECONCILER' whatever actually fixed it: from
        here the two causes (a late email parsed, or a manual entry the user
        typed in the app) are indistinguishable, and claiming to know which
        would be a guess. The app stamps 'MANUAL_ENTRY' itself at the moment
        it fills one, so the honest attribution is already recorded by then
        and this never overwrites it -- it only touches rows still open.

        An empty `detected` means every open gap reconciles now, not that
        nothing was checked; the caller always runs a full pass.
        """
        ...

    def fetch_merchant_rules(self, user_id: str) -> list[MerchantRule]: ...

    def fetch_categories(self, user_id: str) -> dict[str, str]:
        """name -> category_id for every category a transaction can be filed
        under -- groups (categories some other category points at) excluded."""
        ...

    def fetch_category_tree(self, user_id: str) -> list[CategoryNode]:
        """Every category, groups included, with its parent_id."""
        ...

    def fetch_needs_review_transactions(
        self, user_id: str, limit: int
    ) -> list[ReviewCandidate]: ...

    def fetch_recategorize_candidates(self, user_id: str) -> list[ReviewCandidate]:
        """Every transaction whatever its status, with its current category
        and category_source -- except transfer-paired rows, which
        pipeline/transfers.py owns."""
        ...

    def apply_category(
        self, txn_id: str, category_id: str, source: str, confidence: float
    ) -> None:
        """Sets category_id/category_source/category_confidence and moves
        status from NEEDS_REVIEW to CATEGORIZED. Never touches
        excluded_from_spend -- see pipeline/categorize.py's module docstring."""
        ...

    def mark_needs_review(self, txn_id: str) -> None: ...

    def create_merchant_rule(
        self, user_id: str, pattern: str, category_id: str, learned_from_user: bool
    ) -> str: ...
