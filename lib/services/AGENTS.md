# lib/services/ — Domain & infrastructure services

## Purpose

Side-effectful, UI-free modules: LLM engine, model download, Hive storage, local HTTP API, logging, wakelock, etc.

## Files that belong here

- `*_service.dart`, managers used as GetX services (e.g. `model_manager.dart`)
- No widgets, no `BuildContext` for navigation (snackbars only if already patterned)

## Rules

1. Register new services in [`../bindings/app_bindings.dart`](../bindings/app_bindings.dart) with `fenix: true` when appropriate.
2. Expose reactive state via GetX `.obs` when controllers/UI must observe it.
3. **`LocalApiServerService`:** preserve OpenAI-compatible `/v1/models` and `/v1/chat/completions` behavior; document breaking changes in ARCHITECTURE.md.
4. **`LlmService`:** lifecycle (load/cancel/unload/generate/stop) stays centralized.
5. Prefer `LogService` for user-visible diagnostics over bare `print` (debugPrint OK for crash paths).
6. Mode V: `VoiceRuntimeService.ensureRunning()` warm-starts host `voice_runtime/` from Splash (macOS). Sidecar can still be run alone via `voice_runtime/scripts/`.

## Testing

Unit-test pure logic against fakes; HTTP server tests live under `test/` (see existing `local_api_server_service_test.dart`).
