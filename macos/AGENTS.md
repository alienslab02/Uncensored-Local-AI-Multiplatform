# macos/ — macOS runner

## Purpose

Xcode project hosting the Flutter macOS embedder.

## Rules

1. Entitlements (`DebugProfile.entitlements`, `Release.entitlements`) control sandbox, network, mic.
2. Don’t re-enable App Sandbox without verifying `~/Documents/PortableAI/models` access.
3. Mic for Phase 2 Flutter voice needs `com.apple.security.device.audio-input`.
4. Avoid editing `Flutter/ephemeral/` — generated.
5. Prefer `flutter run -d macos` / `flutter build macos` over hand-tuning pbxproj unless required.
