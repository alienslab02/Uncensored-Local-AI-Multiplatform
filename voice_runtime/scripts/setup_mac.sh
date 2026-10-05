#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

export PATH="${HOME}/.local/bin:/opt/homebrew/bin:${PATH}"

if ! command -v uv >/dev/null 2>&1; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="${HOME}/.local/bin:${PATH}"
fi

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew required for espeak-ng on macOS" >&2
  exit 1
fi
brew list espeak-ng >/dev/null 2>&1 || brew install espeak-ng

uv venv --python 3.12 .venv
# shellcheck disable=SC1091
source .venv/bin/activate
uv pip install -r requirements.txt

# Expressive TTS (Nano/Turbo/Multilingual). Optional — Kokoro remains fallback.
if [[ "${VOICE_INSTALL_CHATTERBOX:-1}" != "0" ]]; then
  echo "Installing chatterbox-tts (large; set VOICE_INSTALL_CHATTERBOX=0 to skip)…"
  uv pip install -r requirements-chatterbox.txt || {
    echo "WARN: chatterbox install failed — Kokoro fallback still available" >&2
  }
fi

mkdir -p data/kokoro data/whisper data/references
MODEL="data/kokoro/kokoro-v1.0.onnx"
VOICES="data/kokoro/voices-v1.0.bin"
BASE="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0"
if [[ ! -f "$MODEL" ]]; then
  curl -L "$BASE/kokoro-v1.0.onnx" -o "$MODEL"
fi
if [[ ! -f "$VOICES" ]]; then
  curl -L "$BASE/voices-v1.0.bin" -o "$VOICES"
fi

echo "Setup OK."
echo "  TTS backend: export VOICE_TTS_BACKEND=chatterbox_nano|chatterbox_turbo|chatterbox_mtl_v3|kokoro"
echo "  Start with: ./scripts/run_mac.sh"
