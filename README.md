# audiobook-reader

A **private, local** audiobook + reader over a personal book library. Pick any book, see the page
(diagrams and all), read it aloud, or have it summarised — without any book leaving this machine.

Status: **v0 scaffold.** The library scanner works; the reader, TTS and AI-summary layers are stubs
with defined interfaces, built up incrementally.

## Privacy — the rule this project is built around

This repo is **private and contains code only. It never contains a single book, or even the path to
your library.**

- Your library lives at a path set in your local `config.toml` (git-ignored). Only
  `config.example.toml` — with a placeholder path — is committed.
- The app **reads** books at runtime; it never copies, exports, or commits their content.
- `.gitignore` hard-blocks every book/audio format and every data directory, so an accidental
  `git add .` cannot leak anything. **Do not weaken those rules.**
- The AI summariser runs on a **local model (Ollama)** by default — book text is never sent to an
  external API.

## The three layers (v1 goal — "all 3")

1. **Reader** — render a book's pages (PDF/EPUB), diagrams visible, annotate / work over it.
2. **Read-aloud (TTS)** — turn the current page/chapter into speech.
3. **AI summary** — summarise a page/chapter with a local LLM, then read the summary or full text.

## Layout

```
src/audiobook_reader/
  library.py     # scan the configured library path, list books (metadata only, never copies)
  reader.py      # open a book, extract page text/images   [stub]
  tts.py         # text -> speech                            [stub, interface defined]
  summarize.py   # page/chapter -> summary via local Ollama  [stub, interface defined]
  app.py         # entry point (CLI now; GUI later)
config.example.toml   # copy to config.toml and set your library path
tests/                # unit tests (start with library scanning)
```

## Run

```bash
cp config.example.toml config.toml   # then edit the library path
python -m audiobook_reader.app list  # lists books found in your library
```
