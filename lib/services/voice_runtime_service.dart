import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'chat_storage_service.dart';
import 'log_service.dart';

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

  /// Selectable engines shown in Settings (must match `voice_runtime/tts`).
  static const ttsBackendOptions = <({String id, String label, String blurb})>[
    (
      id: 'chatterbox_nano',
      label: 'Chatterbox Nano',
      blurb: 'Expressive tags ([chuckle], …). Trial default.',
    ),
    (
      id: 'chatterbox_turbo',
      label: 'Chatterbox Turbo',
      blurb: 'Larger expressive English model.',
    ),
    (
      id: 'chatterbox_mtl_v3',
      label: 'Chatterbox Multilingual',
      blurb: 'Many languages; pass language_id on speak.',
    ),
    (
      id: 'kokoro',
      label: 'Kokoro (fallback)',
      blurb: 'Fast ONNX stack. Use if Chatterbox is slow.',
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

  String get resolvedTtsBackend {
    final fromEnv = (Platform.environment['VOICE_TTS_BACKEND'] ?? '').trim();
    if (fromEnv.isNotEmpty) return fromEnv;
    final stored = (_storage?.voiceTtsBackend ?? '').trim();
    if (stored.isNotEmpty) return stored;
    return defaultTtsBackend;
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
    return ensureRunning(forceRestart: true);
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

  Future<List<int>> speak(String text, {String voice = 'af_heart'}) async {
    if (!await ping()) {
      final ok = await ensureRunning();
      if (!ok) throw StateError(lastError.value);
    }
    final res = await http
        .post(
          Uri.parse('$baseUrl/speak'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'text': text, 'voice': voice}),
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
