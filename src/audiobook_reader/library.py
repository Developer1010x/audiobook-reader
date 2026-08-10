"""Scan the configured book library and list what's in it.

This is the one fully-working piece of v0. It reads *metadata only* — filename, size,
extension — and never opens, copies, or moves book content. Everything downstream
(reader, TTS, summary) takes a Book from here and operates on it in place.
"""

from __future__ import annotations

import tomllib
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Book:
    path: Path          # absolute path in your library — never copied, never committed
    title: str          # derived from the filename for now
    ext: str            # "pdf", "epub", ...
    size_bytes: int


def load_config(config_path: Path | None = None) -> dict:
    """Read config.toml (git-ignored). Falls back to config.example.toml for a first run."""
    root = Path(__file__).resolve().parent.parent.parent
    path = config_path or (root / "config.toml")
    if not path.exists():
        path = root / "config.example.toml"
    with open(path, "rb") as f:
        return tomllib.load(f)


def scan_library(config: dict | None = None) -> list[Book]:
    """Return every book under the configured library path, sorted by title.

    Raises FileNotFoundError with a clear message if the path isn't set/real, because a
    silent empty list would look like "no books" rather than "you didn't set the path".
    """
    cfg = config or load_config()
    lib = cfg["library"]
    base = Path(lib["path"]).expanduser()
    if not base.is_dir():
        raise FileNotFoundError(
            f"Library path not found: {base}\n"
            f"Copy config.example.toml to config.toml and set [library].path."
        )
    wanted = {e.lower().lstrip(".") for e in lib.get("extensions", ["pdf", "epub"])}
    books: list[Book] = []
    for p in base.rglob("*"):
        if p.is_file() and p.suffix.lower().lstrip(".") in wanted and not p.name.startswith("._"):
            books.append(
                Book(path=p, title=p.stem, ext=p.suffix.lower().lstrip("."), size_bytes=p.stat().st_size)
            )
    return sorted(books, key=lambda b: b.title.lower())
