"""Summariser tests. Every network call is mocked — these tests never contact Ollama,
never contact Google, and never send a byte anywhere."""
import pytest

from audiobook_reader import summarize


@pytest.fixture(autouse=True)
def no_ambient_key(monkeypatch):
    """A key in the developer's real environment must not change test outcomes."""
    for var in summarize.GEMINI_KEY_VARS:
        monkeypatch.delenv(var, raising=False)


def capture(monkeypatch, reply: dict):
    """Replace the HTTP layer, recording what would have been sent."""
    sent = {}

    def fake_post(url, payload, headers, timeout):
        sent.update(url=url, payload=payload, headers=headers, timeout=timeout)
        return reply

    monkeypatch.setattr(summarize, "_post", fake_post)
    return sent


def test_ollama_is_the_default_and_hits_localhost(monkeypatch):
    sent = capture(monkeypatch, {"response": "  a local summary  "})
    assert summarize.summarise("some book text") == "a local summary"
    assert sent["url"] == summarize.OLLAMA_URL
    assert "localhost" in sent["url"]
    assert sent["headers"] == {}  # no API key ever attached to the local call


def test_gemini_sends_key_as_header_and_parses_parts(monkeypatch):
    monkeypatch.setenv("GEMINI_API_KEY", "test-key-123")
    sent = capture(
        monkeypatch,
        {"candidates": [{"content": {"parts": [{"text": "cloud "}, {"text": "summary"}]}}]},
    )
    out = summarize.summarise("some book text", provider="gemini")
    assert out == "cloud summary"
    assert sent["headers"]["x-goog-api-key"] == "test-key-123"
    assert "generativelanguage.googleapis.com" in sent["url"]


def test_gemini_model_lands_in_the_url(monkeypatch):
    monkeypatch.setenv("GEMINI_API_KEY", "k")
    sent = capture(monkeypatch, {"candidates": [{"content": {"parts": [{"text": "x"}]}}]})
    summarize.summarise("t", provider="gemini", model="gemini-2.5-pro")
    assert "gemini-2.5-pro:generateContent" in sent["url"]


def test_gemini_without_a_key_raises_and_sends_nothing(monkeypatch):
    def explode(*a, **k):
        raise AssertionError("must not make a request without a key")

    monkeypatch.setattr(summarize, "_post", explode)
    with pytest.raises(RuntimeError, match="no API key found"):
        summarize.summarise("text", provider="gemini")


def test_gemini_googleapikey_var_also_works(monkeypatch):
    monkeypatch.setenv("GOOGLE_API_KEY", "second-choice")
    sent = capture(monkeypatch, {"candidates": [{"content": {"parts": [{"text": "x"}]}}]})
    summarize.summarise("t", provider="gemini")
    assert sent["headers"]["x-goog-api-key"] == "second-choice"


def test_empty_gemini_candidates_raise_rather_than_return_blank(monkeypatch):
    monkeypatch.setenv("GEMINI_API_KEY", "k")
    capture(monkeypatch, {"promptFeedback": {"blockReason": "SAFETY"}})
    with pytest.raises(RuntimeError, match="no candidates"):
        summarize.summarise("t", provider="gemini")


def test_unknown_provider_rejected(monkeypatch):
    monkeypatch.setattr(summarize, "_post", lambda *a, **k: {})
    with pytest.raises(ValueError, match="Unknown provider"):
        summarize.summarise("text", provider="openai")


def test_empty_text_rejected_before_any_request(monkeypatch):
    def explode(*a, **k):
        raise AssertionError("must not send an empty request")

    monkeypatch.setattr(summarize, "_post", explode)
    with pytest.raises(ValueError, match="Nothing to summarise"):
        summarize.summarise("   ")


def test_is_cloud_classification():
    """The flag the CLI uses to warn the user. Getting this wrong leaks silently."""
    assert summarize.is_cloud("gemini") and summarize.is_cloud("GEMINI")
    assert not summarize.is_cloud("ollama")


def test_ollama_never_falls_back_to_the_cloud(monkeypatch):
    """A local model being down must fail, not silently ship the book to Google."""
    import urllib.error

    def down(*a, **k):
        raise urllib.error.URLError("connection refused")

    monkeypatch.setattr(summarize, "_post", down)
    with pytest.raises(RuntimeError, match="Could not reach Ollama"):
        summarize.summarise("text", provider="ollama")
