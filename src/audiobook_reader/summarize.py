"""AI summary layer — summarise a page/chapter with a LOCAL model.

STUB. Privacy rule: book text goes to a local Ollama model only, never an external API.
Implement by POSTing to http://localhost:11434/api/generate with the configured model.
"""

from __future__ import annotations


def summarise(text: str, *, provider: str = "ollama", model: str = "llama3.2") -> str:
    """Return a short summary of `text` from a local model. Never call an external API here."""
    if provider != "ollama":
        raise ValueError("Only local providers are allowed for book content (privacy rule).")
    raise NotImplementedError("summarize.summarise: call local Ollama at localhost:11434.")
