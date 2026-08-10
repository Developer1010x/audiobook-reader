"""Library scan is the one working piece of v0 — test it against a tiny fake library."""
from pathlib import Path

from audiobook_reader.library import scan_library


def test_scan_lists_only_wanted_extensions(tmp_path: Path):
    (tmp_path / "a.pdf").write_bytes(b"%PDF-1.4 fake")
    (tmp_path / "b.epub").write_bytes(b"fake-epub")
    (tmp_path / "notes.txt").write_text("not a book we scan")
    (tmp_path / "._a.pdf").write_bytes(b"mac junk")  # must be skipped

    cfg = {"library": {"path": str(tmp_path), "extensions": ["pdf", "epub"]}}
    books = scan_library(cfg)

    titles = sorted(b.title for b in books)
    assert titles == ["a", "b"]
    assert all(b.ext in {"pdf", "epub"} for b in books)


def test_missing_path_raises_clearly(tmp_path: Path):
    cfg = {"library": {"path": str(tmp_path / "does-not-exist"), "extensions": ["pdf"]}}
    try:
        scan_library(cfg)
        assert False, "should have raised"
    except FileNotFoundError as e:
        assert "Library path not found" in str(e)
