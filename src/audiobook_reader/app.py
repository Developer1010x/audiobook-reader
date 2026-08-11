"""Entry point. CLI for v0 (a GUI comes later).

Working today: `list` (library scan) and `read` (page text + rendered page image, PDF only).
`summarise` works via a local Ollama model, or Google Gemini if explicitly opted into.
Stubbed: `speak`.
"""

from __future__ import annotations

import re
import sys

from . import reader, summarize  # tts joins this once it's implemented
from .library import load_config, scan_library


def cmd_list() -> None:
    books = scan_library()
    print(f"{len(books)} books found:\n")
    for b in books[:50]:
        print(f"  [{b.ext}] {b.title}  ({b.size_bytes // 1024} KB)")
    if len(books) > 50:
        print(f"  ... and {len(books) - 50} more")


def _norm(s: str) -> str:
    """Lowercase and flatten separators, so 'thousand brains' matches 'A_thousand_brains-...'."""
    return re.sub(r"[\s_\-]+", " ", s.lower()).strip()


def _find_one(term: str):
    """The single book matching `term`, or None after printing why not.

    Titles come from filenames, which mix spaces, underscores and hyphens freely
    ("A_thousand_brains-theory_of_intelligence"), so both sides are normalised —
    otherwise searching for what you see on screen fails.
    """
    matches = [b for b in scan_library() if _norm(term) in _norm(b.title)]
    if not matches:
        print(f"No book matching '{term}'. Try: audiobook-reader list")
        return None
    if len(matches) > 1:
        print(f"{len(matches)} books match '{term}' — be more specific:")
        for b in matches[:10]:
            print(f"  {b.title}")
        return None
    return matches[0]


def cmd_read(args: list[str]) -> int:
    """read <search-term> [page] — show a page's text and render it to the cache."""
    if not args:
        print("usage: audiobook-reader read <search-term> [page]")
        return 2
    page_no = int(args[1]) if len(args) > 1 else 1

    book = _find_one(args[0])
    if book is None:
        return 1
    total = reader.page_count(book)
    try:
        page = reader.get_page(book, page_no)
    except ValueError as e:
        print(e)  # a bad page number is user error, not a crash
        return 1
    print(f"{book.title} — page {page.number}/{total}\n")
    print(page.text.strip() or "(no extractable text — likely a scanned page)")
    if page.image_paths:
        print(f"\n[page image] {page.image_paths[0]}")
    return 0


def cmd_summarise(args: list[str]) -> int:
    """summarise <search-term> [page] [--provider ollama|gemini] [--pages A-B]"""
    def take(flag: str) -> str | None:
        if flag not in args:
            return None
        i = args.index(flag)
        value = args[i + 1]
        del args[i : i + 2]
        return value

    provider, model, page_range = take("--provider"), take("--model"), take("--pages")
    if not args:
        print("usage: audiobook-reader summarise <search-term> [page] "
              "[--pages A-B] [--provider ollama|gemini] [--model NAME]")
        return 2

    book = _find_one(args[0])
    if book is None:
        return 1

    cfg = load_config().get("summary", {})
    cfg_provider = cfg.get("provider", "ollama")
    provider = provider or cfg_provider
    # The configured model belongs to the configured provider. If --provider switched
    # away from it, that model name is meaningless (an Ollama tag is not a Gemini model),
    # so fall through to the new provider's own default instead.
    if model is None and provider.lower() == cfg_provider.lower():
        model = cfg.get("model")
    model = model or summarize.default_model(provider)

    if page_range:
        start, _, end = page_range.partition("-")
        start, end = int(start), int(end or start)
    else:
        start = end = int(args[1]) if len(args) > 1 else 1

    try:
        text = reader.extract_text(book, start, end)
    except ValueError as e:
        print(e)
        return 1
    if not text.strip():
        print("No extractable text on those pages — likely scanned images (OCR not built yet).")
        return 1

    # Sending book text to a third party is a decision, so it is always stated out loud.
    where = "LEAVING THIS MACHINE → Google" if summarize.is_cloud(provider) else "local"
    print(f"[{provider}:{model}] {book.title} pp.{start}-{end} "
          f"({len(text)} chars, {where})\n")
    try:
        print(summarize.summarise(text, provider=provider, model=model))
    except (RuntimeError, ValueError) as e:
        print(e)
        return 1
    return 0


def main(argv: list[str] | None = None) -> int:
    args = argv if argv is not None else sys.argv[1:]
    cmd = args[0] if args else "list"
    if cmd == "list":
        cmd_list()
    elif cmd == "read":
        return cmd_read(args[1:])
    elif cmd in {"summarise", "summarize"}:
        return cmd_summarise(args[1:])
    elif cmd == "speak":
        # These call into the stub layers; each raises NotImplementedError for now.
        print(f"'{cmd}' is not implemented yet — see reader.py / tts.py / summarize.py.")
        return 1
    else:
        print(f"Unknown command: {cmd}. Try: list")
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
