"""Entry point. CLI for v0 (a GUI comes later).

Working today: `list` — prove the library scan works end to end.
Stubbed: `read`, `speak`, `summarise` — defined interfaces, not yet implemented.
"""

from __future__ import annotations

import sys

from . import reader, summarize, tts
from .library import scan_library


def cmd_list() -> None:
    books = scan_library()
    print(f"{len(books)} books found:\n")
    for b in books[:50]:
        print(f"  [{b.ext}] {b.title}  ({b.size_bytes // 1024} KB)")
    if len(books) > 50:
        print(f"  ... and {len(books) - 50} more")


def main(argv: list[str] | None = None) -> int:
    args = argv if argv is not None else sys.argv[1:]
    cmd = args[0] if args else "list"
    if cmd == "list":
        cmd_list()
    elif cmd in {"read", "speak", "summarise", "summarize"}:
        # These call into the stub layers; each raises NotImplementedError for now.
        print(f"'{cmd}' is not implemented yet — see reader.py / tts.py / summarize.py.")
        return 1
    else:
        print(f"Unknown command: {cmd}. Try: list")
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
