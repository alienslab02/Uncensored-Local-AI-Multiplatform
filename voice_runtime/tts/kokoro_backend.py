"""Kokoro ONNX TTS — named fallback / current Mode V stack."""

from __future__ import annotations

import io
import os
import wave
from pathlib import Path
from typing import Any

import numpy as np

from .base import SpeakResult, TtsBackend, register

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "data"
KOKORO_MODEL = DATA / "kokoro" / "kokoro-v1.0.onnx"
KOKORO_VOICES = DATA / "kokoro" / "voices-v1.0.bin"
DEFAULT_VOICE = os.environ.get("VOICE_PRESET", "af_heart")


def configure_espeak() -> None:
    brew_data = Path("/opt/homebrew/share/espeak-ng-data")
    brew_bin = Path("/opt/homebrew/bin/espeak-ng")
    if brew_data.is_dir():
        os.environ.setdefault("ESPEAK_DATA_PATH", str(brew_data))
    if brew_bin.is_file():
        os.environ.setdefault("PHONEMIZER_ESPEAK_PATH", str(brew_bin))


@register
class KokoroBackend(TtsBackend):
    name = "kokoro"

    def __init__(self) -> None:
        self._kokoro = None

    def load(self) -> None:
        configure_espeak()
        from kokoro_onnx import Kokoro

        if not KOKORO_MODEL.exists() or not KOKORO_VOICES.exists():
            raise FileNotFoundError(
                f"Missing Kokoro assets under {DATA / 'kokoro'}. "
                "Run scripts/setup_mac.sh"
            )
        self._kokoro = Kokoro(str(KOKORO_MODEL), str(KOKORO_VOICES))

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
        del language_id, exaggeration, reference_wav, kwargs
        if self._kokoro is None:
            raise RuntimeError("Kokoro not loaded")
        speed = float(os.environ.get("VOICE_TTS_SPEED", "0.92"))
        samples, sample_rate = self._kokoro.create(
            text,
            voice=voice or DEFAULT_VOICE,
            speed=speed,
            lang="en-us",
        )
        audio = np.asarray(samples)
        if audio.dtype != np.int16:
            audio_i16 = (np.clip(audio, -1.0, 1.0) * 32767.0).astype(np.int16)
        else:
            audio_i16 = audio

        buf = io.BytesIO()
        with wave.open(buf, "wb") as wf:
            wf.setnchannels(1)
            wf.setsampwidth(2)
            wf.setframerate(int(sample_rate))
            wf.writeframes(audio_i16.tobytes())
        return SpeakResult(wav_bytes=buf.getvalue(), sample_rate=int(sample_rate))

    def health(self) -> dict[str, Any]:
        return {
            "backend": self.name,
            "ready": self._kokoro is not None,
            "engine": "kokoro-onnx",
            "default_voice": DEFAULT_VOICE,
        }
