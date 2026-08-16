# audiobook-reader

A private, local-first reader over a personal book library. Open any PDF, EPUB,
Markdown or text file; read it on screen, have it read aloud in a neural voice,
OCR the scanned pages, and — only for textbooks, only when you ask — get an AI
summary from a local or cloud model.

**Nothing about your library leaves the machine unless you explicitly choose a
cloud provider.** Books are read in place and never copied.

---

## Contents

- [Quick start](#quick-start)
- [Features](#features)
- [Architecture](#architecture)
- [The privacy boundary](#the-privacy-boundary)
- [Data flows](#data-flows)
- [The AI layer](#the-ai-layer)
- [External dependencies](#external-dependencies)
- [Building](#building)
- [Testing](#testing)
- [Configuration and storage](#configuration-and-storage)
- [Known limitations](#known-limitations)

---

## Quick start

```bash
cd app
flutter pub get
flutter run -d linux
```

On first launch, choose your library folder. The app scans it recursively for
`.pdf`, `.epub`, `.txt` and `.md` files and never writes to it.

### Optional engines

Everything below is optional — the app degrades gracefully and tells you what to
install when a feature needs something that isn't there.

```bash
# Neural voice (strongly recommended — the system voice is robotic)
uv venv ~/.local/share/piper-venv
VIRTUAL_ENV=~/.local/share/piper-venv uv pip install piper-tts
mkdir -p ~/.local/share/piper-voices && cd ~/.local/share/piper-voices
~/.local/share/piper-venv/bin/python -m piper.download_voices en_US-lessac-medium

# OCR for scanned pages
sudo apt install tesseract-ocr

# Local LLM (keeps book text on-device)
curl -fsSL https://ollama.com/install.sh | sh
ollama pull qwen2.5:1.5b

# Fallback voice if you skip Piper
sudo apt install speech-dispatcher speech-dispatcher-espeak-ng
```

---

## Features

### Library

- Recursive scan of a folder you choose; folder tree with breadcrumbs
- Cover art rendered from each book's first page and cached; generated
  typographic covers for text formats
- Search across the whole library regardless of current folder, tolerant of
  `_`, `-` and space differences in filenames
- **Continue reading** shelf with real progress, favourites, sort by title /
  recency / size, grid and list views
- Reading stats: pages per day, streak, 14-day sparkline

### Reader (PDF)

Document outline, in-document text search with match navigation, zoom, page
jump, night mode, resume-where-you-left-off, bookmarks with notes.

### Reader (EPUB / Markdown / text)

Flowed text with adjustable size, EPUB chapter navigation, synthetic pagination
so page numbers, resume and page ranges work identically to PDF.

### Read-aloud

- Neural voice via Piper, with voice selection; espeak-ng fallback
- **Chunked, pipelined playback** — chunk *n* plays while chunk *n+1*
  synthesises, so audio starts in ~1 s instead of ~10 s for a full page
- **Follow-along highlighting** at sentence granularity
- **Tap any sentence to start reading from there**
- Auto-advance to the next page

### OCR

Scanned pages are detected automatically (no embedded text) and recognised with
Tesseract at ~300 dpi. Results are cached, so a page is never OCRed twice.

### AI assist

Five modes — Summary, Learning, Interview, Flashcards, Key terms — across four
output lengths, over six providers. See [The AI layer](#the-ai-layer).

---

## Architecture

Four layers with dependencies running strictly downward. A service never imports
a screen, which is why every service is testable without a widget tree.

```
┌─ 1 · UI ──────────────────────────────────────────────────────────┐
│  library_screen   reader_screen   text_reader_screen              │
│  summary_sheet    bookmarks_sheet settings_screen   widgets/      │
└───────────────────────────┬───────────────────────────────────────┘
                            │  Book · Bookmark · BookType
┌─ 2 · Models ──────────────▼───────────────────────────────────────┐
│  book        library_node        bookmark                         │
└───────────────────────────┬───────────────────────────────────────┘
                            │
┌─ 3 · Services ────────────▼───────────────────────────────────────┐
│  library_service   reader_service   text_document   spoken_text   │
│  classifier ← the gate on the entire AI path                      │
│  tts_service → piper_tts      ocr_service      cover_service      │
│  settings_service  stats_service                                  │
│  llm/ llm_provider · ai_mode · summary_length · summariser        │
└───────────────────────────┬───────────────────────────────────────┘
                            │
┌─ 4 · Outside ─────────────▼───────────────────────────────────────┐
│  pdfrx (in-process)                                               │
│  piper · tesseract · ollama          (local subprocesses)         │
│  gemini · groq · openrouter · together · huggingface  (HTTPS)     │
└───────────────────────────────────────────────────────────────────┘
```

### Module reference

| Module | Responsibility |
|---|---|
| `models/book.dart` | Path, title, extension, size. **Metadata only — never content.** |
| `models/library_node.dart` | Folder tree built from a flat scan; drops folders with no books at any depth |
| `models/bookmark.dart` | Page, preview, note, timestamp; JSON codec |
| `services/library_service.dart` | Recursive scan, extension filter, macOS `._` stub filter, separator-tolerant search |
| `services/reader_service.dart` | PDF text for a page or range, OCR fallback, classification sampling |
| `services/text_document.dart` | EPUB (zip → `container.xml` → OPF spine → XHTML) and txt/md pagination |
| `services/spoken_text.dart` | Splits a page into sentences and maps each to its on-page rectangles |
| `services/classifier.dart` | Textbook vs storybook from text signals — no LLM involved |
| `services/tts_service.dart` | Engine selection, chunked pipelined playback, segment callbacks |
| `services/piper_tts.dart` | Piper binary/voice discovery and synthesis |
| `services/ocr_service.dart` | Render → Tesseract → cache |
| `services/cover_service.dart` | First page → cached PNG |
| `services/settings_service.dart` | Preferences, bookmarks, positions; API keys to the OS keyring |
| `services/stats_service.dart` | Pages per day, streak, rolling 120-day window |
| `services/llm/` | Provider registry, prompt modes, output lengths, map-reduce summariser |

### Design rules

**Metadata only.** A `Book` carries a path, never content, so scanning a large
library never opens a file.

**Format stops at the reader.** Both readers hand downstream a plain
`List<String>` of sentences. Speech, highlighting, bookmarks, stats and AI are
therefore format-blind — none of them knows what a PDF is.

**The classifier is a gate, not a label.** A storybook has no code path to a
model; the AI button is never built. Ties break toward storybook, because the
cheap mistake is hiding a feature rather than spending money and sending text to
a third party.

**Fail loudly, never fall back.** A missing engine reports exactly what to
install. A dead local model never silently reroutes to the cloud.

**Cache derived work.** Covers, OCR text and classifications are computed once
and stored outside the library, which is treated as strictly read-only.

---

## The privacy boundary

**Local, always:** library scanning, PDF rendering, EPUB parsing, text
extraction, OCR, speech synthesis, cover generation, bookmarks, reading stats,
and the Ollama model.

**The one crossing:** selecting a cloud provider sends the chosen page range to
that provider. It is never implicit —

- it requires an explicit provider choice **and** a stored API key;
- the sheet states the destination and exact character count before sending;
- an unknown or corrupt provider setting falls back to **Ollama**, never a cloud
  provider;
- a failing local model raises an error rather than rerouting.

API keys live in the platform secure store (Keychain / Keystore / libsecret),
never in preferences and never in a file in the repo.

---

## Data flows

**Opening the library**
`folder → library_service → Book[] → library_node → shelves + tree`
Runs off the UI isolate; deep folder trees would otherwise jank the first frame.

**Reading aloud**
`Book → reader_service → spoken_text → sentences → tts_service → piper → audio`
Each chunk is one sentence, which is what makes exact follow-along highlighting
possible.

**A scanned page**
`page → no embedded text → render 300 dpi → tesseract → cached text`
Extraction is always attempted first: it is instant and more accurate when real
text exists.

**AI assist**
`classifier says textbook → page range → summariser → provider`

**EPUB**
`.epub → unzip → container.xml → OPF spine → XHTML → pages`
Parsed directly with `archive` + `html` + `xml`, because `epubx` conflicts with
`pdfrx` over the `image` package.

---

## The AI layer

### Modes

| Mode | Output |
|---|---|
| Summary | The gist in bullets |
| Learning | Core idea, concepts defined, an analogy, assumed knowledge |
| Interview | Q&A pairs, foundational → advanced |
| Flashcards | Front/back pairs for active recall |
| Key terms | Glossary as *this passage* uses each term |

### Lengths

`One line` · `Brief` (3 points) · `Standard` (6) · `Detailed` (12+ with
sub-structure).

Length is a separate axis from mode. `One line` deliberately overrides the mode's
shape — "one-line flashcards" is incoherent, so the length instruction wins.

### Context handling and chunking

Every model has a finite context window. Sending a whole chapter in one request
**does not fail loudly** — the model silently sees only part of it and answers
confidently about text it never read. That is the worst possible failure mode for
a study tool.

`summariser.dart` therefore:

1. Estimates tokens (~3.6 chars/token) and compares against the provider's
   `inputCharBudget` — about 55 % of its context, leaving room for the prompt and
   the answer.
2. **Fits:** one request.
3. **Does not fit:** map-reduce. Each chunk is condensed to notes (*map*), then
   the notes are summarised into the final answer (*reduce*). Chunks split on
   paragraph boundaries, falling back to sentence ends, with ~400 characters of
   overlap so an idea spanning a boundary survives on one side.
4. If the notes themselves overflow, they are condensed once more rather than
   truncated.

> **Ollama note.** Ollama defaults to a 2048–4096 token context *regardless of
> what the model supports*. The app sends `options.num_ctx` explicitly. Without
> it, every multi-page local summary was silently truncated.

### Providers

| Provider | Local | Context (declared) | Key |
|---|---|---|---|
| Ollama | ✅ | 8,192 (`num_ctx` sent) | none |
| Google Gemini | ☁️ | 120,000 | `GEMINI_API_KEY` |
| Groq | ☁️ | 32,000 | `GROQ_API_KEY` |
| OpenRouter | ☁️ | 32,000 | `OPENROUTER_API_KEY` |
| Together AI | ☁️ | 32,000 | `TOGETHER_API_KEY` |
| Hugging Face | ☁️ | 16,000 | `HF_TOKEN` |

Groq, OpenRouter, Together and Hugging Face share one OpenAI-compatible
implementation; only base URL and key differ. Temperature is 0.3 throughout —
summarising should be faithful, not creative.

---

## External dependencies

### Dart packages

`pdfrx` · `flutter_tts` · `archive` · `html` · `xml` · `http` ·
`shared_preferences` · `flutter_secure_storage` · `file_picker` ·
`path_provider` · `path` · `crypto` · `cupertino_icons`

No state-management library, no ORM, no HTTP wrapper, no LLM framework.

### External binaries (desktop only)

| Binary | Purpose | Without it |
|---|---|---|
| `piper` | Neural TTS | Falls back to espeak-ng |
| `tesseract` | OCR | Scanned pages report they need OCR |
| `spd-say` | Fallback TTS | Read-aloud unavailable |
| `pw-play` / `aplay` | Audio playback | Piper unavailable |
| `ollama` | Local LLM | Cloud providers only |

---

## Building

```bash
flutter build linux --release     # → build/linux/x64/release/bundle (~60 MB)
flutter build linux --debug
```

### Linux prerequisites

```bash
sudo apt install libsecret-1-dev libjsoncpp-dev   # flutter_secure_storage
```

**Toolchain note.** If the build fails with
`Failed to find any of [ld.lld, ld] in /usr/lib/llvm-18/bin`, that directory has
clang but no linker. Either install it:

```bash
sudo apt install lld-18
```

or use a shim on `PATH` (no root required):

```bash
mkdir -p ~/.local/llvm-shim/bin && cd ~/.local/llvm-shim/bin
cp /usr/lib/llvm-18/bin/clang clang      # a real file, not a symlink:
ln -sf clang clang++                     # the resolver canonicalises symlinks
ln -sf /usr/bin/ld ld
ln -sf /usr/bin/ld ld.lld
PATH="$HOME/.local/llvm-shim/bin:$PATH" flutter build linux --release
```

---

## Testing

```bash
flutter test --concurrency=1
```

**100 tests.** Use `--concurrency=1`: the parallel runner can deadlock on this
suite.

| Suite | Covers |
|---|---|
| `classifier_test` | Textbook/storybook detection **and its bias** — ties must fall to storybook |
| `provider_test` | Registry, cloud/local split, keys required before any request, context budgets |
| `summariser_test` | Chunk boundaries, no text lost, map-reduce call counts, prompt routing |
| `text_document_test` | EPUB spine order, chapter titles, script/style stripping, Latin-1 fallback |
| `reader_test` | Page ranges, 1-based indexing, render caching, out-of-range errors |
| `bookmark_test`, `settings_bookmark_test` | JSON round-trip, corrupt storage, persistence |
| `stats_test` | Streak logic including the "quiet today" case |
| `tts_test`, `ocr_test`, `library_tree_test` | Engine selection, availability, folder tree, search |

No test touches the network or your real library — the EPUB suite builds its own
EPUB in memory, and provider tests assert that requests *don't* happen.

---

## Configuration and storage

| Data | Location |
|---|---|
| Library path, provider, model, positions, bookmarks, favourites, stats | `SharedPreferences` |
| API keys | OS secure store (Keychain / Keystore / libsecret) |
| Covers, OCR text | `getApplicationCacheDirectory()/covers`, `/ocr` |
| Piper voices | `~/.local/share/piper-voices/*.onnx` |
| Your books | **Wherever they already are. Never copied, never modified.** |

---

## Known limitations

- **Mobile is unverified.** Nothing has been built for Android or iOS. Piper,
  Tesseract and Ollama are all subprocesses and cannot run there — a phone would
  get the system voice, no OCR, and cloud-only AI.
- **No audio export**, background playback, or sleep timer.
- **Markdown renders as raw text** (`## Heading` appears literally).
- **Duplicate titles are indistinguishable** in shelves and search results.
- **Night mode inverts photographs** along with text.
- **Highlighting is sentence-level, not word-level** — Piper does not expose
  phoneme timings.
- **No summary caching or streaming**; repeating a summary repeats the cost.

---

## Licence

MIT licensed (see LICENSE). No book content is included in this repository, and
`.gitignore` blocks every common book and audio format so it cannot be added
accidentally.
