#!/usr/bin/env bash
# One-command macOS Mode V launch:
#   voice_runtime (:8765) → Flutter UI (auto-loads GGUF + Local API :4891)
#
# Usage (from repo root):
#   ./scripts/dev_mac.sh
#
# Options via env:
#   VOICE_TTS_BACKEND=kokoro ./scripts/dev_mac.sh
#   DEV_MAC_SKIP_VOICE=1     # UI only
#   DEV_MAC_SETUP=1          # force voice_runtime/scripts/setup_mac.sh first

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

export PATH="${HOME}/flutter/bin:${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"

die() { echo "ERROR: $*" >&2; exit 1; }

command -v flutter >/dev/null 2>&1 || die "flutter not on PATH (install SDK or add \$HOME/flutter/bin)"

# ── Voice runtime ──────────────────────────────────────────────
VOICE_DIR="$ROOT/voice_runtime"
if [[ "${DEV_MAC_SKIP_VOICE:-0}" != "1" ]]; then
  [[ -d "$VOICE_DIR" ]] || die "missing $VOICE_DIR"

  if [[ ! -f "$VOICE_DIR/.env" && -f "$VOICE_DIR/.env.example" ]]; then
    cp "$VOICE_DIR/.env.example" "$VOICE_DIR/.env"
    echo "Created voice_runtime/.env from .env.example (edit VOICE_TTS_BACKEND there)"
  fi

  # Optional full setup (venv + kokoro assets + chatterbox)
  if [[ "${DEV_MAC_SETUP:-0}" == "1" ]] \
    || [[ ! -x "$VOICE_DIR/.venv/bin/python" ]] \
    || [[ ! -f "$VOICE_DIR/data/kokoro/kokoro-v1.0.onnx" ]]; then
    echo "→ voice_runtime setup (first run / DEV_MAC_SETUP=1)…"
    chmod +x "$VOICE_DIR/scripts/"*.sh "$VOICE_DIR/scripts/lib/"*.sh 2>/dev/null || true
    "$VOICE_DIR/scripts/setup_mac.sh"
  fi

  chmod +x "$VOICE_DIR/scripts/ensure_running.sh" "$VOICE_DIR/scripts/lib/load_dotenv.sh" 2>/dev/null || true
  echo "→ starting voice runtime (:8765)…"
  # Prefer .env / caller export; Flutter Settings can still override later
  (
    cd "$VOICE_DIR"
    ./scripts/ensure_running.sh
  ) || die "voice runtime failed to become healthy — see voice_runtime/pilot/out/server.log"

  echo "→ voice health:"
  curl -sS "http://127.0.0.1:8765/health" | python3 -m json.tool 2>/dev/null \
    || curl -sS "http://127.0.0.1:8765/health"
  echo
else
  echo "→ skipping voice (DEV_MAC_SKIP_VOICE=1)"
fi

# ── Flutter app ────────────────────────────────────────────────
echo "→ flutter pub get…"
flutter pub get

echo "→ launching macOS app (splash auto-loads GGUF + Local API :4891)…"
echo "   Mic uses voice at :8765. Switch TTS in Settings → Voice TTS or voice_runtime/.env"
echo

exec flutter run -d macos
