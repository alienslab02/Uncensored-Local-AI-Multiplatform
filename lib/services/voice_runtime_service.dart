import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'app_paths.dart';
import 'chat_storage_service.dart';
import 'log_service.dart';

/// One entry from `GET /voices`.
class VoiceOption {
  final String id;
  final String label;
  final String kind; // kokoro | reference
  final String? path;
  final String? backend;

  const VoiceOption({
    required this.id,
    required this.label,
    required this.kind,
    this.path,
    this.backend,
  });

  factory VoiceOption.fromJson(Map<String, dynamic> json) {
    return VoiceOption(
      id: '${json['id'] ?? ''}',
      label: '${json['label'] ?? json['id'] ?? 'Voice'}',
      kind: '${json['kind'] ?? ''}',
      path: json['path'] as String?,
      backend: json['backend'] as String?,
    );
  }

  bool get isReference => kind == 'reference';
  bool get isKokoro => kind == 'kokoro';
}

/// Client + auto-launcher for Mode V host voice runtime (`:8765`).
///
/// Mic press calls [ensureRunning]: finds `voice_runtime/`, runs
/// `scripts/ensure_running.sh` (setup if needed), waits until healthy.
/// The server is started **detached** so it stays up after the app restarts.
///
/// TTS backend resolution order:
/// 1. Process env `VOICE_TTS_BACKEND` (if set)
/// 2. Settings / Hive `voiceTtsBackend`
/// 3. Default `chatterbox_nano`
class VoiceRuntimeService extends GetxService {
  static const defaultBaseUrl = 'http://127.0.0.1:8765';
  static const defaultTtsBackend = 'chatterbox_nano';
  static const defaultTtsVoice = 'kokoro:af_heart';

  /// Selectable engines shown in Settings (must match `voice_runtime/tts`).
  static const ttsBackendOptions = <({String id, String label, String blurb})>[
    (
      id: 'chatterbox_nano',
      label: 'Chatterbox Nano',
      blurb: 'Expressive tags ([chuckle], …). Trial default. Uses clone WAVs.',
    ),
    (
      id: 'chatterbox_turbo',
      label: 'Chatterbox Turbo',
      blurb: 'Larger expressive English model. Uses clone WAVs.',
    ),
    (
      id: 'chatterbox_mtl_v3',
      label: 'Chatterbox Multilingual',
      blurb: 'Many languages; uses clone WAVs + language_id.',
    ),
    (
      id: 'kokoro',
      label: 'Kokoro (fallback)',
      blurb: 'Fast ONNX presets (Heart, Adam, …).',
    ),
  ];

  final baseUrl = defaultBaseUrl.obs;
  final isReady = false.obs;
  final lastError = ''.obs;
  final statusMessage = ''.obs;
  final isStarting = false.obs;
  final activeBackend = ''.obs;
  final requestedBackend = ''.obs;
  final fallbackUsed = false.obs;
  final voices = <VoiceOption>[].obs;
  final selectedVoiceId = ''.obs;
  final voicesLoading = false.obs;

  LogService get _log {
    try {
      return Get.find<LogService>();
    } catch (_) {
      return LogService();
    }
  }

  ChatStorageService? get _storage {
    try {
      return Get.find<ChatStorageService>();
    } catch (_) {
      return null;
    }
  }

  /// Env overrides Settings when set.
  bool get envOverridesBackend =>
      (Platform.environment['VOICE_TTS_BACKEND'] ?? '').trim().isNotEmpty;

  bool get envOverridesVoice =>
      (Platform.environment['VOICE_TTS_VOICE'] ?? '').trim().isNotEmpty;

  String get resolvedTtsBackend {
    final fromEnv = (Platform.environment['VOICE_TTS_BACKEND'] ?? '').trim();
    if (fromEnv.isNotEmpty) return fromEnv;
    final stored = (_storage?.voiceTtsBackend ?? '').trim();
    if (stored.isNotEmpty) return stored;
    return defaultTtsBackend;
  }

  String get resolvedTtsVoice {
    final fromEnv = (Platform.environment['VOICE_TTS_VOICE'] ?? '').trim();
    if (fromEnv.isNotEmpty) return fromEnv;
    final stored = (_storage?.voiceTtsVoice ?? '').trim();
    if (stored.isNotEmpty) return stored;
    // Chatterbox → prefer first reference if we already fetched catalog
    final backend = resolvedTtsBackend;
    if (backend.startsWith('chatterbox')) {
      for (final v in voices) {
        if (v.isReference) return v.id;
      }
    }
    return defaultTtsVoice;
  }

  Future<Map<String, dynamic>?> fetchHealth({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    try {
      final res =
          await http.get(Uri.parse('$baseUrl/health')).timeout(timeout);
      if (res.statusCode != 200) return null;
      return jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<bool> ping({Duration timeout = const Duration(seconds: 2)}) async {
    final json = await fetchHealth(timeout: timeout);
    if (json == null) {
      isReady.value = false;
      return false;
    }
    final ready = json['ready'] == true;
    isReady.value = ready;
    _applyHealthTts(json);
    return ready;
  }

  void _applyHealthTts(Map<String, dynamic> json) {
    final tts = json['tts'];
    if (tts is! Map) return;
    activeBackend.value = '${tts['active'] ?? tts['backend'] ?? ''}';
    requestedBackend.value = '${tts['requested'] ?? ''}';
    fallbackUsed.value = tts['fallback_used'] == true;
  }

  /// Persist [backendId] and restart the sidecar so it takes effect.
  Future<bool> applyTtsBackend(String backendId) async {
    final id = backendId.trim();
    if (id.isEmpty) return false;
    if (!envOverridesBackend) {
      _storage?.voiceTtsBackend = id;
    }
    requestedBackend.value = id;
    final ok = await ensureRunning(forceRestart: true);
    if (ok) await refreshVoices();
    return ok;
  }

  /// Persist selected catalog voice id (applied on next `/speak`).
  Future<void> applyTtsVoice(String voiceId) async {
    final id = voiceId.trim();
    if (id.isEmpty) return;
    if (!envOverridesVoice) {
      _storage?.voiceTtsVoice = id;
    }
    selectedVoiceId.value = id;
  }

  Future<List<VoiceOption>> refreshVoices() async {
    voicesLoading.value = true;
    try {
      if (!await ping()) {
        await ensureRunning();
      }
      final res = await http
          .get(Uri.parse('$baseUrl/voices'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) {
        lastError.value = 'voices ${res.statusCode}: ${res.body}';
        return voices.toList();
      }
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final list = (json['voices'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => VoiceOption.fromJson(Map<String, dynamic>.from(e)))
          .where((v) => v.id.isNotEmpty)
          .toList();
      voices.assignAll(list);

      var selected = resolvedTtsVoice;
      final ids = list.map((v) => v.id).toSet();
      if (selected.isEmpty || !ids.contains(selected)) {
        final def = '${json['default_id'] ?? ''}';
        selected = ids.contains(def)
            ? def
            : (list.isNotEmpty ? list.first.id : defaultTtsVoice);
        if (!envOverridesVoice && selected.isNotEmpty) {
          _storage?.voiceTtsVoice = selected;
        }
      }
      selectedVoiceId.value = selected;
      return list;
    } catch (e) {
      lastError.value = 'voices failed: $e';
      return voices.toList();
    } finally {
      voicesLoading.value = false;
    }
  }

  /// Remove a custom clone (`ref:…`). Kokoro presets cannot be deleted.
  Future<bool> deleteReferenceVoice(String voiceId) async {
    final id = voiceId.trim();
    if (!id.startsWith('ref:')) {
      lastError.value = 'Only custom clone voices can be removed';
      return false;
    }

    var deleted = false;
    if (await ping()) {
      try {
        final uri = Uri.parse('$baseUrl/voices').replace(
          queryParameters: {'id': id},
        );
        final res = await http
            .delete(uri)
            .timeout(const Duration(seconds: 15));
        if (res.statusCode == 200) {
          deleted = true;
        } else {
          lastError.value = 'delete ${res.statusCode}: ${res.body}';
        }
      } catch (e) {
        lastError.value = 'delete failed: $e';
      }
    }

    // Local fallback: delete file under AppPaths if API unavailable
    if (!deleted) {
      VoiceOption? match;
      for (final v in voices) {
        if (v.id == id) {
          match = v;
          break;
        }
      }
      final path = match?.path;
      if (path != null && path.isNotEmpty) {
        try {
          final f = File(path);
          if (f.existsSync()) {
            await f.delete();
            deleted = true;
          }
        } catch (e) {
          lastError.value = 'delete failed: $e';
        }
      }
    }

    if (!deleted) return false;

    if (selectedVoiceId.value == id ||
        (_storage?.voiceTtsVoice ?? '') == id) {
      selectedVoiceId.value = '';
      if (!envOverridesVoice) {
        _storage?.voiceTtsVoice = '';
      }
    }
    await refreshVoices();
    return true;
  }

  /// Copy a local WAV into the user voice library and select it.
  Future<VoiceOption?> importReferenceWav(String sourcePath) async {
    final src = File(sourcePath);
    if (!src.existsSync()) {
      lastError.value = 'File not found';
      return null;
    }
    final bytes = await src.readAsBytes();
    if (bytes.length < 1000) {
      lastError.value = 'WAV too small — use a clear sample (>5s for cloning)';
      return null;
    }

    // Prefer runtime upload so catalog stays authoritative
    if (await ping()) {
      try {
        final uri = Uri.parse('$baseUrl/voices');
        final req = http.MultipartRequest('POST', uri)
          ..files.add(
            http.MultipartFile.fromBytes(
              'audio',
              bytes,
              filename: p.basename(sourcePath),
            ),
          );
        final streamed =
            await req.send().timeout(const Duration(seconds: 30));
        final body = await streamed.stream.bytesToString();
        if (streamed.statusCode == 200) {
          final json = jsonDecode(body) as Map<String, dynamic>;
          final voiceJson = json['voice'];
          if (voiceJson is Map) {
            final opt =
                VoiceOption.fromJson(Map<String, dynamic>.from(voiceJson));
            await refreshVoices();
            await applyTtsVoice(opt.id);
            return opt;
          }
        }
      } catch (e) {
        _log.error('voice upload failed: $e', source: 'VoiceRuntime');
      }
    }

    // Local fallback into AppPaths
    try {
      await AppPaths.ensureInitialized();
      final dir = Directory(AppPaths.voiceReferencesDir);
      await dir.create(recursive: true);
      var stem = p.basenameWithoutExtension(sourcePath);
      stem = stem.replaceAll(RegExp(r'[^A-Za-z0-9_\-]+'), '_');
      var dest = File(p.join(dir.path, '$stem.wav'));
      var n = 1;
      while (dest.existsSync()) {
        dest = File(p.join(dir.path, '${stem}_$n.wav'));
        n++;
      }
      await dest.writeAsBytes(bytes);
      await refreshVoices();
      final id = 'ref:${p.basenameWithoutExtension(dest.path).toLowerCase()}';
      await applyTtsVoice(id);
      return VoiceOption(
        id: id,
        label: p.basenameWithoutExtension(dest.path),
        kind: 'reference',
        path: dest.path,
        backend: 'chatterbox',
      );
    } catch (e) {
      lastError.value = 'Import failed: $e';
      return null;
    }
  }

  /// Ensure STT/TTS sidecar is healthy. Safe to call on every mic press.
  Future<bool> ensureRunning({bool forceRestart = false}) async {
    final desired = resolvedTtsBackend;

    if (!forceRestart && await ping()) {
      final active = activeBackend.value;
      final requested = requestedBackend.value;
      final matches = requested == desired ||
          (requested.isEmpty && active == desired);
      if (matches) {
        statusMessage.value = '';
        lastError.value = '';
        return true;
      }
      _log.info(
        'TTS backend mismatch (want=$desired active=$active requested=$requested) — restarting',
        source: 'VoiceRuntime',
      );
      forceRestart = true;
    }

    if (!Platform.isMacOS) {
      lastError.value = 'Voice auto-start is macOS-only in v1';
      statusMessage.value = lastError.value;
      return false;
    }
    if (isStarting.value) {
      for (var i = 0; i < 90; i++) {
        await Future<void>.delayed(const Duration(seconds: 1));
        if (!isStarting.value) break;
        if (await ping()) return true;
      }
    }

    isStarting.value = true;
    statusMessage.value = forceRestart
        ? 'Switching voice engine to $desired…'
        : 'Starting voice…';
    lastError.value = '';

    try {
      final root = _resolveVoiceRuntimeRoot();
      if (root == null) {
        lastError.value =
            'Could not find voice_runtime/. Open the project from its repo folder once, or set path in settings.';
        statusMessage.value = lastError.value;
        _log.error(lastError.value, source: 'VoiceRuntime');
        return false;
      }

      _storage?.voiceRuntimePath = root;
      final ensure = File(p.join(root, 'scripts', 'ensure_running.sh'));
      if (!ensure.existsSync()) {
        lastError.value = 'Missing ${ensure.path}';
        statusMessage.value = lastError.value;
        return false;
      }

      await Process.run('chmod', ['+x', ensure.path]);

      statusMessage.value =
          'Preparing voice (first Chatterbox download may take several minutes)…';
      _log.info(
        'ensure_running: $root backend=$desired force=$forceRestart',
        source: 'VoiceRuntime',
      );

      String? refsDir;
      try {
        await AppPaths.ensureInitialized();
        refsDir = AppPaths.voiceReferencesDir;
        await Directory(refsDir).create(recursive: true);
      } catch (_) {}

      final voiceId = resolvedTtsVoice;
      String? refPath;
      for (final v in voices) {
        if (v.id == voiceId && v.isReference) {
          refPath = v.path;
          break;
        }
      }
      final preset = voiceId.startsWith('kokoro:')
          ? voiceId.substring('kokoro:'.length)
          : (Platform.environment['VOICE_PRESET'] ?? 'af_heart');

      final result = await Process.run(
        '/bin/bash',
        [ensure.path],
        workingDirectory: root,
        environment: {
          ...Platform.environment,
          'PATH':
              '${Platform.environment['HOME']}/.local/bin:/opt/homebrew/bin:/usr/local/bin:${Platform.environment['PATH'] ?? ''}',
          'ESPEAK_DATA_PATH':
              Platform.environment['ESPEAK_DATA_PATH'] ??
              '/opt/homebrew/share/espeak-ng-data',
          'PHONEMIZER_ESPEAK_PATH':
              Platform.environment['PHONEMIZER_ESPEAK_PATH'] ??
              '/opt/homebrew/bin/espeak-ng',
          'VOICE_RUNTIME_HOST': '127.0.0.1',
          'VOICE_RUNTIME_PORT': '8765',
          'VOICE_TTS_BACKEND': desired,
          'VOICE_TTS_VOICE': voiceId,
          'VOICE_PRESET': preset,
          'VOICE_REFERENCES_DIR': ?refsDir,
          if (refPath != null && refPath.isNotEmpty)
            'VOICE_TTS_REFERENCE': refPath,
          if (forceRestart) 'VOICE_TTS_FORCE_RESTART': '1',
        },
      );

      _log.info(
        'ensure_running exit=${result.exitCode} out=${result.stdout}'
        ' err=${result.stderr}',
        source: 'VoiceRuntime',
      );

      for (var i = 0; i < 120; i++) {
        statusMessage.value = 'Waiting for voice…';
        if (await ping()) {
          lastError.value = '';
          final active = activeBackend.value.isEmpty
              ? desired
              : activeBackend.value;
          statusMessage.value = fallbackUsed.value
              ? 'Voice ready ($active; fell back from $desired)'
              : 'Voice ready ($active)';
          return true;
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }

      final detail = (result.stderr.toString().trim().isNotEmpty
              ? result.stderr.toString().trim()
              : result.stdout.toString().trim())
          .split('\n')
          .reversed
          .take(4)
          .toList()
          .reversed
          .join(' ');
      lastError.value = detail.isEmpty
          ? 'Voice runtime failed to start (exit ${result.exitCode})'
          : detail;
      statusMessage.value = lastError.value;
      return false;
    } catch (e) {
      lastError.value = e.toString();
      statusMessage.value = lastError.value;
      _log.error('ensureRunning failed: $e', source: 'VoiceRuntime');
      return false;
    } finally {
      isStarting.value = false;
    }
  }

  Future<String> transcribeFile(String wavPath) async {
    final bytes = await File(wavPath).readAsBytes();
    return transcribeBytes(bytes, filename: p.basename(wavPath));
  }

  Future<String> transcribeBytes(
    List<int> bytes, {
    String filename = 'audio.wav',
  }) async {
    if (!await ping()) {
      final ok = await ensureRunning();
      if (!ok) throw StateError(lastError.value);
    }
    if (bytes.isEmpty) {
      throw StateError('Empty audio buffer');
    }
    final uri = Uri.parse('$baseUrl/transcribe');
    final req = http.MultipartRequest('POST', uri)
      ..files.add(
        http.MultipartFile.fromBytes('audio', bytes, filename: filename),
      );
    final streamed = await req.send().timeout(const Duration(seconds: 60));
    final body = await streamed.stream.bytesToString();
    if (streamed.statusCode != 200) {
      throw HttpException('transcribe ${streamed.statusCode}: $body');
    }
    final json = jsonDecode(body) as Map<String, dynamic>;
    return (json['text'] as String? ?? '').trim();
  }

  Future<List<int>> speak(String text, {String? voice}) async {
    if (!await ping()) {
      final ok = await ensureRunning();
      if (!ok) throw StateError(lastError.value);
    }
    final voiceId = (voice ?? resolvedTtsVoice).trim();
    final res = await http
        .post(
          Uri.parse('$baseUrl/speak'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'text': text,
            if (voiceId.isNotEmpty) 'voice': voiceId,
          }),
        )
        .timeout(const Duration(seconds: 90));
    if (res.statusCode != 200) {
      throw HttpException('speak ${res.statusCode}: ${res.body}');
    }
    return res.bodyBytes;
  }

  String? _resolveVoiceRuntimeRoot() {
    final candidates = <String>[];

    final stored = _storage?.voiceRuntimePath ?? '';
    if (stored.isNotEmpty) candidates.add(stored);

    var dir = File(Platform.resolvedExecutable).parent;
    for (var i = 0; i < 14; i++) {
      candidates.add(p.join(dir.path, 'voice_runtime'));
      dir = dir.parent;
    }

    dir = Directory.current;
    for (var i = 0; i < 8; i++) {
      candidates.add(p.join(dir.path, 'voice_runtime'));
      dir = dir.parent;
    }

    final home = Platform.environment['HOME'];
    if (home != null) {
      candidates.add(
        p.join(
          home,
          'Documents/bilal/development/personal/uncensored-ai',
          'Uncensored-Local-AI-Multiplatform/voice_runtime',
        ),
      );
    }

    for (final c in candidates) {
      final root = Directory(p.normalize(c));
      final server = File(p.join(root.path, 'server.py'));
      final ensure = File(p.join(root.path, 'scripts', 'ensure_running.sh'));
      if (server.existsSync() && ensure.existsSync()) {
        return root.path;
      }
    }
    return null;
  }

  @override
  void onClose() {
    // Intentionally do NOT kill the sidecar — it should stay up for next launch.
    super.onClose();
  }
}
