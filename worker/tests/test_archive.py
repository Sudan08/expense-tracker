from datetime import datetime, timezone

from expense_tracker.ingest import archive


def test_write_then_exists(tmp_path):
    received_at = datetime(2026, 8, 31, 9, 45, 53, tzinfo=timezone.utc)
    message_id = "<abc@example.com>"

    assert not archive.exists(tmp_path, message_id, received_at)
    archive.write(tmp_path, message_id, received_at, b"raw content")
    assert archive.exists(tmp_path, message_id, received_at)
    assert archive.read(tmp_path, message_id, received_at) == b"raw content"


def test_path_is_sha256_of_message_id_under_year_month(tmp_path):
    received_at = datetime(2026, 8, 31, tzinfo=timezone.utc)
    path = archive.archive_path(tmp_path, "<abc@example.com>", received_at)
    assert path.parent == tmp_path / "2026" / "08"
    assert path.suffix == ".eml"
    assert len(path.stem) == 64  # sha256 hex digest


def test_iter_archived_finds_written_files(tmp_path):
    received_at = datetime(2026, 8, 31, tzinfo=timezone.utc)
    archive.write(tmp_path, "<a@x.com>", received_at, b"a")
    archive.write(tmp_path, "<b@x.com>", received_at, b"b")
    assert len(list(archive.iter_archived(tmp_path))) == 2
