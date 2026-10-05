#!/usr/bin/env bash
# Idempotent: start voice runtime if :8765 is not healthy / wrong TTS backend.
# Safe to call from Flutter.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

export PATH="${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"

# shellcheck disable=SC1091
source "$ROOT/scripts/lib/load_dotenv.sh"
_load_dotenv "$ROOT/.env"

export ESPEAK_DATA_PATH="${ESPEAK_DATA_PATH:-/opt/homebrew/share/espeak-ng-data}"
export PHONEMIZER_ESPEAK_PATH="${PHONEMIZER_ESPEAK_PATH:-/opt/homebrew/bin/espeak-ng}"
export VOICE_RUNTIME_HOST="${VOICE_RUNTIME_HOST:-127.0.0.1}"
export VOICE_RUNTIME_PORT="${VOICE_RUNTIME_PORT:-8765}"
# Trial default: Chatterbox Nano; override via .env or export
export VOICE_TTS_BACKEND="${VOICE_TTS_BACKEND:-chatterbox_nano}"
FORCE_RESTART="${VOICE_TTS_FORCE_RESTART:-0}"

health_json() {
  curl -sf --max-time 2 "http://${VOICE_RUNTIME_HOST}:${VOICE_RUNTIME_PORT}/health" || true
}

health_ok() {
  health_json | grep -q '"ready":true'
}

backend_matches() {
  local json
  json="$(health_json)"
  [[ -n "$json" ]] || return 1
  # Prefer requested (what we asked for); active may be kokoro after auto-fallback
  echo "$json" | grep -q "\"requested\"[[:space:]]*:[[:space:]]*\"${VOICE_TTS_BACKEND}\""
}

stop_listener() {
  if command -v lsof >/dev/null 2>&1; then
    PIDS="$(lsof -tiTCP:"${VOICE_RUNTIME_PORT}" -sTCP:LISTEN 2>/dev/null || true)"
    if [[ -n "${PIDS}" ]]; then
      # shellcheck disable=SC2086
      kill ${PIDS} 2>/dev/null || true
      sleep 1
    fi
  fi
}

if [[ "$FORCE_RESTART" == "1" ]]; then
  echo "force_restart backend=${VOICE_TTS_BACKEND}"
  stop_listener
elif health_ok && backend_matches; then
  echo "already_ready backend=${VOICE_TTS_BACKEND}"
  exit 0
elif health_ok; then
  echo "restarting_for_backend=${VOICE_TTS_BACKEND}"
  stop_listener
fi

# First-time setup if needed
if [[ ! -x "$ROOT/.venv/bin/python" || ! -f "$ROOT/data/kokoro/kokoro-v1.0.onnx" ]]; then
  echo "running_setup"
  chmod +x "$ROOT/scripts/setup_mac.sh"
  "$ROOT/scripts/setup_mac.sh"
fi

mkdir -p "$ROOT/pilot/out"
# shellcheck disable=SC1091
source "$ROOT/.venv/bin/activate"

stop_listener

nohup python "$ROOT/server.py" >>"$ROOT/pilot/out/server.log" 2>&1 &
echo $! >"$ROOT/pilot/out/server.pid"
echo "started_pid=$!"

# Chatterbox first load can take several minutes (HF download)
for i in $(seq 1 300); do
  if health_ok; then
    echo "ready backend=${VOICE_TTS_BACKEND}"
    exit 0
  fi
  sleep 1
done

echo "failed_to_start" >&2
tail -40 "$ROOT/pilot/out/server.log" >&2 || true
exit 1
