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
- The AI summariser runs on a **local model (Ollama) by default**, so book text stays on this
  machine.

### The one exception: Gemini (opt-in)

A **Google Gemini** provider is available. It is genuinely different in kind, so it is spelled out:

> Selecting `gemini` **sends the page or chapter text to Google's API**, where it is subject to
> Google's retention and training policy. This is the one path where book content leaves the
> machine.

The guardrails around it:

- **Never implicit.** Gemini runs only when named in `config.toml` or passed as
  `--provider gemini`, *and* a key is present. The default stays local.
- **No silent fallback.** If Ollama is down, the summariser fails loudly. It will never quietly
  reroute your library to a third party.
- **The CLI says so at runtime** — every cloud run prints `LEAVING THIS MACHINE → Google` with the
  character count before it sends.
- **The key is never committed.** It is read from `GEMINI_API_KEY` / `GOOGLE_API_KEY` in the
  environment, or from `.env`, which is git-ignored. It is never written to `config.toml`.

```bash
export GEMINI_API_KEY=...        # from https://aistudio.google.com/apikey
audiobook-reader summarise "a tour of c++" --pages 20-25 --provider gemini
```

## The three layers (v1 goal — "all 3")

1. **Reader** — render a book's pages (PDF/EPUB), diagrams visible, annotate / work over it.
2. **Read-aloud (TTS)** — turn the current page/chapter into speech.
3. **AI summary** — summarise a page/chapter with a local LLM, then read the summary or full text.

## Layout

```
src/audiobook_reader/
  library.py     # scan the configured library path, list books (metadata only, never copies)
  reader.py      # open a book, extract page text + rendered page images (PDF via PyMuPDF)
  tts.py         # text -> speech                            [stub, interface defined]
  summarize.py   # page/chapter -> summary: local Ollama, or Gemini if opted in
  app.py         # entry point (CLI now; GUI later)
config.example.toml   # copy to config.toml and set your library path
tests/                # unit tests (start with library scanning)
```

## Run

```bash
cp config.example.toml config.toml   # then edit the library path
python -m audiobook_reader.app list  # lists books found in your library
```
