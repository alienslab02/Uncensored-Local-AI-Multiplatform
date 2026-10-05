# RULES.md — Project rules for humans and AI

Violating these causes broken architecture, privacy regressions, or unmaintainable diffs.

## Hard rules

1. **Local-first.** Core chat/LLM must work offline with a loaded GGUF. Do not require cloud inference for text chat.
2. **Voice Mode V (current direction).** In-app push-to-talk via host `voice_runtime/` (Whisper + Kokoro on loopback `:8765`), **macOS first** (see [ROADMAP.md](ROADMAP.md)). No Gemini Live, no Fish Audio cloud, no Docker Fish.
3. **No secrets in git.** No API keys, tokens, or `.env` with credentials. Use `.env.example` with placeholders.
4. **No large binaries in git.** Do not commit `.gguf`, Fish checkpoints, Whisper weights, or `inbox/`/`outbox/` audio. Keep them under ignored `data/` / volume paths.
5. **Don’t expand scope.** No drive-by refactors, unrelated UI redesigns, or new markdown docs unless asked (except maintained AI context files in this set).
6. **Match existing style.** GetX DI, Hive persistence patterns, existing theme (`AppColors` / `AppTheme`). Don’t introduce a second state-management framework.
7. **OpenAI local API compatibility.** Changes to `LocalApiServerService` must stay compatible with common OpenAI client shapes for `/v1/models` and `/v1/chat/completions` (including streaming) unless versioned deliberately.
8. **Voice runtime on loopback.** `voice_runtime` binds `127.0.0.1` only. Weights stay under ignored `voice_runtime/data/`. Do not require Docker for voice chat.
9. **Latency for voice.** Prefer streaming LLM + sentence-chunk TTS over batch wav→wav. Optimize time-to-first-audio.
10. **Platform entitlements.** macOS mic/network changes must update the correct entitlements files; don’t silently re-enable App Sandbox in a way that breaks Documents model paths without documenting it.

## Coding standards (Dart / Flutter)

- Prefer clear names over cleverness; keep functions focused.
- Use `Get.find` / bindings already established; register new services in `AppBindings`.
- Controllers: reactive `.obs` / `Obx`; avoid unnecessary `setState` where GetX already drives UI.
- Services: no UI widgets; return data / throw typed errors; log via `LogService` when available.
- Don’t add `useMemo`-style premature caching; follow existing patterns.
- Generated Hive `*.g.dart`: regenerate with build_runner; don’t hand-edit.
- Tests: put under `test/`; name `*_test.dart`.

## Coding standards (voice_runtime / Python)

- Pin deps in `voice_runtime/requirements.txt`; use `uv` + Python 3.12 on macOS.
- Health endpoint required (`GET /health`).
- Prefer Kokoro sentence TTS + streaming LLM; optimize time-to-first-audio.
- Do not reintroduce a Docker Fish / `voice_services` product path.

## Security & privacy

- Default bind local API to loopback unless user enables all interfaces.
- Never log full user prompts/responses to remote services.
- Treat model files and chat Hive boxes as sensitive local data.

## PR / commit hygiene

- Only commit when the user asks.
- Don’t commit `build/`, `.dart_tool/`, model caches, or audio exchanges.
- Describe *why* in commit messages when committing.

## Explicitly out of scope unless requested

- Cloud voice (Gemini Live, ElevenLabs, Fish cloud, etc.)
- Replacing local GGUF with a hosted LLM
- App Store / Play packaging polish
- Embedding Fish/Whisper inside the Flutter binary
