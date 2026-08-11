"""Reader layer — open a book and extract page text + images (for the diagrams you want visible).

PDF is implemented with PyMuPDF. EPUB raises a clear error until it's needed — the library
currently holds no EPUBs, and a half-working EPUB path is worse than an honest failure.

Reads in place: a book is opened read-only and never copied. The only thing written anywhere
is a rendered page PNG under the git-ignored cache/ directory, so diagrams can be displayed.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass
from pathlib import Path

import pymupdf

from .library import Book

# Rendered page images land here. cache/ is git-ignored (see .gitignore) so no book
# content — not even a rasterised page — can be committed.
CACHE_DIR = Path(__file__).resolve().parent.parent.parent / "cache"


@dataclass
class Page:
    number: int
    text: str
    image_paths: list[str]  # rendered page-image / figure paths in a git-ignored cache


def open_book(book: Book) -> pymupdf.Document:
    """Open `book` read-only and return the document handle.

    Caller is responsible for closing it, or use it as a context manager:
    `with open_book(b) as doc: ...`
    """
    if book.ext != "pdf":
        raise NotImplementedError(
            f"reader.open_book: only PDF is implemented; got '{book.ext}'. "
            f"EPUB support goes here (ebooklib) when the library has EPUBs."
        )
    return pymupdf.open(book.path)


def page_count(book: Book) -> int:
    """Number of pages in `book`."""
    with open_book(book) as doc:
        return doc.page_count


def get_page(book: Book, number: int, *, render: bool = True, dpi: int = 150) -> Page:
    """Return page `number` (1-based) as text plus, if `render`, a PNG of the full page.

    The page is rendered whole rather than extracting embedded images individually, because
    diagrams are usually vector drawings with no embedded bitmap to extract — rasterising the
    page is what actually makes them visible.
    """
    with open_book(book) as doc:
        if not 1 <= number <= doc.page_count:
            raise ValueError(
                f"Page {number} out of range for '{book.title}' (1..{doc.page_count})."
            )
        page = doc[number - 1]
        text = page.get_text()

        image_paths: list[str] = []
        if render:
            CACHE_DIR.mkdir(exist_ok=True)
            # Key the filename by page path + number so two books with the same title
            # (your library has several) can't overwrite each other's renders.
            # hashlib, not hash(): str hashing is salted per process, so hash() would
            # produce a different filename every run and the cache would never hit.
            digest = hashlib.sha256(str(book.path).encode()).hexdigest()[:12]
            stem = f"{digest}_p{number}"
            out = CACHE_DIR / f"{stem}.png"
            page.get_pixmap(dpi=dpi).save(out)
            image_paths.append(str(out))

        return Page(number=number, text=text, image_paths=image_paths)


def extract_text(book: Book, start: int = 1, end: int | None = None) -> str:
    """Concatenated text of pages `start`..`end` (1-based, inclusive) — the input TTS and
    the summariser consume. No rendering, so this stays fast over a whole chapter."""
    with open_book(book) as doc:
        last = doc.page_count if end is None else min(end, doc.page_count)
        if not 1 <= start <= last:
            raise ValueError(f"Bad page range {start}..{end} for '{book.title}'.")
        return "\n\n".join(doc[i - 1].get_text() for i in range(start, last + 1))
