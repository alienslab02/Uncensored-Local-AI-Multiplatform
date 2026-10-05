#!/usr/bin/env python3
"""Mode V voice runtime — loopback STT/TTS for Flutter voice chat."""

from __future__ import annotations

import os
import re
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.responses import Response
from pydantic import BaseModel, Field

from tts import get_tts_backend
from tts.kokoro_backend import DEFAULT_VOICE, configure_espeak

ROOT = Path(__file__).resolve().parent
DATA = ROOT / "data"
WHISPER_MODEL = os.environ.get("WHISPER_MODEL", "tiny")
HOST = os.environ.get("VOICE_RUNTIME_HOST", "127.0.0.1")
PORT = int(os.environ.get("VOICE_RUNTIME_PORT", "8765"))


class SpeakRequest(BaseModel):
    text: str = Field(..., min_length=1, max_length=2000)
    voice: str = Field(default=DEFAULT_VOICE)
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


app = FastAPI(title="Uncensored Local AI Voice Runtime", lifespan=lifespan)


@app.get("/health")
def health() -> dict:
    tts_ready = state.tts is not None
    tts_info = {
        "ready": tts_ready,
        "default_voice": DEFAULT_VOICE,
        "error": state.tts_error or state.tts_meta.get("error"),
        "requested": state.tts_meta.get("requested"),
        "active": state.tts_meta.get("active"),
        "fallback_used": bool(state.tts_meta.get("fallback_used")),
        "available": state.tts_meta.get("available"),
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
    text = re.sub(r"<\|[^|>]+?\|>", " ", text)
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
        result = state.tts.speak(
            text,
            voice=body.voice or DEFAULT_VOICE,
            language_id=body.language_id,
            exaggeration=body.exaggeration,
            reference_wav=body.reference_wav,
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
