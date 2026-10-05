# lib/models/ — Data models

## Purpose

Serializable domain types: chats, messages, catalog entries, download state. Hive type adapters live here.

## Files that belong here

- Plain Dart model classes
- `*.g.dart` Hive generated files (do not hand-edit)

## Rules

1. After changing `@HiveType` / fields, run `dart run build_runner build --delete-conflicting-outputs`.
2. Keep JSON `fromJson`/`toJson` aligned with `assets/models_catalog.json` for catalog models.
3. No Flutter widget imports in models.
4. Message roles must stay compatible with LLM history mapping (`toLlamaMessage`).
