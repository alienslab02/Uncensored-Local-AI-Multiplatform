"""Chatterbox Nano / Turbo / Multilingual V3 backends (local, MIT)."""

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
REF_DIR = DATA / "references"
DEFAULT_REF = REF_DIR / "default_ref.wav"


def _pick_device() -> str:
    forced = os.environ.get("VOICE_TTS_DEVICE", "").strip().lower()
    if forced in {"cpu", "mps", "cuda"}:
        return forced
    try:
        import torch

        if torch.backends.mps.is_available():
            return "mps"
        if torch.cuda.is_available():
            return "cuda"
    except Exception:  # noqa: BLE001
        pass
    return "cpu"


def _ensure_reference_wav(path: Path) -> Path | None:
    """Optional >5s reference for custom voice cloning (builtin conds often enough)."""
    if path.is_file() and path.stat().st_size > 1000:
        return path
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        from .kokoro_backend import KokoroBackend

        k = KokoroBackend()
        k.load()
        text = (
            "Hello. This is a short voice reference for local speech synthesis. "
            "It needs to be longer than five seconds so the model can lock onto the voice. "
            "Thanks for waiting while we prepare the expressive speech engine."
        )
        result = k.speak(text)
        path.write_bytes(result.wav_bytes)
        with wave.open(str(path), "rb") as wf:
            seconds = wf.getnframes() / float(wf.getframerate())
        if seconds > 5.0:
            return path
    except Exception:  # noqa: BLE001
        pass
    return None


def _float_to_wav_bytes(audio: np.ndarray, sample_rate: int) -> bytes:
    audio = np.asarray(audio).squeeze()
    if audio.dtype != np.int16:
        audio_i16 = (np.clip(audio.astype(np.float32), -1.0, 1.0) * 32767.0).astype(
            np.int16
        )
    else:
        audio_i16 = audio
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(int(sample_rate))
        wf.writeframes(audio_i16.tobytes())
    return buf.getvalue()


class _ChatterboxTurboFamily(TtsBackend):
    nano: bool = False
    name = "chatterbox_turbo"

    def __init__(self) -> None:
        self._model = None
        self._device = "cpu"
        self._ref: Path | None = None

    def load(self) -> None:
        try:
            from chatterbox.tts_turbo import ChatterboxTurboTTS
        except ImportError as e:
            raise ImportError(
                "chatterbox-tts not installed. "
                "Run: uv pip install -r requirements-chatterbox.txt"
            ) from e

        self._device = _pick_device()
        self._model = ChatterboxTurboTTS.from_pretrained(
            self._device, nano=self.nano
        )
        # Prefer builtin conds.pt; only build a Kokoro ref if user forces VOICE_TTS_REFERENCE
        # or builtin conditionals are missing.
        has_builtin = getattr(self._model, "conds", None) is not None
        if os.environ.get("VOICE_TTS_REFERENCE"):
            self._ref = _ensure_reference_wav(Path(os.environ["VOICE_TTS_REFERENCE"]))
        elif not has_builtin:
            self._ref = _ensure_reference_wav(DEFAULT_REF)
        else:
            self._ref = None

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
        del language_id, kwargs
        if self._model is None:
            raise RuntimeError(f"{self.name} not loaded")

        gen_kwargs: dict[str, Any] = {}
        ref_path = reference_wav
        if not ref_path and voice:
            # Allow catalog stems / bare filenames under reference dirs
            from .voices import resolve_voice

            try:
                resolved = resolve_voice(
                    voice if voice.startswith("ref:") or voice.endswith(".wav")
                    else f"ref:{voice}"
                )
                ref_path = resolved.get("reference_wav")
            except Exception:  # noqa: BLE001
                ref_path = None
        if ref_path:
            gen_kwargs["audio_prompt_path"] = ref_path
        elif self._ref is not None and self._ref.is_file():
            gen_kwargs["audio_prompt_path"] = str(self._ref)
        if exaggeration is not None:
            gen_kwargs["exaggeration"] = float(exaggeration)

        wav = self._model.generate(text, **gen_kwargs)
        arr = wav.detach().cpu().numpy() if hasattr(wav, "detach") else np.asarray(wav)
        sr = int(getattr(self._model, "sr", 24000))
        return SpeakResult(wav_bytes=_float_to_wav_bytes(arr, sr), sample_rate=sr)

    def health(self) -> dict[str, Any]:
        return {
            "backend": self.name,
            "ready": self._model is not None,
            "engine": "chatterbox-nano" if self.nano else "chatterbox-turbo",
            "device": self._device,
            "reference": str(self._ref) if self._ref else None,
        }


@register
class ChatterboxNanoBackend(_ChatterboxTurboFamily):
    name = "chatterbox_nano"
    nano = True


@register
class ChatterboxTurboBackend(_ChatterboxTurboFamily):
    name = "chatterbox_turbo"
    nano = False


@register
class ChatterboxMultilingualV3Backend(TtsBackend):
    name = "chatterbox_mtl_v3"

    def __init__(self) -> None:
        self._model = None
        self._device = "cpu"
        self._ref: Path | None = None

    def load(self) -> None:
        try:
            from chatterbox.mtl_tts import ChatterboxMultilingualTTS
        except ImportError as e:
            raise ImportError(
                "chatterbox-tts not installed. "
                "Run: uv pip install -r requirements-chatterbox.txt"
            ) from e

        self._device = _pick_device()
        self._model = ChatterboxMultilingualTTS.from_pretrained(
            self._device, t3_model="v3"
        )
        ref_env = os.environ.get("VOICE_TTS_REFERENCE", str(DEFAULT_REF))
        self._ref = _ensure_reference_wav(Path(ref_env))

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
        del voice, kwargs
        if self._model is None:
            raise RuntimeError(f"{self.name} not loaded")
        lang = (language_id or os.environ.get("VOICE_TTS_LANGUAGE", "en")).strip()
        gen_kwargs: dict[str, Any] = {"language_id": lang}
        ref_path = Path(reference_wav) if reference_wav else self._ref
        if ref_path is not None and ref_path.is_file():
            gen_kwargs["audio_prompt_path"] = str(ref_path)
        if exaggeration is not None:
            gen_kwargs["exaggeration"] = float(exaggeration)

        wav = self._model.generate(text, **gen_kwargs)
        arr = wav.detach().cpu().numpy() if hasattr(wav, "detach") else np.asarray(wav)
        sr = int(getattr(self._model, "sr", 24000))
        return SpeakResult(wav_bytes=_float_to_wav_bytes(arr, sr), sample_rate=sr)

    def health(self) -> dict[str, Any]:
        return {
            "backend": self.name,
            "ready": self._model is not None,
            "engine": "chatterbox-multilingual-v3",
            "device": self._device,
            "reference": str(self._ref) if self._ref else None,
        }
