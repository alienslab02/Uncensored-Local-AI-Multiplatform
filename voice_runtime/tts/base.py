"""TTS backend protocol + registry with Kokoro auto-fallback."""

from __future__ import annotations

import os
from abc import ABC, abstractmethod
from dataclasses import dataclass
from typing import Any


@dataclass
class SpeakResult:
    wav_bytes: bytes
    sample_rate: int


class TtsBackend(ABC):
    name: str = "base"

    @abstractmethod
    def load(self) -> None:
        """Load weights; raise on failure."""

    @abstractmethod
    def speak(
        self,
        text: str,
        *,
        voice: str | None = None,
        language_id: str | None = None,
        exaggeration: float | None = None,
        reference_wav: str | None = None,
        **kwargs: Any,
    ) -> SpeakResult:
        """Synthesize WAV bytes."""

    def health(self) -> dict[str, Any]:
        return {"backend": self.name, "ready": True}


FALLBACK_NAME = "kokoro"

_REGISTRY: dict[str, type[TtsBackend]] = {}


def register(cls: type[TtsBackend]) -> type[TtsBackend]:
    _REGISTRY[cls.name] = cls
    return cls


def list_backends() -> list[str]:
    return sorted(_REGISTRY.keys())


def _requested_name() -> str:
    return os.environ.get("VOICE_TTS_BACKEND", "chatterbox_nano").strip().lower()


def get_tts_backend() -> tuple[TtsBackend, dict[str, Any]]:
    """
    Load requested backend; on Chatterbox failure, fall back to kokoro.

    Returns (backend, meta) with requested/active/fallback_used/error.
    """
    from . import chatterbox_backend as _cb  # noqa: F401
    from . import kokoro_backend as _kb  # noqa: F401

    requested = _requested_name()
    meta: dict[str, Any] = {
        "requested": requested,
        "active": None,
        "fallback_used": False,
        "error": None,
        "available": list_backends(),
    }

    primary = requested
    if primary not in _REGISTRY:
        meta["error"] = f"unknown backend {primary!r}; available={list_backends()}"
        meta["requested_invalid"] = True
        primary = FALLBACK_NAME

    def _try(name: str) -> TtsBackend:
        cls = _REGISTRY[name]
        inst = cls()
        inst.load()
        return inst

    try:
        backend = _try(primary)
        meta["active"] = backend.name
        if meta.get("requested_invalid") or primary != requested:
            meta["fallback_used"] = True
        return backend, meta
    except Exception as e:  # noqa: BLE001
        meta["error"] = f"{type(e).__name__}: {e}"
        if primary == FALLBACK_NAME:
            raise
        try:
            backend = _try(FALLBACK_NAME)
            meta["active"] = backend.name
            meta["fallback_used"] = True
            return backend, meta
        except Exception as e2:  # noqa: BLE001
            meta["error"] = (
                f"primary: {meta['error']}; fallback: {type(e2).__name__}: {e2}"
            )
            raise RuntimeError(meta["error"]) from e2
