"""~/.expense-tracker/config.toml + .env. See docs/EXPENSE_TRACKER_PLAN.md section 3."""

from __future__ import annotations

import os
import socket
import tomllib
from dataclasses import dataclass
from datetime import date, datetime, timezone
from pathlib import Path

from dotenv import load_dotenv

DEFAULT_HOME = Path.home() / ".expense-tracker"


@dataclass(frozen=True)
class Config:
    archive_dir: Path
    machine: str
    imap_host: str
    imap_username: str
    imap_password: str
    db_url: str
    esewa_sender: str
    nabil_sender: str
    account_start: datetime
    user_id: str


def load_config(home: Path | None = None) -> Config:
    home = home or DEFAULT_HOME
    load_dotenv(home / ".env")

    config_path = home / "config.toml"
    if not config_path.exists():
        raise FileNotFoundError(
            f"{config_path} not found. See docs/EXPENSE_TRACKER_PLAN.md section 3 "
            "for the expected layout."
        )
    with config_path.open("rb") as f:
        raw = tomllib.load(f)

    worker = raw.get("worker", {})
    imap = raw["imap"]
    senders = raw.get("senders", {})

    imap_password = os.environ.get("EXPENSE_TRACKER_IMAP_PASSWORD")
    if not imap_password:
        raise RuntimeError(f"EXPENSE_TRACKER_IMAP_PASSWORD not set in {home / '.env'}")

    db_url = os.environ.get("EXPENSE_TRACKER_DB_URL")
    if not db_url:
        raise RuntimeError(f"EXPENSE_TRACKER_DB_URL not set in {home / '.env'}")

    user_id = os.environ.get("EXPENSE_TRACKER_USER_ID")
    if not user_id:
        raise RuntimeError(
            f"EXPENSE_TRACKER_USER_ID not set in {home / '.env'} -- your Supabase "
            "auth.users.id (a UUID), created once when you sign up in the app"
        )

    account_start_raw = worker.get("account_start")
    if not account_start_raw:
        raise RuntimeError(
            f"worker.account_start not set in {config_path} -- the earliest date "
            "to backfill from on a first sync, e.g. account_start = 2025-01-01"
        )
    account_start = datetime.combine(
        account_start_raw if isinstance(account_start_raw, date) else date.fromisoformat(account_start_raw),
        datetime.min.time(),
        tzinfo=timezone.utc,
    )

    return Config(
        archive_dir=Path(worker.get("archive_dir", home / "raw")).expanduser(),
        machine=worker.get("machine", socket.gethostname()),
        imap_host=imap.get("host", "imap.gmail.com"),
        imap_username=imap["username"],
        imap_password=imap_password,
        db_url=db_url,
        esewa_sender=senders.get("esewa", "esewa.com.np"),
        nabil_sender=senders.get("nabil", "nabilbank.com"),
        account_start=account_start,
        user_id=user_id,
    )
