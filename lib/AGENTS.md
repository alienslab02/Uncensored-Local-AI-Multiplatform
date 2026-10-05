# lib/ — Flutter application code

## Purpose

All Dart application logic and UI live here. Platform runners (`android/`, `ios/`, …) only host the engine.

## Allowed here

- `main.dart`, feature folders (`services`, `controllers`, `screens`, `widgets`, `models`, `theme`, `routes`, `bindings`)
- Feature-specific private helpers next to their feature

## Not allowed here

- Native platform projects, Gradle/Xcode files
- Host voice runtime Python (that goes in `voice_runtime/`)
- Checked-in model weights

## Rules

1. Read the nested `AGENTS.md` in the subfolder you edit.
2. Keep UI out of services; keep HTTP/FS out of widgets when a service already owns it.
3. New top-level lib folders need an `AGENTS.md` and a root `AGENTS.md` link update.
4. Prefer extending existing services over parallel duplicates (e.g. don’t add a second LLM wrapper).
