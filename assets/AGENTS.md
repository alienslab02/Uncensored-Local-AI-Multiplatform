# assets/ — Bundled app assets

## Purpose

Files shipped inside the Flutter asset bundle.

## Belong here

- `models_catalog.json` and other small static assets
- Images/fonts if added later via `pubspec.yaml`

## Rules

1. Register new assets in `pubspec.yaml` `flutter: assets:`.
2. Keep catalog JSON schema compatible with `AiModelInfo`.
3. Never put `.gguf` model weights in assets (too large; download at runtime).
4. Prefer marking the user’s chosen default model with `"recommended": true` carefully (one primary).
