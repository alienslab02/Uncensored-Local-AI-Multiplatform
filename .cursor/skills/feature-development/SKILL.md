---
name: feature-development
description: >-
  Build vertical features and fix bugs in Uncensored Local AI using existing
  GetX/Hive/Flutter layering, DI, theme, logging, and local-first constraints.
  Use when adding a feature, implementing a vertical slice, fixing a bug,
  refactoring app code, or extending voice_runtime / local OpenAI API.
---

# Feature development (this repo)

Before coding, read root [AGENTS.md](../../../AGENTS.md), [RULES.md](../../../RULES.md),
[ROADMAP.md](../../../ROADMAP.md), and the nested `AGENTS.md` in every folder you will touch.
For system shape, skim [ARCHITECTURE.md](../../../ARCHITECTURE.md).

## Mental model (do not invent a parallel stack)

| Layer | Path | Owns |
|-------|------|------|
| DI | `lib/bindings/app_bindings.dart` | `Get.lazyPut` / `Get.put` registration |
| Boot | `lib/screens/splash_screen.dart` | Ordered `service.init()` |
| Services | `lib/services/` | I/O, engines, Hive, HTTP — **no widgets** |
| Controllers | `lib/controllers/` | Orchestration + `.obs` / `ever` — thin |
| Screens | `lib/screens/` | Pages / tabs |
| Widgets | `lib/widgets/` | Reusable UI |
| Models | `lib/models/` | Data + Hive adapters (`*.g.dart` generated) |
| Theme | `lib/theme/` | `AppColors` + `BuildContext` extensions (`context.bg`, `context.text`, …) |
| Paths | `lib/services/app_paths.dart` | `~/.uncensored-ai` (desktop) / app support (mobile) |
| Voice BE | `voice_runtime/` | Host Whisper + pluggable TTS on `:8765` (macOS Mode V) |

**Local-first:** GGUF chat must work offline. Voice is Mode V (`voice_runtime/`) — pluggable TTS (`kokoro` fallback, Chatterbox trial). No Docker Fish / Gemini Live / cloud TTS unless the user explicitly asks.

---

## Workflow A — New vertical (feature slice)

Work **outside-in** but register **inside-out**:

### 1. Scope check

- Smallest slice that ships value (one user-visible path).
- Prefer extending an existing service/controller over a second parallel API.
- If the feature is voice: change `voice_runtime/` and/or Flutter voice services; respect [ROADMAP.md](../../../ROADMAP.md) platform scope (Mode V = macOS first).
- If it touches OpenAI local API: keep `/v1/models` and `/v1/chat/completions` (+ streaming) compatible.

### 2. Data / persistence (if needed)

- Add/extend model in `lib/models/` (Hive: regenerate with build_runner — **never hand-edit `*.g.dart`**).
- Persist settings via `ChatStorageService` getters/setters on the `settings` box (same pattern as `localApiServerPort`).
- All new files under AppPaths roots — not ad-hoc Documents folders.
- Catalog models: update `assets/models_catalog.json` + `AiModelInfo` schema alignment; register assets in `pubspec.yaml` if new files.

### 3. Service

- Create `lib/services/<name>_service.dart` extending `GetxService` when it is app-wide infrastructure.
- Expose reactive fields with `.obs` when UI must listen.
- Use `LogService` with `source:` labels; tolerate missing log with `try { Get.find... } catch (_) {}` like `ModelController`.
- Async setup: implement `Future<T> init() async` and call it from **SplashScreen** in a clear order (after storage if it needs Hive).

### 4. Controller

- `GetxController` + `Get.find<Service>()`.
- Orchestrate only; don’t bury HTTP/FS here if a service already owns it.
- Mirror progress with `ever(service.progress, ...)`.
- User feedback: `Get.snackbar(..., snackPosition: SnackPosition.BOTTOM)` for success/failure.

### 5. DI

In `AppBindings.dependencies()`:

```dart
Get.lazyPut(() => MyService(), fenix: true);
Get.lazyPut(() => MyController(), fenix: true);
```

Use immediate `Get.put` only when needed before first frame (see `ThemeController`).

### 6. UI

- Screens use `Obx` / controller fields; reuse `context.bg`, `context.text`, `context.textM`, `AppColors.accent`, existing card/list patterns from Settings/Home.
- Extract to `lib/widgets/` when reused across screens.
- Support embedded vs full-screen patterns (`SettingsScreen(embedded: true)`) when adding tab content.
- Don’t invent a new palette or a second state-management library.

### 7. Routes (if new page)

- Add to `lib/routes/app_routes.dart` and navigate with `Get.toNamed` / `Get.offAllNamed`.

### 8. Tests

- Prefer service/unit tests under `test/` with temp Hive dir + `Get.put` / `Get.reset()` (see `local_api_server_service_test.dart`).
- Don’t require real `.gguf` or GPU in unit tests.

### 9. Docs for AI/humans

- Update nested `AGENTS.md` if a folder gains a new responsibility.
- Update `ARCHITECTURE.md` / `ROADMAP.md` for new ports, services, or platform scope.

### 10. Verify

- `flutter analyze` on touched Dart when practical.
- Manual path: load model → exercise feature → check Local API / voice health if you touched them.

---

## Workflow B — Bug fix

1. **Reproduce** with the smallest path (UI action, API curl, or voice_runtime log).
2. **Locate layer:** UI symptom ≠ always UI bug — check controller state, then service, then platform/entitlements.
3. **Match existing error style:** snackbars for user; `LogService.error`; avoid swallowing without log.
4. **Fix at the owning layer** (e.g. path issues in `AppPaths` / `ModelManager`, not a random widget hack).
5. **Regression:** add or extend a test when the bug is logic/API shaped.
6. **Don’t** drive-by refactor unrelated files or “clean up” theme/architecture while fixing.

### Common failure zones

| Symptom | Check first |
|---------|-------------|
| Model not found / can’t download | `AppPaths.modelsDir`, macOS sandbox/entitlements, network client entitlement |
| Chat “Error: …” | `LlmService` load state, `ChatController.sendMessage` stream, stop tokens cleanup |
| Local API 503 / empty models | Model loaded? Server enabled? Port bind? `LocalApiServerService` |
| Voice silent / slow | `VoiceRuntimeService` / `:8765` health, mic permission, AppPaths `voice/`, Kokoro RTF |
| State lost after restart | Hive under AppPaths `hive/`, `ChatStorageService` keys |

---

## Coding practices already used (match these)

- **GetX everywhere** for DI and reactivity (`Obx`, `.obs`, `RxnString`, `fenix: true`).
- **Section banners** in files: `// ── Foo ──`.
- **Nullable LogService** lookup so logging never crashes init.
- **Splash-ordered init** for services that need async setup.
- **Theme via extensions** on `BuildContext`, not hard-coded greys (except inside `AppColors`).
- **OpenAI local surface** as the stable integration point for external tools.
- **Smallest diff**; no new markdown docs unless asked (except maintaining AGENTS/ARCHITECTURE/ROADMAP/skills).

## Explicit don’ts

- No Riverpod/Bloc/Provider alongside GetX.
- No cloud LLM/voice as default path.
- No resurrecting Docker Fish / `voice_services/`.
- No committing `.gguf`, Whisper/Kokoro caches, secrets, temp wavs.
- No hand-edited Hive `*.g.dart`.
- No shipping Mode V voice UI as “supported” on Windows/Linux/mobile until roadmap says so.

## Progressive detail

- Layer examples and file checklist: [reference.md](reference.md)
