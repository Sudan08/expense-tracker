"""Bulk upserts over a direct Postgres connection (psycopg). Nothing else in
the worker knows about the DB. See docs/EXPENSE_TRACKER_PLAN.md section 5:
"psycopg is better for bulk upserts" than supabase-py for this use case.

Connects with the service_role connection string -- this bypasses RLS by
design (section 11.1): only the worker writes financial facts.

One connection is held for the whole run, and a run spans a slow IMAP fetch
and (with --use-ollama) a slow local model, so that connection sits idle for
minutes at a stretch. Supabase's pooler drops idle sessions, and a laptop
wake or wifi handover kills the socket outright. Every statement therefore
goes through _execute, which reconnects and retries once when it finds the
connection dead underneath it.
"""

from __future__ import annotations

import contextlib
import logging
from datetime import datetime
from typing import Any, Literal

import psycopg

from expense_tracker.parsers.base import NormalizedTxn
from expense_tracker.parsers.sms import SmsMessage
from expense_tracker.pipeline.categorize import CategoryNode, MerchantRule, ReviewCandidate
from expense_tracker.pipeline.reconcile import BalanceRow, LedgerGap
from expense_tracker.pipeline.transfers import TransferCandidate
from expense_tracker.store.base import StoreUnavailable, SyncRunSummary

_ACCOUNT_KIND = {"NABIL": "BANK", "ESEWA": "WALLET"}

logger = logging.getLogger(__name__)

# Bound the connect attempt. libpq's default is to wait indefinitely, which
# on a just-woken laptop with no route yet means the run hangs holding the
# sync lock instead of failing fast and letting the retry loop handle it.
_CONNECT_TIMEOUT_SECONDS = 15

# TCP keepalives so a connection killed by the pooler (or by a NAT that
# forgot us over a long Ollama pass) is reported as dead promptly, rather
# than the next query blocking until the OS gives up minutes later.
_KEEPALIVE_PARAMS: dict[str, int] = {
    "keepalives": 1,
    "keepalives_idle": 30,
    "keepalives_interval": 10,
    "keepalives_count": 3,
}


class PostgresStore:
    def __init__(self, db_url: str) -> None:
        self._db_url = db_url
        self._conn: psycopg.Connection | None = None
        self._connect()

    def _connect(self) -> None:
        try:
            self._conn = psycopg.connect(
                self._db_url,
                autocommit=True,
                connect_timeout=_CONNECT_TIMEOUT_SECONDS,
                **_KEEPALIVE_PARAMS,
            )
        except psycopg.OperationalError as exc:
            raise _classify(exc, "connect") from exc

    def _reconnect(self) -> None:
        if self._conn is not None:
            with contextlib.suppress(Exception):
                self._conn.close()
        self._conn = None
        self._connect()

    def _execute(
        self,
        sql: str,
        params: tuple = (),
        *,
        fetch: Literal["one", "all"] | None = None,
        retry: bool = True,
    ) -> Any:
        """Run one autocommitted statement, reconnecting once if the
        connection turns out to be dead.

        retry=False is for the handful of plain INSERTs with no ON CONFLICT
        clause: if such a statement did reach the server and commit before
        the socket broke, re-running it would create a second row. Every
        other statement here is a SELECT, an idempotent upsert, or an UPDATE
        keyed by id, all of which are safe to repeat.
        """
        attempts = 2 if retry else 1
        for attempt in range(1, attempts + 1):
            try:
                assert self._conn is not None
                with self._conn.cursor() as cur:
                    cur.execute(sql, params)
                    if fetch == "one":
                        return cur.fetchone()
                    if fetch == "all":
                        return cur.fetchall()
                    return None
            except psycopg.OperationalError as exc:
                if exc.sqlstate is not None:
                    # The server answered and said no. Reconnecting changes
                    # nothing; this is a real problem to surface.
                    raise
                if attempt == attempts:
                    raise _classify(exc, "query") from exc
                logger.warning("database connection lost, reconnecting: %s", exc)
                self._reconnect()

    def close(self) -> None:
        if self._conn is not None:
            with contextlib.suppress(Exception):
                self._conn.close()
            self._conn = None

    def last_completed_sync_at(self, user_id: str) -> datetime | None:
        row = self._execute(
            """
            select max(completed_at) from sync_runs
            where user_id = %s and completed_at is not null and error is null
            """,
            (user_id,),
            fetch="one",
        )
        return row[0] if row else None

    def fetch_last_sync_run(self, user_id: str) -> SyncRunSummary | None:
        row = self._execute(
            """
            select machine, started_at, completed_at, fetched, parsed, failed,
                   txns_inserted, error
            from sync_runs
            where user_id = %s
            order by started_at desc
            limit 1
            """,
            (user_id,),
            fetch="one",
        )
        if row is None:
            return None
        return SyncRunSummary(
            machine=row[0], started_at=row[1], completed_at=row[2],
            fetched=row[3], parsed=row[4], failed=row[5],
            txns_inserted=row[6], error=row[7],
        )

    def count_failed_emails(self, user_id: str) -> int:
        return self._execute(
            "select count(*) from processed_emails where user_id = %s and status = 'FAILED'",
            (user_id,),
            fetch="one",
        )[0]

    def count_open_ledger_gaps(self, user_id: str) -> int:
        return self._execute(
            "select count(*) from ledger_gaps where user_id = %s and not resolved",
            (user_id,),
            fetch="one",
        )[0]

    def fetch_retention_candidates(
        self, user_id: str, older_than: datetime
    ) -> list[tuple[str, datetime]]:
        rows = self._execute(
            """
            select p.message_id, p.received_at
            from processed_emails p
            where p.user_id = %s
              and p.status = 'PARSED'
              and p.txn_count > 0
              and p.received_at < %s
              and not exists (
                  select 1 from transactions t
                  where t.source_message_id = p.message_id and t.status <> 'CONFIRMED'
              )
            """,
            (user_id, older_than),
            fetch="all",
        )
        return [(row[0], row[1]) for row in rows]

    def get_or_create_account(
        self, user_id: str, institution: str, mask: str | None, kind: str, currency: str
    ) -> str:
        # mask coerced to '' rather than left NULL: the unique(user_id,
        # institution, mask) constraint can't dedupe on NULL (Postgres NULLs
        # are never equal to each other), which would silently create a
        # fresh account row on every sync for accounts with no natural mask
        # (the eSewa wallet, which has none).
        mask = mask or ""
        row = self._execute(
            """
            select id from accounts
            where user_id = %s and institution = %s and mask = %s
            """,
            (user_id, institution, mask),
            fetch="one",
        )
        if row:
            return str(row[0])

        display_name = f"{institution} {mask}".strip() if mask else institution
        return str(
            self._execute(
                """
                insert into accounts (user_id, kind, institution, mask, display_name, currency)
                values (%s, %s, %s, %s, %s, %s)
                on conflict (user_id, institution, mask) do update set institution = excluded.institution
                returning id
                """,
                (user_id, kind, institution, mask, display_name, currency),
                fetch="one",
            )[0]
        )

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
    ) -> None:
        self._execute(
            """
            insert into processed_emails
                (message_id, user_id, received_at, from_addr, template_key,
                 parser_version, status, error, txn_count)
            values (%s, %s, %s, %s, %s, %s, %s, %s, %s)
            on conflict (message_id) do update set
                template_key = excluded.template_key,
                parser_version = excluded.parser_version,
                status = excluded.status,
                error = excluded.error,
                txn_count = excluded.txn_count,
                processed_at = now()
            """,
            (
                message_id,
                user_id,
                received_at,
                from_addr,
                template_key,
                parser_version,
                status,
                error,
                txn_count,
            ),
        )

    def upsert_transactions(
        self,
        user_id: str,
        account_id: str,
        txns: list[NormalizedTxn],
        *,
        source_message_id: str | None = None,
        source_raw_message_id: str | None = None,
    ) -> int:
        inserted = 0
        for txn in txns:
            row = self._execute(
                """
                insert into transactions
                    (user_id, account_id, source_message_id, source_raw_message_id,
                     occurred_at,
                     occurred_precision, direction, amount_paisa, balance_after_paisa,
                     currency, reference, description_raw, counterparty, channel,
                     dedupe_key, parser_version)
                values (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                -- Nabil reports one transaction over two transports, and they
                -- carry different things: the SMS arrives in seconds but
                -- quotes no balance, the email arrives at the next sync and
                -- does. They collapse onto one row by dedupe_key
                -- (parsers/nabil.py), and this is where the second arrival
                -- contributes what the first couldn't rather than being
                -- thrown away -- without it, an SMS-first row would keep a
                -- null balance forever and reconcile.py would skip it, which
                -- silently disables gap detection for the account.
                --
                -- coalesce, so the existing value always wins where it has
                -- one: this fills blanks, it never overwrites a fact already
                -- recorded. Everything else about the row -- amount,
                -- direction, category, status, note -- is left exactly as it
                -- was, so a re-parse of the same message stays a no-op.
                on conflict (user_id, dedupe_key) do update set
                    balance_after_paisa =
                        coalesce(transactions.balance_after_paisa,
                                 excluded.balance_after_paisa),
                    reference = coalesce(transactions.reference, excluded.reference),
                    -- Nabil's SMS truncates the remarks at 18 characters, so
                    -- an SMS-first row displays "ATM WDL -03051911-" where the
                    -- email would have said "ATM WDL -03051911-NABIL-NABIL".
                    -- Take the longer text when it is an *extension* of what
                    -- is already stored -- never a different string, which
                    -- would mean the two rows aren't the same transaction and
                    -- overwriting would hide that.
                    -- The wildcard below is written doubled on purpose. This
                    -- statement is executed with bound parameters, and
                    -- psycopg scans the whole string -- comments included --
                    -- treating a single percent sign as the start of a
                    -- placeholder, so an un-doubled one rejects the query.
                    description_raw = case
                        when excluded.description_raw <> transactions.description_raw
                         and excluded.description_raw like transactions.description_raw || '%%'
                        then excluded.description_raw
                        else transactions.description_raw
                    end,
                    counterparty = coalesce(transactions.counterparty, excluded.counterparty),
                    channel = coalesce(transactions.channel, excluded.channel)
                -- xmax = 0 is true only for a genuine insert, so the caller's
                -- "inserted" count stays honest now that the conflict path
                -- returns a row too.
                returning id, (xmax = 0) as was_inserted
                """,
                (
                    user_id,
                    account_id,
                    source_message_id,
                    source_raw_message_id,
                    txn.occurred_at,
                    txn.occurred_precision,
                    txn.direction,
                    txn.amount_paisa,
                    txn.balance_after_paisa,
                    txn.currency,
                    txn.reference,
                    txn.description_raw,
                    txn.counterparty,
                    txn.channel,
                    txn.dedupe_key,
                    txn.parser_version,
                ),
                fetch="one",
            )
            if row is not None and row[1]:
                inserted += 1
        return inserted

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
        row = self._execute(
            """
            insert into raw_messages
                (user_id, channel, sender, body, received_at, content_hash, device)
            values (%s, %s, %s, %s, %s, %s, %s)
            on conflict (user_id, content_hash) do nothing
            returning id
            """,
            (user_id, channel, sender, body, received_at, content_hash, device),
            fetch="one",
        )
        return row is not None

    def fetch_pending_raw_messages(
        self, user_id: str, limit: int = 500
    ) -> list[SmsMessage]:
        rows = self._execute(
            """
            select id, sender, body, received_at, content_hash
            from raw_messages
            where user_id = %s and status = 'PENDING'
            order by received_at
            limit %s
            """,
            (user_id, limit),
            fetch="all",
        )
        return [
            SmsMessage(
                id=str(r[0]),
                sender=r[1],
                body=r[2],
                received_at=r[3],
                content_hash=r[4],
            )
            for r in rows
        ]

    def mark_raw_message(
        self,
        raw_message_id: str,
        status: str,
        template_key: str | None,
        parser_version: int | None,
        error: str | None,
        txn_count: int,
    ) -> None:
        self._execute(
            """
            update raw_messages
               set status = %s, template_key = %s, parser_version = %s,
                   error = %s, txn_count = %s, processed_at = now()
             where id = %s
            """,
            (status, template_key, parser_version, error, txn_count, raw_message_id),
        )

    def start_sync_run(
        self, user_id: str, machine: str, started_at: datetime, since: datetime
    ) -> str:
        return str(
            self._execute(
                """
                insert into sync_runs (user_id, machine, started_at, since)
                values (%s, %s, %s, %s)
                returning id
                """,
                (user_id, machine, started_at, since),
                fetch="one",
                retry=False,
            )[0]
        )

    def finish_sync_run(
        self,
        run_id: str,
        completed_at: datetime,
        fetched: int,
        parsed: int,
        failed: int,
        txns_inserted: int,
        error: str | None,
    ) -> None:
        self._execute(
            """
            update sync_runs set
                completed_at = %s, fetched = %s, parsed = %s,
                failed = %s, txns_inserted = %s, error = %s
            where id = %s
            """,
            (completed_at, fetched, parsed, failed, txns_inserted, error, run_id),
        )

    def fetch_transfer_candidates(
        self, user_id: str, since: datetime
    ) -> list[TransferCandidate]:
        rows = self._execute(
            """
            select t.id, t.account_id, a.institution, t.direction, t.amount_paisa,
                   t.occurred_at, t.description_raw, t.counterparty
            from transactions t
            join accounts a on a.id = t.account_id
            where t.user_id = %s and t.transfer_group_id is null and t.occurred_at >= %s
            """,
            (user_id, since),
            fetch="all",
        )
        return [
            TransferCandidate(
                id=str(row[0]), account_id=str(row[1]), institution=row[2],
                direction=row[3], amount_paisa=row[4], occurred_at=row[5],
                description_raw=row[6], counterparty=row[7],
            )
            for row in rows
        ]

    def create_transfer_group(self, user_id: str, confidence: float) -> str:
        return str(
            self._execute(
                "insert into transfer_groups (user_id, confidence) values (%s, %s) returning id",
                (user_id, confidence),
                fetch="one",
                retry=False,
            )[0]
        )

    def link_transfer_leg(
        self, transfer_group_id: str, txn_id: str, excluded_from_spend: bool
    ) -> None:
        self._execute(
            "update transactions set transfer_group_id = %s, excluded_from_spend = %s "
            "where id = %s",
            (transfer_group_id, excluded_from_spend, txn_id),
        )

    def fetch_balance_rows_by_account(self, user_id: str) -> dict[str, list[BalanceRow]]:
        rows = self._execute(
            """
            select id, account_id, occurred_at, direction, amount_paisa, balance_after_paisa
            from transactions
            where user_id = %s
            order by account_id, occurred_at, created_at, id
            """,
            (user_id,),
            fetch="all",
        )
        by_account: dict[str, list[BalanceRow]] = {}
        for row in rows:
            account_id = str(row[1])
            by_account.setdefault(account_id, []).append(
                BalanceRow(
                    id=str(row[0]), account_id=account_id, occurred_at=row[2],
                    direction=row[3], amount_paisa=row[4], balance_after_paisa=row[5],
                )
            )
        return by_account

    def insert_ledger_gap(self, user_id: str, gap: LedgerGap) -> bool:
        row = self._execute(
            """
            insert into ledger_gaps
                (user_id, account_id, after_txn_id, before_txn_id, missing_paisa)
            values (%s, %s, %s, %s, %s)
            on conflict (account_id, after_txn_id, before_txn_id) do nothing
            returning id
            """,
            (user_id, gap.account_id, gap.after_txn_id, gap.before_txn_id, gap.missing_paisa),
            fetch="one",
        )
        return row is not None

    def resolve_gaps_absent_from(
        self, user_id: str, detected: list[tuple[str, str, str]]
    ) -> int:
        """See Store.resolve_gaps_absent_from.

        The detected set is passed as three parallel uuid arrays rather than
        a list of tuples: an anonymous `record[]` has no field types for
        Postgres to compare against uuid columns, and a VALUES list would
        need special-casing for the empty set. Here the empty case falls out
        correctly on its own -- unnest of three empty arrays yields no rows,
        NOT EXISTS is true for every open gap, and "nothing is a gap any
        more" closes all of them, which is exactly right.
        """
        account_ids = [d[0] for d in detected]
        after_ids = [d[1] for d in detected]
        before_ids = [d[2] for d in detected]
        rows = self._execute(
            """
            update ledger_gaps g
               set resolved     = true,
                   resolved_at  = now(),
                   resolved_by  = 'RECONCILER'
             where g.user_id = %s
               and not g.resolved
               and not exists (
                   select 1
                     from unnest(%s::uuid[], %s::uuid[], %s::uuid[])
                          as d(account_id, after_txn_id, before_txn_id)
                    where d.account_id    = g.account_id
                      and d.after_txn_id  = g.after_txn_id
                      and d.before_txn_id = g.before_txn_id
               )
            returning g.id
            """,
            (user_id, account_ids, after_ids, before_ids),
            fetch="all",
        )
        return len(rows)

    def fetch_merchant_rules(self, user_id: str) -> list[MerchantRule]:
        rows = self._execute(
            "select id, pattern, category_id, priority from merchant_rules where user_id = %s",
            (user_id,),
            fetch="all",
        )
        return [
            MerchantRule(id=str(r[0]), pattern=r[1], category_id=str(r[2]), priority=r[3])
            for r in rows
        ]

    def fetch_categories(self, user_id: str) -> dict[str, str]:
        rows = self._execute(
            "select c.name, c.id from categories c where c.user_id = %s "
            "and not exists (select 1 from categories child where child.parent_id = c.id)",
            (user_id,),
            fetch="all",
        )
        return {name: str(cid) for name, cid in rows}

    def fetch_category_tree(self, user_id: str) -> list[CategoryNode]:
        rows = self._execute(
            "select id, name, parent_id from categories where user_id = %s", (user_id,), fetch="all"
        )
        return [
            CategoryNode(id=str(r[0]), name=r[1], parent_id=None if r[2] is None else str(r[2]))
            for r in rows
        ]

    def fetch_needs_review_transactions(self, user_id: str, limit: int) -> list[ReviewCandidate]:
        rows = self._execute(
            "select id, description_raw, counterparty, amount_paisa, direction from transactions "
            "where user_id = %s and status = 'NEEDS_REVIEW' order by occurred_at limit %s",
            (user_id, limit),
            fetch="all",
        )
        return [
            ReviewCandidate(
                id=str(r[0]), description_raw=r[1], counterparty=r[2], amount_paisa=r[3],
                direction=r[4],
            )
            for r in rows
        ]

    def fetch_recategorize_candidates(self, user_id: str) -> list[ReviewCandidate]:
        rows = self._execute(
            "select id, description_raw, counterparty, amount_paisa, direction, category_id, "
            "category_source from transactions "
            "where user_id = %s and transfer_group_id is null order by occurred_at",
            (user_id,),
            fetch="all",
        )
        return [
            ReviewCandidate(
                id=str(r[0]), description_raw=r[1], counterparty=r[2], amount_paisa=r[3],
                direction=r[4], category_id=None if r[5] is None else str(r[5]),
                category_source=r[6],
            )
            for r in rows
        ]

    def apply_category(
        self, txn_id: str, category_id: str, source: str, confidence: float
    ) -> None:
        self._execute(
            "update transactions set category_id = %s, category_source = %s, "
            "category_confidence = %s, status = 'CATEGORIZED' where id = %s",
            (category_id, source, confidence, txn_id),
        )

    def mark_needs_review(self, txn_id: str) -> None:
        self._execute("update transactions set status = 'NEEDS_REVIEW' where id = %s", (txn_id,))

    def create_merchant_rule(
        self, user_id: str, pattern: str, category_id: str, learned_from_user: bool
    ) -> str:
        return str(
            self._execute(
                "insert into merchant_rules (user_id, pattern, category_id, learned_from_user) "
                "values (%s, %s, %s, %s) returning id",
                (user_id, pattern, category_id, learned_from_user),
                fetch="one",
                retry=False,
            )[0]
        )

    def fetch_transactions_in_range(
        self, user_id: str, account_id: str, start: datetime, end: datetime
    ) -> list[NormalizedTxn]:
        # Return NormalizedTxn so it can be compared.
        rows = self._execute(
            """
            select
                template_key, parser_version,
                'NABIL' as institution, null as account_mask,
                occurred_at, occurred_precision, direction,
                amount_paisa, balance_after_paisa, currency,
                reference, description_raw, counterparty, channel,
                source_message_id as message_id, dedupe_key
            from transactions
            where user_id = %(user_id)s
              and account_id = %(account_id)s
              and occurred_at >= %(start)s
              and occurred_at <= %(end)s
            order by occurred_at asc
            """,
            {
                "user_id": user_id,
                "account_id": account_id,
                "start": start,
                "end": end,
            },
        ).fetchall()

        return [
            NormalizedTxn(
                template_key=r[0],
                parser_version=r[1],
                institution=r[2],
                account_mask=r[3],
                occurred_at=r[4],
                occurred_precision=r[5],
                direction=r[6],
                amount_paisa=r[7],
                balance_after_paisa=r[8],
                currency=r[9],
                reference=r[10],
                description_raw=r[11],
                counterparty=r[12],
                channel=r[13],
                message_id=r[14] or "none",
                dedupe_key=r[15],
            )
            for r in rows
        ]


def _classify(exc: psycopg.OperationalError, phase: str) -> Exception:
    """psycopg raises OperationalError both for "I could not reach a server"
    and for "the server answered and refused". Only the first is a transient
    outage worth skipping the run over; the second (bad password, missing
    database) is a config problem the user must see. libpq attaches a
    SQLSTATE only when the server actually answered, so that is the split.
    """
    if exc.sqlstate is not None:
        return exc
    return StoreUnavailable(f"database unreachable during {phase}: {exc}")

