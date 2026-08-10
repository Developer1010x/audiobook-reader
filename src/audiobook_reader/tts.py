"""Text-to-speech layer — read a page/chapter aloud.

STUB. Default engine is offline/system (no cloud), per the privacy rule. Candidates:
pyttsx3 (fully offline, simplest) or Piper (better voices, still local).
"""

from __future__ import annotations


def speak(text: str, *, engine: str = "system") -> None:
    """Speak `text` now (blocking). Offline engine only — book text never leaves the machine."""
    raise NotImplementedError("tts.speak: implement with pyttsx3 (offline) or Piper.")


def to_audio_file(text: str, out_path: str, *, engine: str = "system") -> str:
    """Render `text` to an audio file in the git-ignored audio_cache/. Returns the path."""
    raise NotImplementedError("tts.to_audio_file: render to audio_cache/ (git-ignored).")
