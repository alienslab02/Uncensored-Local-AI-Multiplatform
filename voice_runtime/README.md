# Voice runtime (Mode V)

Local **Whisper + pluggable TTS** HTTP sidecar for in-app voice chat. Runs on the Mac host, not Docker.

## TTS backends

| `VOICE_TTS_BACKEND` | Notes |
|---------------------|--------|
| `chatterbox_nano` | Trial default — expressive tags (`[chuckle]`, …) |
| `chatterbox_turbo` | Faster/larger Turbo variant |
| `chatterbox_mtl_v3` | Multilingual V3 — pass `language_id` |
| `kokoro` | Named fallback (Kokoro ONNX) |

**Switch easily**

1. **App UI:** Settings → Voice TTS → tap an engine (restarts sidecar).
2. **`.env` file:** copy [`/.env.example`](.env.example) → `voice_runtime/.env` and set `VOICE_TTS_BACKEND=…`  
   (loaded by `scripts/run_mac.sh` / `ensure_running.sh`; does not override vars already set).
3. **Shell export:** `export VOICE_TTS_BACKEND=kokoro` (highest priority when launching).
4. Failed Chatterbox load → automatic Kokoro fallback (`tts.fallback_used` in `/health`).

Precedence when starting the sidecar: shell/Flutter-passed env → `voice_runtime/.env` → script defaults.

## Setup (once)

```bash
cd voice_runtime
chmod +x scripts/*.sh
cp -n .env.example .env   # edit VOICE_TTS_BACKEND here
./scripts/setup_mac.sh
# Skip Chatterbox (Kokoro only): VOICE_INSTALL_CHATTERBOX=0 ./scripts/setup_mac.sh
```

Needs: Homebrew (`espeak-ng`), `uv`, Python 3.12.

**Prefer the repo one-liner** (voice + Flutter UI + auto model/API):

```bash
# from repo root
./scripts/dev_mac.sh
```

## Run (voice only)

```bash
export VOICE_TTS_BACKEND=chatterbox_nano   # or edit .env
./scripts/run_mac.sh
curl -s http://127.0.0.1:8765/health
```

## Smoke

```bash
# TTS
curl -s -X POST http://127.0.0.1:8765/speak \
  -H 'Content-Type: application/json' \
  -d '{"text":"Sure [chuckle], that works.","voice":"af_heart"}' \
  --output /tmp/vb_speak.wav && afplay /tmp/vb_speak.wav

# STT (use any 16 kHz wav; pilot TTS output works)
curl -s -X POST http://127.0.0.1:8765/transcribe \
  -F "audio=@pilot/out/kokoro_pilot.wav"
```

## Pilot bench

```bash
source .venv/bin/activate
python pilot/bench_tts_backends.py
```
