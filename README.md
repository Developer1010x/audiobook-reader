# Audier

**A private, local-first reader and audiobook player for the books you already own.**

Open any PDF, EPUB, Markdown or text file. Read it on screen, have it read aloud in a
neural voice, OCR the scanned pages, and — for textbooks, when you ask — get study aids
from a local or cloud model.

Your books are read where they sit. Nothing is copied, uploaded or modified, and nothing
reaches a third party unless you name a cloud provider yourself.

```bash
cd app && flutter run -d linux
```

---

## Why this exists

Every reader app wants your library in its cloud. This one is built the other way around:
the library stays a folder on your disk, speech and OCR run as local processes, and the AI
layer defaults to a model on your own machine. The cloud is one clearly-marked door, not
the floor you are standing on.

That constraint drives the whole design — see [The privacy boundary](#the-privacy-boundary).

---

## What it does

| | |
|---|---|
| **Reads any format you own** | PDF with real page rendering, EPUB parsed from the OPF spine, Markdown rendered properly, plain text — all paginated so page numbers, resume and page ranges behave identically |
| **Reads aloud, well** | Neural speech via Piper, chunked and pipelined so audio starts in about a second rather than ten; espeak-ng as a fallback |
| **Follows along** | Sentence-level highlighting with auto-scroll, and tapping any sentence starts reading from there |
| **Handles scanned books** | Pages with no embedded text are detected and OCRed with Tesseract at 300 dpi, then cached so it never happens twice |
| **Keeps playing** | Background audio with lock-screen and headset controls, a sleep timer that stops on a sentence boundary, and a Car Mode built for glanceable use |
| **Studies with you** | Five AI modes — summary, learning, interview prep, flashcards, key terms — over four output lengths and six providers |
| **Remembers** | Bookmarks, highlights and notes with Markdown export; resume position per book; reading streaks and a 14-day sparkline |
| **Looks up words** | Built-in dictionary, no round trip to a browser |

Textbooks and storybooks are told apart by a local text classifier, and the AI layer is
only ever built for textbooks. It is a gate, not a label: a novel has no code path to a
model at all.

---

## The privacy boundary

**Always local** — library scanning, PDF rendering, EPUB parsing, text extraction, OCR,
speech synthesis, covers, bookmarks, reading stats, and the Ollama model.

**The one crossing** — choosing a cloud provider sends the page range you selected to that
provider. It is never implicit:

- it requires both an explicit provider choice **and** a stored API key;
- the sheet names the destination and the exact character count *before* sending;
- an unknown or corrupt provider setting falls back to Ollama, never to a cloud provider;
- a failing local model raises an error instead of quietly rerouting your book.

API keys live in the OS secure store — Keychain, Keystore or libsecret — never in
preferences and never in a file in this repository. `.gitignore` blocks every common book
and audio format, so an accidental `git add .` cannot leak a library.

---

## Install

### Run from source

```bash
cd app
flutter pub get
flutter run -d linux        # or: -d macos, -d windows, -d android
```

On first launch, pick your library folder. It is scanned recursively and never written to.

### Build and install a desktop binary

```bash
cd app
flutter build linux --release          # → build/linux/x64/release/bundle
```

Packaging manifests for **Flatpak** and **Snap** live in `app/packaging/` and `app/snap/`.

Linux prerequisites: `sudo apt install libsecret-1-dev libjsoncpp-dev`

### Optional engines

Every one of these is optional. The app degrades gracefully and tells you exactly what to
install when a feature needs something that is missing.

```bash
# Neural voice — strongly recommended; the system voice is robotic
uv venv ~/.local/share/piper-venv
VIRTUAL_ENV=~/.local/share/piper-venv uv pip install piper-tts
mkdir -p ~/.local/share/piper-voices && cd ~/.local/share/piper-voices
~/.local/share/piper-venv/bin/python -m piper.download_voices en_US-lessac-medium

sudo apt install tesseract-ocr                      # OCR for scanned pages
curl -fsSL https://ollama.com/install.sh | sh       # local LLM; keeps text on-device
ollama pull qwen2.5:1.5b
```

---

## Architecture

Four layers, dependencies running strictly downward. A service never imports a screen,
which is why every service is testable without a widget tree.

```
┌─ 1 · UI ───────────────────────────────────────────────────────────┐
│  library · reader · text_reader · car_mode · settings · sheets      │
└────────────────────────────┬───────────────────────────────────────┘
                             │  Book · Bookmark · BookType
┌─ 2 · Models ───────────────▼───────────────────────────────────────┐
│  book · library_node · bookmark                                     │
└────────────────────────────┬───────────────────────────────────────┘
                             │
┌─ 3 · Services ─────────────▼───────────────────────────────────────┐
│  library · reader · text_document · spoken_text · chapter_index     │
│  classifier ← the gate on the entire AI path                        │
│  tts → piper · ocr · cover · dictionary · recommender               │
│  audio/ background handler · sleep_timer · wakeful · media_player   │
│  settings · stats · theme · concurrency · runtime_env               │
│  llm/ provider · ai_mode · summary_length · summariser              │
└────────────────────────────┬───────────────────────────────────────┘
                             │
┌─ 4 · Outside ──────────────▼───────────────────────────────────────┐
│  pdfrx (in-process)                                                 │
│  piper · tesseract · ollama            (local subprocesses)         │
│  gemini · groq · openrouter · together · huggingface     (HTTPS)    │
└─────────────────────────────────────────────────────────────────────┘
```

Four rules hold the design together:

**Metadata only.** A `Book` carries a path, never content — so scanning a large library
never opens a file.

**Format stops at the reader.** Both readers hand downstream a plain `List<String>` of
sentences. Speech, highlighting, bookmarks, stats and AI are therefore format-blind; none
of them knows what a PDF is.

**Fail loudly, never fall back.** A missing engine reports exactly what to install. A dead
local model never silently reroutes to the cloud.

**Cache derived work.** Covers, OCR text and classifications are computed once and stored
outside the library, which is treated as strictly read-only.

### The chunking problem

Every model has a finite context window, and sending a whole chapter in one request **does
not fail loudly** — the model silently sees part of it and answers confidently about text
it never read. For a study tool that is the worst possible failure mode.

So the summariser estimates tokens against each provider's budget, and when the text does
not fit it map-reduces: each chunk is condensed to notes, then the notes are summarised
into the answer. Chunks split on paragraph boundaries with ~400 characters of overlap, so
an idea spanning a boundary survives on one side.

> Ollama defaults to a 2048–4096 token context *regardless of what the model supports*.
> The app sends `options.num_ctx` explicitly — without it, every multi-page local summary
> was silently truncated.

---

## Testing

```bash
cd app && flutter test --concurrency=1
```

**198 tests across 17 suites.** Use `--concurrency=1`; the parallel runner can deadlock on
this suite.

No test touches the network or your real library — the EPUB suite builds its own EPUB in
memory, and the provider tests assert that requests *don't* happen. The classifier suite
tests its bias explicitly: ties must fall to storybook, because the cheap mistake is hiding
a feature rather than spending money and sending text to a third party.

---

## Repository layout

```
app/            The Flutter application — this is the product
  lib/          main.dart · models/ · services/ · ui/
  test/         17 suites
  packaging/    Flatpak manifest, desktop entry, AppStream metainfo
  snap/         snapcraft.yaml
  README.md     Full technical reference — module table, data flows, provider matrix
docs/           Icon and screenshots
src/, tests/    Superseded Python CLI prototype, kept for reference
```

**[`app/README.md`](app/README.md)** is the deep reference: every module and its
responsibility, the data flows, the full provider matrix, and the desktop toolchain notes.

---

## Providers

| Provider | Local | Context (declared) | Key |
|---|---|---|---|
| Ollama | ✅ | 8,192 (`num_ctx` sent) | none |
| Google Gemini | ☁️ | 120,000 | `GEMINI_API_KEY` |
| Groq | ☁️ | 32,000 | `GROQ_API_KEY` |
| OpenRouter | ☁️ | 32,000 | `OPENROUTER_API_KEY` |
| Together AI | ☁️ | 32,000 | `TOGETHER_API_KEY` |
| Hugging Face | ☁️ | 16,000 | `HF_TOKEN` |

The four OpenAI-compatible providers share one implementation; only base URL and key
differ. Temperature is 0.3 throughout — summarising should be faithful, not creative.

---

## Known limitations

- **Mobile is only partly verified.** Piper, Tesseract and Ollama are subprocesses and
  cannot run on a phone, so mobile gets the system voice, no OCR, and cloud-only AI.
- **Highlighting is sentence-level, not word-level** — Piper does not expose phoneme
  timings.
- **Night mode inverts photographs** along with text.
- **Duplicate titles are indistinguishable** in shelves and search results.
- **No summary caching or streaming** — repeating a summary repeats the cost.
- **No audio export.**

---

## Licence

Private project. No book content is included in this repository.
