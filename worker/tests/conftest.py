"""When EXPENSE_TRACKER_TEST_DB_URL points at an empty Postgres, apply the
real migration (supabase/migrations/*.sql) plus the minimal stand-ins for
what real Supabase provides out of the box (the auth schema, the
`authenticated` role, `auth.uid()`) so test_sync_integration.py can run
against it without any manual setup step.
"""

from __future__ import annotations

import os
from pathlib import Path

import psycopg
import pytest

DB_URL = os.environ.get("EXPENSE_TRACKER_TEST_DB_URL")
MIGRATIONS_DIR = Path(__file__).parent.parent.parent / "supabase" / "migrations"


@pytest.fixture(scope="session", autouse=True)
def _apply_migrations_once():
    if not DB_URL:
        yield
        return

    with psycopg.connect(DB_URL, autocommit=True) as conn:
        with conn.cursor() as cur:
            cur.execute(
                "select exists (select from information_schema.tables "
                "where table_schema = 'public' and table_name = 'transactions')"
            )
            already_applied = cur.fetchone()[0]
        if not already_applied:
            with conn.cursor() as cur:
                # Best-effort, not required. This was here for
                # gen_random_uuid(), which has been core since Postgres 13 --
                # and nothing in supabase/migrations/ calls a pgcrypto
                # function any more (the Nabil key rewrite deliberately uses
                # core sha256() rather than pgcrypto's digest(), so that it
                # works on a Supabase project where pgcrypto lives in a
                # separate `extensions` schema). Minimal Postgres builds ship
                # without the extension, and refusing to run the suite
                # against one for a line we don't need is pure friction.
                try:
                    cur.execute("create extension if not exists pgcrypto")
                except psycopg.errors.FeatureNotSupported:
                    conn.rollback()
                cur.execute("create schema if not exists auth")
                cur.execute(
                    "create table if not exists auth.users "
                    "(id uuid primary key default gen_random_uuid())"
                )
                cur.execute(
                    "create or replace function auth.uid() returns uuid "
                    "language sql stable as $$ select null::uuid $$"
                )
                cur.execute(
                    "do $$ begin "
                    "if not exists (select from pg_roles where rolname = 'authenticated') then "
                    "create role authenticated; end if; end $$"
                )
            for migration in sorted(MIGRATIONS_DIR.glob("*.sql")):
                with conn.cursor() as cur:
                    cur.execute(migration.read_text())
    yield
