# AGENTS.md — Uncensored Local AI Multiplatform

This file is the entry point for AI coding agents. Read it before changing code.

## What this project is

Flutter multi-platform app that runs **local GGUF LLMs** (llama.cpp via `llamadart`) with **no cloud LLM dependency**. Optional Local OpenAI-compatible API on `127.0.0.1:4891`. Voice (Mode V) is **local-only**: in-app push-to-talk → host `voice_runtime` (Whisper + Kokoro on `:8765`) → streamed Gemma → spoken reply.

## Source of truth docs (load these)

| Doc | Purpose |
|-----|---------|
| [RULES.md](RULES.md) | Hard rules, security, do/don't |
| [ARCHITECTURE.md](ARCHITECTURE.md) | System design, data flow, ports |
| [ROADMAP.md](ROADMAP.md) | Product direction, voice/platform scope, data roots |
| Nested `AGENTS.md` | Per-folder purpose, allowed files, conventions |
| `.cursor/rules/*.mdc` | Cursor-applied rules (always / by glob) |
| [.cursor/skills/feature-development/SKILL.md](.cursor/skills/feature-development/SKILL.md) | How to build a vertical or fix bugs (Cursor discovers `.cursor/skills/`; mirrored at `.agents/skills/`) |

## Nested agent guides

- [lib/AGENTS.md](lib/AGENTS.md)
- [lib/services/AGENTS.md](lib/services/AGENTS.md)
- [lib/controllers/AGENTS.md](lib/controllers/AGENTS.md)
- [lib/screens/AGENTS.md](lib/screens/AGENTS.md)
- [lib/widgets/AGENTS.md](lib/widgets/AGENTS.md)
- [lib/models/AGENTS.md](lib/models/AGENTS.md)
- [voice_runtime/AGENTS.md](voice_runtime/AGENTS.md) — Mode V host STT/TTS (macOS)
- [test/AGENTS.md](test/AGENTS.md)
- [assets/AGENTS.md](assets/AGENTS.md)
- [macos/AGENTS.md](macos/AGENTS.md) (and siblings under `android/`, `ios/`, `linux/`, `windows/`, `web/`)
- [.github/AGENTS.md](.github/AGENTS.md)

## Stack

- **UI:** Flutter + GetX (`GetxController`, `Obx`, DI via `AppBindings`)
- **Storage:** Hive (`ChatStorageService`)
- **LLM:** `LlmService` → `llamadart`
- **Local API:** `LocalApiServerService` OpenAI-style `/v1/*`
- **Voice BE:** `voice_runtime/` host FastAPI (Whisper + pluggable TTS: Chatterbox Nano trial / Kokoro fallback); macOS Mode V (see [ROADMAP.md](ROADMAP.md))

## Default working style for agents

1. For new features or bugfixes, follow [.cursor/skills/feature-development/SKILL.md](.cursor/skills/feature-development/SKILL.md).
2. Prefer smallest change that solves the task.
3. Match existing patterns in the touched folder’s `AGENTS.md`.
4. Do not add cloud voice/LLM (Gemini Live, Fish Audio cloud, OpenAI cloud) unless the user explicitly asks.
5. Do not commit secrets, API keys, or large model binaries.
6. Voice product work goes in `voice_runtime/` + Flutter PTT. Do not reintroduce Docker Fish.
7. After substantive Dart edits, keep analysis clean (`flutter analyze` on touched scope when practical).

## How to run (quick)

```bash
# App only — splash auto-loads GGUF + Local API :4891 and warm-starts voice :8765 (macOS)
flutter run -d macos

# Optional helper (same UX; also ensures voice setup / .env first)
./scripts/dev_mac.sh

# Run voice sidecar alone (no UI)
cd voice_runtime && ./scripts/ensure_running.sh   # or ./scripts/run_mac.sh

# TTS: Settings → Voice TTS, or voice_runtime/.env / VOICE_TTS_BACKEND=
```

## Ports

| Service | Port | Where |
|---------|------|--------|
| Local OpenAI API | `4891` | Host (Flutter) |
| Voice runtime STT/TTS | `8765` | Host (`voice_runtime`) |
