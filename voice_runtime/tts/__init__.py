"""Pluggable TTS backends for Mode V voice_runtime."""

from .base import SpeakResult, TtsBackend, get_tts_backend, list_backends

__all__ = [
    "SpeakResult",
    "TtsBackend",
    "get_tts_backend",
    "list_backends",
]
