"""AI summary layer — summarise a page/chapter with a local OR a cloud model.

TWO PROVIDERS, AND THEY ARE NOT EQUIVALENT:

  "ollama"  (default)  — local. Book text stays on this machine. Private.
  "gemini"  (opt-in)   — Google's API. BOOK TEXT LEAVES THIS MACHINE and is sent to
                         Google, subject to their retention and training policy.

Gemini is never selected implicitly: it must be named in config.toml or passed explicitly,
AND an API key must be present in the environment. There is deliberately no fallback from
ollama to gemini — a local model being down must fail loudly, never silently ship your
library to a third party.

Uses stdlib urllib so neither provider adds a dependency.
"""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.request

OLLAMA_URL = "http://localhost:11434/api/generate"
GEMINI_URL = "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"

# Checked in order; the first one set wins.
GEMINI_KEY_VARS = ("GEMINI_API_KEY", "GOOGLE_API_KEY")

LOCAL_PROVIDERS = {"ollama"}
CLOUD_PROVIDERS = {"gemini"}

DEFAULT_MODELS = {"ollama": "qwen2.5:1.5b", "gemini": "gemini-2.5-flash"}


def default_model(provider: str) -> str | None:
    """The model used when none is configured — so callers can display what will run."""
    return DEFAULT_MODELS.get(provider.lower())

PROMPT = (
    "Summarise the following passage from a book in {n} short bullet points. "
    "Be concrete and keep the author's own terminology.\n\n{text}"
)


def _post(url: str, payload: dict, headers: dict, timeout: int) -> dict:
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", **headers},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read())


def _summarise_ollama(text: str, model: str, bullets: int, timeout: int) -> str:
    payload = {
        "model": model,
        "prompt": PROMPT.format(n=bullets, text=text),
        "stream": False,
    }
    try:
        return _post(OLLAMA_URL, payload, {}, timeout).get("response", "").strip()
    except urllib.error.URLError as e:
        raise RuntimeError(
            f"Could not reach Ollama at {OLLAMA_URL} ({e}). Is `ollama serve` running, "
            f"and is the model pulled?  ollama pull {model}"
        ) from e


def gemini_api_key() -> str | None:
    """The Gemini key from the environment, or None. Never read from a committed file."""
    for var in GEMINI_KEY_VARS:
        key = os.environ.get(var)
        if key:
            return key.strip()
    return None


def _summarise_gemini(text: str, model: str, bullets: int, timeout: int) -> str:
    key = gemini_api_key()
    if not key:
        raise RuntimeError(
            "Gemini selected but no API key found. Set one of "
            f"{' or '.join(GEMINI_KEY_VARS)} in your environment (or in .env, which is "
            "git-ignored):\n    export GEMINI_API_KEY=...\n"
            "Get a key at https://aistudio.google.com/apikey"
        )
    payload = {
        "contents": [{"parts": [{"text": PROMPT.format(n=bullets, text=text)}]}]
    }
    try:
        data = _post(
            GEMINI_URL.format(model=model), payload, {"x-goog-api-key": key}, timeout
        )
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")[:400]
        raise RuntimeError(f"Gemini API error {e.code}: {body}") from e
    except urllib.error.URLError as e:
        raise RuntimeError(f"Could not reach the Gemini API ({e}).") from e

    candidates = data.get("candidates") or []
    if not candidates:
        # Usually a safety block or an empty finish — surface it rather than returning "".
        raise RuntimeError(f"Gemini returned no candidates: {json.dumps(data)[:400]}")
    parts = candidates[0].get("content", {}).get("parts", [])
    return "".join(p.get("text", "") for p in parts).strip()


def summarise(
    text: str,
    *,
    provider: str = "ollama",
    model: str | None = None,
    bullets: int = 5,
    timeout: int = 120,
) -> str:
    """Return a short summary of `text`.

    provider="ollama" keeps the text local. provider="gemini" SENDS IT TO GOOGLE.
    """
    provider = provider.lower()
    if not text.strip():
        raise ValueError("Nothing to summarise — the page had no extractable text.")

    if provider in LOCAL_PROVIDERS:
        return _summarise_ollama(text, model or DEFAULT_MODELS["ollama"], bullets, timeout)
    if provider in CLOUD_PROVIDERS:
        return _summarise_gemini(text, model or DEFAULT_MODELS["gemini"], bullets, timeout)
    raise ValueError(
        f"Unknown provider '{provider}'. Known: "
        f"{', '.join(sorted(LOCAL_PROVIDERS | CLOUD_PROVIDERS))}."
    )


def is_cloud(provider: str) -> bool:
    """True if this provider sends book text off the machine. Callers warn on this."""
    return provider.lower() in CLOUD_PROVIDERS
