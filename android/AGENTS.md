# android/ — Android runner

## Purpose

Gradle/Android host for Flutter.

## Rules

1. Keep min/target SDK consistent with Flutter template unless upgrading deliberately.
2. Permissions (mic, storage, foreground service) must match features actually used.
3. Don’t commit `local.properties` or keystores.
4. Release APKs are produced via CI/local `flutter build apk` — don’t vendor APKs in git.
