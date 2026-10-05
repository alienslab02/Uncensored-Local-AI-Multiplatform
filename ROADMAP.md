# Project roadmap — Uncensored Local AI

Source of truth for product direction. Update this when scope changes.

## Shipped

| Item | Notes |
|------|--------|
| On-device GGUF chat (Flutter + llamadart) | Android / iOS / desktop |
| Model library download + import | Catalog + custom files |
| Persistent chats (Hive) | Local only |
| Local OpenAI-compatible API `:4891` | Desktop / when enabled |
| **Mode V voice chat (macOS)** | In-app PTT → `voice_runtime` (Whisper + Kokoro) → Gemma stream → speak |
| Unified local data root | Platform-aware `AppPaths` (see below) |

## Local data layout (all platforms)

Same subfolders everywhere; **root path differs by OS**:

| Platform | Root |
|----------|------|
| macOS / Linux | `~/.uncensored-ai/` |
| Windows | `%USERPROFILE%\.uncensored-ai\` |
| iOS / Android | `<ApplicationSupport>/uncensored-ai/` (sandbox) |

| Subdir | Purpose |
|--------|---------|
| `hive/` | Chats + settings |
| `models/` | GGUF weights |
| `voice/` | Temp STT/TTS audio |
| `logs/`, `cache/` | Reserved |

Do **not** store app data under `~/Documents` (legacy desktop paths are migrated once into the new root).

## Voice strategy

| Mode | Status | Stack |
|------|--------|--------|
| **Mode V** | **Current product path** | Flutter mic UI + host `voice_runtime/` (faster-whisper + **pluggable TTS**) on `127.0.0.1:8765` |
| TTS trial | **In progress** | Default trial: Chatterbox Nano (expressive); **Kokoro** remains named fallback (`VOICE_TTS_BACKEND=kokoro`) |
| TTS next | Planned | Chatterbox Multilingual V3 via same registry |
| Mode C (Docker Fish) | **Removed** | Former `voice_services/` — discarded (too slow on Apple Silicon CPU) |

### Explicit platform scope for voice

| Platform | Voice chat |
|----------|------------|
| **macOS** | Supported (Mode V) — auto-start sidecar from mic button |
| Windows / Linux | Planned — same architecture, host runtime packaging TBD |
| Android / iOS | **Not Mode V yet** — text chat + local models only; on-device STT/TTS later |
| Cloud voice (Gemini Live, Fish cloud, etc.) | Out of scope unless explicitly requested |

## Near-term

- [ ] Harden Mode V UX (permissions, errors, first-run) on macOS
- [ ] Package / document one-command voice runtime install for end users
- [ ] Windows / Linux Mode V parity
- [ ] Mobile voice (on-device STT/TTS; no Docker Fish)

## Later

- [ ] AI agent mode
- [ ] Web search (optional, user-controlled)
- [ ] Image / vision models
- [ ] Voice cloning / custom voices (optional; Kokoro presets first)

## Not doing

- Docker Fish Speech as the product voice path
- Requiring cloud LLM/TTS for core chat or voice
- Scattering Hive/models under `~/Documents`
