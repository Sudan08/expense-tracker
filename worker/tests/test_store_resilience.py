"""A sync run holds one Postgres connection across a slow IMAP fetch and a
slower Ollama pass, so that connection is routinely idle for minutes --
long enough for Supabase's pooler to drop it, or for a laptop wake to
invalidate the socket. Every statement must survive that by reconnecting.

The other half of this is knowing when *not* to reconnect: psycopg raises
OperationalError both for "I never reached a server" and for "the server
answered and refused". Only the first is a transient outage. Offline: these
use a fake connection, no Postgres required.
"""

from __future__ import annotations

import psycopg
import pytest

from expense_tracker.store import supabase
from expense_tracker.store.base import StoreUnavailable
from expense_tracker.store.supabase import PostgresStore

DEAD_SOCKET = "consuming input failed: could not receive data from server: Can't assign requested address"


class _FakeCursor:
    def __init__(self, conn: "_FakeConn") -> None:
        self._conn = conn

    def __enter__(self) -> "_FakeCursor":
        return self

    def __exit__(self, *exc_info) -> bool:
        return False

    def execute(self, sql: str, params) -> None:
        self._conn.executed.append(sql)
        if self._conn.raises is not None:
            raise self._conn.raises

    def fetchone(self):
        return (7,)

    def fetchall(self):
        return []


class _FakeConn:
    def __init__(self, raises: Exception | None = None) -> None:
        self.raises = raises
        self.executed: list[str] = []
        self.closed = False

    def cursor(self) -> _FakeCursor:
        return _FakeCursor(self)

    def close(self) -> None:
        self.closed = True


@pytest.fixture
def connect_returning(monkeypatch):
    """Hand PostgresStore a scripted sequence of connections."""

    def _install(*conns):
        queue = list(conns)
        opened: list[_FakeConn] = []

        def _connect(*args, **kwargs):
            conn = queue.pop(0) if queue else _FakeConn()
            opened.append(conn)
            return conn

        monkeypatch.setattr(supabase.psycopg, "connect", _connect)
        return opened

    return _install


def test_dead_connection_reconnects_and_retries(connect_returning):
    dead = _FakeConn(raises=psycopg.OperationalError(DEAD_SOCKET))
    live = _FakeConn()
    opened = connect_returning(dead, live)

    store = PostgresStore("postgresql://example")
    count = store.count_failed_emails("user-1")

    assert count == 7, "the retry's result is returned, not swallowed"
    assert dead.closed, "the dead connection must be closed, not leaked"
    assert len(opened) == 2, "exactly one reconnect"
    assert len(dead.executed) == 1 and len(live.executed) == 1


def test_reconnect_is_attempted_only_once(connect_returning):
    """If the network is genuinely gone, retrying forever would hold the
    sync lock indefinitely. Give up after one reconnect and let the caller's
    own retry loop decide."""
    first = _FakeConn(raises=psycopg.OperationalError(DEAD_SOCKET))
    second = _FakeConn(raises=psycopg.OperationalError(DEAD_SOCKET))
    opened = connect_returning(first, second)

    store = PostgresStore("postgresql://example")
    with pytest.raises(StoreUnavailable, match="database unreachable during query"):
        store.count_failed_emails("user-1")

    assert len(opened) == 2


def test_server_side_error_is_never_retried(connect_returning):
    """A SQLSTATE means the server answered. Reconnecting changes nothing,
    and retrying would just run a rejected statement twice."""
    refused = psycopg.errors.lookup("42P01")("relation \"transactions\" does not exist")
    conn = _FakeConn(raises=refused)
    opened = connect_returning(conn)

    store = PostgresStore("postgresql://example")
    with pytest.raises(psycopg.errors.UndefinedTable):
        store.count_failed_emails("user-1")

    assert len(opened) == 1, "no reconnect for a server-side refusal"
    assert len(conn.executed) == 1, "statement run once, not twice"


def test_non_idempotent_insert_is_not_retried(connect_returning):
    """create_merchant_rule is a plain INSERT with no ON CONFLICT clause. If
    it did commit before the socket broke, re-running it would leave two
    rules where the user asked for one."""
    dead = _FakeConn(raises=psycopg.OperationalError(DEAD_SOCKET))
    live = _FakeConn()
    connect_returning(dead, live)

    store = PostgresStore("postgresql://example")
    with pytest.raises(StoreUnavailable):
        store.create_merchant_rule("user-1", "PATTERN", "cat-1", learned_from_user=True)

    assert len(dead.executed) == 1
    assert live.executed == [], "must not re-run the insert on a fresh connection"


def test_unreachable_database_at_connect_raises_store_unavailable(monkeypatch):
    def _boom(*args, **kwargs):
        raise psycopg.OperationalError(
            "failed to resolve host 'aws-0-ap-southeast-1.pooler.supabase.com'"
        )

    monkeypatch.setattr(supabase.psycopg, "connect", _boom)

    with pytest.raises(StoreUnavailable, match="database unreachable during connect"):
        PostgresStore("postgresql://example")


def test_bad_credentials_are_not_a_transient_outage(monkeypatch):
    """A wrong service_role password must fail loudly and immediately --
    treating it as a transient outage would make sync exit 0 every day and
    silently never sync anything."""

    def _boom(*args, **kwargs):
        raise psycopg.errors.lookup("28P01")("password authentication failed")

    monkeypatch.setattr(supabase.psycopg, "connect", _boom)

    with pytest.raises(psycopg.errors.InvalidPassword):
        PostgresStore("postgresql://example")
