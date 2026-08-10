"""Reader layer — open a book and extract page text + images (for the diagrams you want visible).

STUB. Interface is fixed so app.py and the future GUI can be written against it now.
Implement with PyMuPDF (fitz) for PDF and ebooklib for EPUB. Reads in place — never copies.
"""

from __future__ import annotations

from dataclasses import dataclass

from .library import Book


@dataclass
class Page:
    number: int
    text: str
    image_paths: list[str]  # rendered page-image / figure paths in a git-ignored cache


def open_book(book: Book):  # -> a page iterator / handle
    raise NotImplementedError("reader.open_book: implement with PyMuPDF (PDF) / ebooklib (EPUB).")


def get_page(book: Book, number: int) -> Page:
    raise NotImplementedError("reader.get_page: return page text + rendered images for `number`.")
