"""Reader tests. A real PDF is built on the fly with PyMuPDF, so these never touch — and
never need — the personal library. Nothing here reads a real book."""
from pathlib import Path

import pymupdf
import pytest

from audiobook_reader.library import Book
from audiobook_reader.reader import extract_text, get_page, open_book, page_count


def make_pdf(tmp_path: Path, pages: list[str]) -> Book:
    doc = pymupdf.open()
    for body in pages:
        page = doc.new_page()
        page.insert_text((72, 72), body)
    path = tmp_path / "sample.pdf"
    doc.save(path)
    doc.close()
    return Book(path=path, title="sample", ext="pdf", size_bytes=path.stat().st_size)


def test_page_count_and_text(tmp_path: Path):
    book = make_pdf(tmp_path, ["first page", "second page"])
    assert page_count(book) == 2
    assert "first page" in get_page(book, 1, render=False).text
    assert "second page" in get_page(book, 2, render=False).text


def test_pages_are_one_based(tmp_path: Path):
    book = make_pdf(tmp_path, ["alpha", "beta"])
    assert "alpha" in get_page(book, 1, render=False).text  # not page 0


def test_render_writes_a_png(tmp_path: Path):
    book = make_pdf(tmp_path, ["drawn"])
    page = get_page(book, 1, render=True, dpi=36)
    assert len(page.image_paths) == 1
    out = Path(page.image_paths[0])
    assert out.exists() and out.read_bytes().startswith(b"\x89PNG")


def test_render_filename_is_stable_across_calls(tmp_path: Path):
    """Guards the hashlib-vs-hash() fix: a salted hash would rename the file every run."""
    book = make_pdf(tmp_path, ["x"])
    a = get_page(book, 1, dpi=36).image_paths[0]
    b = get_page(book, 1, dpi=36).image_paths[0]
    assert a == b


def test_out_of_range_page_raises_valueerror(tmp_path: Path):
    book = make_pdf(tmp_path, ["only one"])
    for bad in (0, 2, 99):
        with pytest.raises(ValueError, match="out of range"):
            get_page(book, bad, render=False)


def test_extract_text_spans_a_range(tmp_path: Path):
    book = make_pdf(tmp_path, ["one", "two", "three"])
    text = extract_text(book, 1, 2)
    assert "one" in text and "two" in text and "three" not in text
    assert "three" in extract_text(book)  # defaults to the whole book


def test_non_pdf_raises_notimplemented(tmp_path: Path):
    epub = Book(path=tmp_path / "x.epub", title="x", ext="epub", size_bytes=0)
    with pytest.raises(NotImplementedError, match="only PDF"):
        open_book(epub)
