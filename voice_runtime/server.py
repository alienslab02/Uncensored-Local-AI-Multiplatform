#!/usr/bin/env python3
"""Mode V voice runtime — loopback STT/TTS for Flutter voice chat."""

from __future__ import annotations

import os
import re
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import Response
from pydantic import BaseModel, Field

from tts import get_tts_backend
from tts.kokoro_backend import DEFAULT_VOICE, configure_espeak
from tts.voices import catalog as voices_catalog
from tts.voices import delete_reference_voice, import_reference_wav, resolve_voice

ROOT = Path(__file__).resolve().parent
DATA = ROOT / "data"
WHISPER_MODEL = os.environ.get("WHISPER_MODEL", "tiny")
HOST = os.environ.get("VOICE_RUNTIME_HOST", "127.0.0.1")
PORT = int(os.environ.get("VOICE_RUNTIME_PORT", "8765"))


class SpeakRequest(BaseModel):
    text: str = Field(..., min_length=1, max_length=2000)
    # Catalog id (`kokoro:af_heart`, `ref:my_clone`) or bare Kokoro preset / WAV path
    voice: str = Field(default="")
    language_id: str | None = Field(default=None)
    exaggeration: float | None = Field(default=None, ge=0.0, le=2.0)
    reference_wav: str | None = Field(default=None)


class RuntimeState:
    def __init__(self) -> None:
        self.tts = None
        self.tts_meta: dict = {}
        self.whisper = None
        self.tts_error: str | None = None
        self.stt_error: str | None = None

    def load(self) -> None:
        configure_espeak()
        try:
            self.tts, self.tts_meta = get_tts_backend()
        except Exception as e:  # noqa: BLE001 — surface in /health
            self.tts_error = f"{type(e).__name__}: {e}"
            self.tts = None
            self.tts_meta = {"error": self.tts_error}

        try:
            from faster_whisper import WhisperModel

            self.whisper = WhisperModel(
                WHISPER_MODEL,
                device="cpu",
                compute_type="int8",
                download_root=str(DATA / "whisper"),
            )
        except Exception as e:  # noqa: BLE001
            self.stt_error = f"{type(e).__name__}: {e}"
            self.whisper = None


state = RuntimeState()


@asynccontextmanager
async def lifespan(_app: FastAPI):
    state.load()
    yield


app = FastAPI(title="Mate Voice Runtime", lifespan=lifespan)


@app.get("/health")
def health() -> dict:
    tts_ready = state.tts is not None
    active = state.tts_meta.get("active")
    cat = voices_catalog(active_backend=active if isinstance(active, str) else None)
    tts_info = {
        "ready": tts_ready,
        "default_voice": DEFAULT_VOICE,
        "selected_voice": cat.get("default_id"),
        "error": state.tts_error or state.tts_meta.get("error"),
        "requested": state.tts_meta.get("requested"),
        "active": active,
        "fallback_used": bool(state.tts_meta.get("fallback_used")),
        "available": state.tts_meta.get("available"),
        "voice_count": len(cat.get("voices") or []),
    }
    if state.tts is not None:
        tts_info.update(state.tts.health())
    return {
        "ready": tts_ready and state.whisper is not None,
        "stt": {
            "ready": state.whisper is not None,
            "model": WHISPER_MODEL,
            "error": state.stt_error,
        },
        "tts": tts_info,
        "host": HOST,
        "port": PORT,
    }


@app.get("/voices")
def list_voices() -> dict:
    active = state.tts_meta.get("active")
    return voices_catalog(active_backend=active if isinstance(active, str) else None)


@app.post("/voices")
async def upload_voice(
    audio: UploadFile = File(...),
    name: str | None = Form(default=None),
) -> dict:
    raw = await audio.read()
    filename = name or audio.filename or "custom_voice.wav"
    if not filename.lower().endswith(".wav"):
        filename = f"{Path(filename).stem}.wav"
    try:
        entry = import_reference_wav(filename, raw)
    except ValueError as e:
        raise HTTPException(400, detail=str(e)) from e
    except OSError as e:
        raise HTTPException(500, detail=f"save failed: {e}") from e
    return {"ok": True, "voice": entry}


@app.delete("/voices")
def remove_voice(id: str) -> dict:
    """Delete a custom clone (`id=ref:…`). Built-in Kokoro presets are not removable."""
    try:
        result = delete_reference_voice(id)
    except ValueError as e:
        raise HTTPException(400, detail=str(e)) from e
    except FileNotFoundError as e:
        raise HTTPException(404, detail=str(e)) from e
    except PermissionError as e:
        raise HTTPException(403, detail=str(e)) from e
    except OSError as e:
        raise HTTPException(500, detail=f"delete failed: {e}") from e
    return {"ok": True, **result}


@app.post("/transcribe")
async def transcribe(audio: UploadFile = File(...)) -> dict:
    if state.whisper is None:
        raise HTTPException(503, detail=state.stt_error or "STT not ready")
    raw = await audio.read()
    if not raw:
        raise HTTPException(400, detail="empty audio")

    import tempfile

    suffix = Path(audio.filename or "audio.wav").suffix or ".wav"
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=True) as tmp:
        tmp.write(raw)
        tmp.flush()
        segments, info = state.whisper.transcribe(
            tmp.name, beam_size=1, vad_filter=True
        )
        text = " ".join(s.text.strip() for s in segments).strip()
    return {
        "text": text,
        "language": getattr(info, "language", None),
    }


# Chatterbox Nano/Turbo special tokens (from added_tokens.json). Not all words work.
_CHATTERBOX_TAGS = frozenset(
    {
        "advertisement",
        "angry",
        "chuckle",
        "clear throat",
        "cough",
        "crying",
        "dramatic",
        "fear",
        "gasp",
        "groan",
        "happy",
        "laugh",
        "narration",
        "sarcastic",
        "shush",
        "sigh",
        "sniff",
        "surprised",
        "whispering",
    }
)

# Common LLM inventions → real tags ([smile] is NOT supported)
_TAG_ALIASES = {
    "smile": "happy",
    "smiling": "happy",
    "grin": "happy",
    "giggle": "chuckle",
    "lol": "laugh",
    "haha": "laugh",
    "cry": "crying",
    "sob": "crying",
    "whisper": "whispering",
    "wow": "surprised",
    "shock": "surprised",
    "scared": "fear",
    "sad": "sigh",
    "hmm": "sigh",
    "ahem": "clear throat",
}


def _normalize_paralinguistic_tags(text: str) -> str:
    def repl(m: re.Match[str]) -> str:
        inner = m.group(1).strip().lower()
        inner = _TAG_ALIASES.get(inner, inner)
        if inner in _CHATTERBOX_TAGS:
            return f"[{inner}]"
        # Drop unknown bracket tags so TTS doesn't spell them
        return " "

    return re.sub(r"\[([^\]]+)\]", repl, text)


def _sanitize_tts_text(raw: str) -> str:
    """Strip model control tokens / markdown; normalize Chatterbox tags."""
    text = raw.strip()
    # Cut at first control leak (incl. truncated `<end|>` without opening `|`)
    for marker in ("<|", "<end|>", "<end_of_turn>", "<start_of_turn>", "</s>"):
        i = text.find(marker)
        if i >= 0:
            text = text[:i]
            break
    text = re.sub(r"<\|[^|>]*\|?>?", " ", text)
    text = re.sub(r"<?end\|>", " ", text)
    text = re.sub(r"</?(?:end_of_turn|start_of_turn|s|pad)(?:\s[^>]*)?>", " ", text, flags=re.I)
    # Markdown emphasis only — keep [] for paralinguistic tags
    text = re.sub(r"[`*_#~>{}|\\]", " ", text)
    text = _normalize_paralinguistic_tags(text)
    text = re.sub(r"\s+", " ", text).strip()
    if not re.search(r"[A-Za-z0-9\u00C0-\u024F\u0400-\u04FF\u4E00-\u9FFF]", text):
        if not re.search(r"\[[^\]]+\]", text):
            return ""
    return text


@app.post("/speak")
def speak(body: SpeakRequest) -> Response:
    if state.tts is None:
        raise HTTPException(503, detail=state.tts_error or "TTS not ready")
    text = _sanitize_tts_text(body.text)
    if not text:
        raise HTTPException(400, detail="nothing speakable after sanitize")

    try:
        resolved = resolve_voice(body.voice or None)
    except FileNotFoundError as e:
        raise HTTPException(404, detail=str(e)) from e

    ref = body.reference_wav or resolved.get("reference_wav")
    preset = resolved.get("voice") or DEFAULT_VOICE

    try:
        result = state.tts.speak(
            text,
            voice=preset,
            language_id=body.language_id,
            exaggeration=body.exaggeration,
            reference_wav=ref,
        )
    except ValueError as e:
        raise HTTPException(422, detail=str(e)) from e
    except Exception as e:  # noqa: BLE001
        raise HTTPException(500, detail=f"{type(e).__name__}: {e}") from e

    return Response(content=result.wav_bytes, media_type="audio/wav")


def main() -> None:
    import uvicorn

    uvicorn.run(
        "server:app",
        host=HOST,
        port=PORT,
        reload=False,
        log_level="info",
    )


if __name__ == "__main__":
    main()
