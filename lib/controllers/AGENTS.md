# lib/controllers/ — GetX controllers

## Purpose

Glue UI ↔ services: chat list, model selection/downloads, theme. Controllers orchestrate; services execute.

## Files that belong here

- `*_controller.dart` only

## Rules

1. Depend on services via `Get.find`, not global singletons.
2. Keep heavy I/O in services; controllers coordinate and expose `.obs` state.
3. Chat generation flow stays in `ChatController`. Voice hold-to-talk is `VoiceChatController` (Right ⌥ / mic press-release).
4. Don’t import platform UI themes deeply; use `Get.snackbar` patterns already in the app.
5. New controller → register in `AppBindings` + mention in this file’s mental model.
