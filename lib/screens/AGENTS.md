# lib/screens/ — Full-screen / tab pages

## Purpose

Top-level UI: home chat, model library, settings, splash, logs, API docs screen.

## Files that belong here

- `*_screen.dart` page widgets
- Large screen-private widgets may start here; extract to `lib/widgets/` when reused

## Rules

1. Use existing theme helpers (`context.bg`, `AppColors`, etc.) — don’t invent a parallel palette.
2. Prefer `Obx` / controller fields over local mirrored state.
3. Settings toggles that persist must go through `ChatStorageService` (or the owning service).
4. Voice: Settings → Voice TTS selects `VOICE_TTS_BACKEND` (persisted); mic PTT lives on Home.
5. Keep desktop and mobile layouts coherent with existing breakpoints in `home_screen.dart`.
