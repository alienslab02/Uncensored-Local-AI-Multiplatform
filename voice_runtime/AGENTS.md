# voice_runtime/ — Mode V host STT/TTS

Host-native FastAPI sidecar for Flutter voice chat. **Not Docker.** Product voice path (macOS-first — see root [ROADMAP.md](../ROADMAP.md)).

## Purpose

- `POST /transcribe` — faster-whisper
- `POST /speak` — pluggable TTS (`VOICE_TTS_BACKEND`); `voice` = catalog id
- `GET /voices` / `POST /voices` / `DELETE /voices?id=ref:…` — list / import / remove clone WAVs
- `GET /health` — readiness + active backend

Listens on `127.0.0.1:8765`. Flutter starts this via `VoiceRuntimeService` when the user taps the mic.

## TTS backends (`voice_runtime/tts/`)

| `VOICE_TTS_BACKEND` | Engine | Notes |
|---------------------|--------|--------|
| `kokoro` | Kokoro ONNX | **Named fallback** — current fast stack |
| `chatterbox_nano` | Chatterbox Nano | **Trial default** — expressive tags (`[chuckle]`, …) |
| `chatterbox_turbo` | Chatterbox Turbo | Same API, larger |
| `chatterbox_mtl_v3` | Chatterbox Multilingual V3 | Pass `language_id` on `/speak` |

If the requested Chatterbox backend fails to load, the server **auto-falls back to `kokoro`** and reports `tts.fallback_used` in `/health`.

```bash
# Prefer editing voice_runtime/.env (from .env.example), or:
export VOICE_TTS_BACKEND=kokoro            # force fallback
export VOICE_TTS_BACKEND=chatterbox_nano   # trial default
export VOICE_TTS_BACKEND=chatterbox_mtl_v3
```

Config file: [`/.env.example`](.env.example) → copy to `.env` (gitignored).

## Allowed here

- Python server, `tts/` plugins, scripts, pilot bench, local model caches under `data/` (gitignored)

## Do not

- Remove the `kokoro` backend
- Reintroduce Docker Fish / inbox-outbox orchestration
- Commit Whisper/Kokoro/Chatterbox weights or large caches
- Bind to `0.0.0.0` without an explicit security review
- Hardcode English filler word lists as “emotion”
