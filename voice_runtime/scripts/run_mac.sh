#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export PATH="${HOME}/.local/bin:/opt/homebrew/bin:${PATH}"

# shellcheck disable=SC1091
source "$ROOT/scripts/lib/load_dotenv.sh"
_load_dotenv "$ROOT/.env"

export ESPEAK_DATA_PATH="${ESPEAK_DATA_PATH:-/opt/homebrew/share/espeak-ng-data}"
export PHONEMIZER_ESPEAK_PATH="${PHONEMIZER_ESPEAK_PATH:-/opt/homebrew/bin/espeak-ng}"
export VOICE_RUNTIME_HOST="${VOICE_RUNTIME_HOST:-127.0.0.1}"
export VOICE_RUNTIME_PORT="${VOICE_RUNTIME_PORT:-8765}"
export VOICE_TTS_BACKEND="${VOICE_TTS_BACKEND:-chatterbox_nano}"
# shellcheck disable=SC1091
source .venv/bin/activate
exec python server.py
