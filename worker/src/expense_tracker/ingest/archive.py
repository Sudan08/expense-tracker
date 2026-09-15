"""raw/ read+write. Filename = sha256(Message-ID) -- the filename is the
index; an existence check is one stat. See docs/EXPENSE_TRACKER_PLAN.md
section 3.
"""

from __future__ import annotations

import hashlib
from datetime import datetime
from pathlib import Path


def archive_path(archive_dir: Path, message_id: str, received_at: datetime) -> Path:
    digest = hashlib.sha256(message_id.encode()).hexdigest()
    year_month = received_at.strftime("%Y/%m")
    return archive_dir / year_month / f"{digest}.eml"


def exists(archive_dir: Path, message_id: str, received_at: datetime) -> bool:
    return archive_path(archive_dir, message_id, received_at).exists()


def write(archive_dir: Path, message_id: str, received_at: datetime, raw_bytes: bytes) -> Path:
    path = archive_path(archive_dir, message_id, received_at)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(raw_bytes)
    return path


def read(archive_dir: Path, message_id: str, received_at: datetime) -> bytes:
    return archive_path(archive_dir, message_id, received_at).read_bytes()


def iter_archived(archive_dir: Path):
    """All locally archived .eml paths -- what `reparse` runs against offline."""
    yield from sorted(archive_dir.glob("*/*/*.eml"))
