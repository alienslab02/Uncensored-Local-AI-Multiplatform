import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Platform-aware root for all local app data.
///
/// | Platform | Root |
/// |----------|------|
/// | macOS / Linux | `~/.uncensored-ai/` |
/// | Windows | `%USERPROFILE%\.uncensored-ai\` |
/// | iOS / Android | `<app support>/uncensored-ai/` (sandbox) |
///
/// Layout under that root:
/// ```
/// hive/     # Hive boxes (chats, settings)
/// models/   # GGUF weights
/// voice/    # temp STT/TTS audio
/// logs/
/// cache/
/// ```
class AppPaths {
  AppPaths._();

  static Directory? _root;
  static bool _ready = false;

  static bool get isDesktop =>
      !kIsWeb &&
      (Platform.isMacOS || Platform.isLinux || Platform.isWindows);

  static Future<Directory> ensureInitialized() async {
    if (_ready && _root != null) return _root!;

    _root = Directory(await _resolveRootPath());

    for (final sub in [
      'hive',
      'models',
      'voice',
      'voice/references',
      'logs',
      'cache',
    ]) {
      await Directory(p.join(_root!.path, sub)).create(recursive: true);
    }

    // Legacy Documents migration is desktop-only (mobile never used that layout).
    if (isDesktop) {
      await _migrateFromLegacyDesktopLocations();
    }

    _ready = true;
    return _root!;
  }

  static Future<String> _resolveRootPath() async {
    if (kIsWeb) {
      // Web has no durable FS like desktop; keep a temp root for structure.
      return p.join(Directory.systemTemp.path, 'uncensored-ai');
    }

    if (Platform.isAndroid || Platform.isIOS) {
      // Sandboxed app support dir — the correct mobile equivalent of ~/.app
      final support = await getApplicationSupportDirectory();
      return p.join(support.path, 'uncensored-ai');
    }

    // Desktop: stable user-home folder (not Documents)
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'];
    if (home != null && home.isNotEmpty) {
      return p.join(home, '.uncensored-ai');
    }

    // Last resort
    final support = await getApplicationSupportDirectory();
    return p.join(support.path, 'uncensored-ai');
  }

  static String get root {
    if (_root == null) {
      throw StateError('AppPaths.ensureInitialized() must be called first');
    }
    return _root!.path;
  }

  static String get hiveDir => p.join(root, 'hive');
  static String get modelsDir => p.join(root, 'models');
  static String get voiceDir => p.join(root, 'voice');
  /// Custom Chatterbox clone WAVs (`ref:<stem>` catalog ids).
  static String get voiceReferencesDir => p.join(root, 'voice', 'references');
  static String get logsDir => p.join(root, 'logs');
  static String get cacheDir => p.join(root, 'cache');

  /// One-time move of old desktop Documents/PortableAI + Hive files.
  static Future<void> _migrateFromLegacyDesktopLocations() async {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'];
    if (home == null) return;

    final legacyModels = Directory(
      p.join(home, 'Documents', 'PortableAI', 'models'),
    );
    await _moveChildrenIfNeeded(legacyModels, Directory(modelsDir));

    final legacyModels2 = Directory(
      p.join(home, 'Documents', 'portable_ai_flutter', 'PortableAI', 'models'),
    );
    await _moveChildrenIfNeeded(legacyModels2, Directory(modelsDir));

    // Flutter desktop sometimes used application documents as Hive root.
    try {
      final appDocs = await getApplicationDocumentsDirectory();
      await _migrateHiveFilesFrom(appDocs);
    } catch (_) {}

    final legacyDocRoots = [
      Directory(p.join(home, 'Documents')),
      Directory(p.join(home, 'Documents', 'portable_ai_flutter')),
    ];
    for (final doc in legacyDocRoots) {
      await _migrateHiveFilesFrom(doc);
    }

    for (final d in [
      Directory(p.join(home, 'Documents', 'PortableAI', 'models')),
      Directory(p.join(home, 'Documents', 'PortableAI')),
    ]) {
      try {
        if (await d.exists()) {
          final empty = !await d.list().any((_) => true);
          if (empty) await d.delete();
        }
      } catch (_) {}
    }
  }

  static Future<void> _migrateHiveFilesFrom(Directory doc) async {
    if (!await doc.exists()) return;
    const hiveNames = [
      'chats.hive',
      'chats.lock',
      'settings.hive',
      'settings.lock',
      'models_meta.hive',
      'models_meta.lock',
    ];
    for (final name in hiveNames) {
      final src = File(p.join(doc.path, name));
      final dest = File(p.join(hiveDir, name));
      if (await src.exists() && !await dest.exists()) {
        try {
          await src.rename(dest.path);
        } catch (_) {
          try {
            await src.copy(dest.path);
            await src.delete();
          } catch (_) {}
        }
      }
    }
  }

  static Future<void> _moveChildrenIfNeeded(
    Directory from,
    Directory to,
  ) async {
    if (!await from.exists()) return;
    await to.create(recursive: true);
    await for (final entity in from.list(followLinks: false)) {
      if (entity is! File) continue;
      final dest = File(p.join(to.path, p.basename(entity.path)));
      if (await dest.exists()) continue;
      try {
        await entity.rename(dest.path);
      } catch (_) {
        try {
          await entity.copy(dest.path);
          await entity.delete();
        } catch (_) {}
      }
    }
  }
}
