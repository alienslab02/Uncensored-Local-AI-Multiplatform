# feature-development — reference

Read only when you need concrete file-level patterns.

## Vertical checklist (copy)

```
[ ] Nested AGENTS.md read for touched folders
[ ] Model / Hive / settings keys (if any)
[ ] Service + init() + Splash registration (if async)
[ ] Controller + Obx UI
[ ] AppBindings lazyPut/put
[ ] Routes (if new screen)
[ ] theme: context.* / AppColors
[ ] LogService + snackbars
[ ] test/ for logic or API
[ ] ARCHITECTURE / AGENTS updated if ports or layers changed
[ ] flutter analyze (touched scope)
```

## AppBindings pattern

```dart
Get.lazyPut(() => NewService(), fenix: true);
Get.lazyPut(() => NewController(), fenix: true);
// ThemeController uses Get.put — needed immediately
```

## Splash init order (extend carefully)

Current order in `splash_screen.dart`:

1. `LogService.init()`
2. `ChatStorageService.init()`
3. `ModelManager.init()`
4. `LlmService.init()`
5. `LocalApiServerService.init()`
6. `WakelockService.init()`

Insert new inits **after** their dependencies (storage before anything Hive-backed).

## Settings persistence pattern

```dart
// ChatStorageService
bool get myFlag =>
    _settingsBox.get('my_flag', defaultValue: false) as bool;
set myFlag(bool value) => _settingsBox.put('my_flag', value);
```

## Controller ↔ service progress

```dart
ever(_llm.loadingProgress, (double progress) {
  loadingProgress.value = progress;
});
```

## UI theme usage

```dart
Scaffold(
  backgroundColor: context.bg,
  body: Text('Hi', style: TextStyle(color: context.text)),
);
// Accent actions: AppColors.accent / AppColors.accentGradient
```

## Local API smoke (host)

```bash
curl -s http://127.0.0.1:4891/healthz
curl -s http://127.0.0.1:4891/v1/models
curl -s http://127.0.0.1:4891/v1/chat/completions \
  -H "Authorization: Bearer local" \
  -H "Content-Type: application/json" \
  -d '{"model":"local","messages":[{"role":"user","content":"hi"}]}'
```

## Voice (Mode V) touchpoints

- Runtime: `voice_runtime/` (Whisper + pluggable TTS on `:8765`)
- TTS plugins: `voice_runtime/tts/` — `VOICE_TTS_BACKEND=chatterbox_nano|kokoro|chatterbox_mtl_v3|…`
- Flutter: `VoiceRuntimeService`, `VoiceChatController`, `VoicePttButton`
- Data: AppPaths `voice/` under `~/.uncensored-ai` (desktop)
- Scope: macOS-first — see [ROADMAP.md](../../../ROADMAP.md)

## Hive codegen

```bash
dart run build_runner build --delete-conflicting-outputs
```

## Example “good” feature split (Local API Server)

Already shipped vertical — mirror this shape:

| Piece | File |
|-------|------|
| Service | `lib/services/local_api_server_service.dart` |
| Settings UI | `lib/screens/settings_screen.dart` + `api_endpoints_screen.dart` |
| Persistence | `ChatStorageService` local_api_* keys |
| Boot | Splash `LocalApiServerService.init()` |
| Test | `test/local_api_server_service_test.dart` |

## Example bug triage

**Download fails on macOS** → network entitlement + URL + disk path in `ModelManager`, not HomeScreen button styling.

**Snackbar “Download Failed”** → read `ModelController.downloadModel` catch + `LogService` source `Download`.
