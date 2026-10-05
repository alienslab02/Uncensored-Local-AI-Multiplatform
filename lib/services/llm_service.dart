import 'dart:async';
import 'dart:io';
import 'package:get/get.dart';
import 'package:llamadart/llamadart.dart';
import 'package:path/path.dart' as p;

import 'wakelock_service.dart';
import 'chat_storage_service.dart';
import 'log_service.dart';

/// Wraps llamadart's LlamaEngine for model loading, generation, and lifecycle.
class LlmService extends GetxService {
  LlamaEngine? _engine;
  LlamaBackend? _backend;

  final isLoaded = false.obs;
  final isGenerating = false.obs;
  final loadedModelPath = ''.obs;
  final tokensPerSecond = 0.0.obs;
  final lastGenerationTokens = 0.obs;
  final lastGenerationSpeed = 0.0.obs;

  // ── Loading progress tracking ──────────────────────────────
  final isLoadingModel = false.obs;
  final loadingProgress = 0.0.obs; // 0.0 to 1.0
  final loadingStatusMsg = ''.obs;
  bool _loadingCancelled = false;

  StreamSubscription? _generateSub;

  String get loadedModelFilename {
    final path = loadedModelPath.value;
    if (path.isEmpty) return '';
    return p.basename(path);
  }

  String get publicModelId {
    final filename = loadedModelFilename;
    if (filename.isEmpty) return 'local';
    final stem = filename.toLowerCase().endsWith('.gguf')
        ? filename.substring(0, filename.length - 5)
        : p.basenameWithoutExtension(filename);
    return stem
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
  }

  /// Initialize the service.
  Future<LlmService> init() async {
    // Backend is created fresh per loadModel() call — no init needed here
    return this;
  }

  /// Cancel an in-progress model load.
  void cancelLoading() {
    _loadingCancelled = true;
  }

  /// Load a GGUF model from [path] with progress tracking.
  Future<void> loadModel(String path) async {
    LogService? log;
    try { log = Get.find<LogService>(); } catch (_) {}

    // Verify file exists first
    final file = File(path);
    if (!await file.exists()) {
      log?.error('Model file not found: $path', source: 'LLM');
      throw Exception('Model file not found: $path');
    }

    final filename = p.basename(path);
    log?.info('Loading model: $filename', source: 'LLM');

    _loadingCancelled = false;
    isLoadingModel.value = true;
    loadingProgress.value = 0.0;
    loadingStatusMsg.value = 'Preparing...';

    // Enable wake lock during model loading (heavy memory operation)
    WakelockService? wakelockService;
    try {
      wakelockService = Get.find<WakelockService>();
    } catch (_) {}

    // Unload previous if any — MUST fully tear down engine + backend
    if (_engine != null || isLoaded.value) {
      loadingStatusMsg.value = 'Unloading previous model...';
      loadingProgress.value = 0.05;
      await _fullTeardown();
      // Give native side time to release resources
      await Future.delayed(const Duration(milliseconds: 500));
      if (_loadingCancelled) {
        _resetLoadingState();
        return;
      }
    }

    // Fresh backend + engine for every load — prevents stale native state
    // Wrapped in try-catch to handle SELinux crashes on Android where
    // ggml_backend_load_all() attempts to scan '/' which is denied.
    try {
      _backend = LlamaBackend();
      _engine = LlamaEngine(_backend!);
    } catch (e) {
      _backend = null;
      _engine = null;
      _resetLoadingState();
      log?.error('Engine init failed: $e', source: 'LLM');
      throw Exception(
        'Failed to initialize AI engine. '
        'This may be a device compatibility issue. '
        'Error: $e',
      );
    }

    try {
      loadingStatusMsg.value = 'Loading into memory...';
      loadingProgress.value = 0.1;

      // Get file size for display
      final fileSize = await file.length();
      final sizeGb = (fileSize / (1024 * 1024 * 1024)).toStringAsFixed(1);
      loadingStatusMsg.value = 'Loading $sizeGb GB into memory...';

      // Start a timer to animate progress while loading
      Timer? progressTimer;
      progressTimer = Timer.periodic(const Duration(milliseconds: 300), (
        timer,
      ) {
        if (_loadingCancelled) {
          timer.cancel();
          return;
        }
        // Gradually increase progress (asymptotic approach to 0.95)
        final current = loadingProgress.value;
        if (current < 0.95) {
          loadingProgress.value = current + (0.95 - current) * 0.04;
        }
      });

      if (_loadingCancelled) {
        progressTimer.cancel();
        await _fullTeardown();
        _resetLoadingState();
        return;
      }

      // Use smaller context on Android to prevent OOM kills.
      // Desktop can handle 2048, but Android devices with limited RAM
      // need 1024 to avoid the Low Memory Killer (LMK).
      final contextSize = Platform.isAndroid ? 1024 : 2048;

      // Map the string backend to GpuBackend enum
      final storage = Get.find<ChatStorageService>();
      GpuBackend parsedBackend;
      switch (storage.backendType) {
        case 'vulkan':
          parsedBackend = GpuBackend.vulkan;
          break;
        case 'opencl':
          parsedBackend = GpuBackend.opencl;
          break;
        default:
          parsedBackend = GpuBackend.cpu;
      }

      // Read gpu layers
      final userGpuLayers = storage.gpuLayers;

      // Optimize threads: 4 for both generation and batch processing to keep memory stable.
      final params = ModelParams(
        contextSize: contextSize,
        gpuLayers: userGpuLayers, 
        preferredBackend: parsedBackend,
        numberOfThreads: Platform.numberOfProcessors > 4 ? 4 : 0, 
        numberOfThreadsBatch: Platform.numberOfProcessors > 4 ? 4 : 0,
      );

      log?.info('Backend=$parsedBackend, GPU layers=$userGpuLayers, ctx=$contextSize, threads=${Platform.numberOfProcessors > 4 ? 4 : 0}', source: 'LLM');

      await _engine!.loadModel(path, modelParams: params);
      progressTimer.cancel();

      if (_loadingCancelled) {
        // User cancelled while loading — full cleanup
        await _fullTeardown();
        _resetLoadingState();
        return;
      }

      loadingProgress.value = 1.0;
      loadingStatusMsg.value = 'Ready!';
      isLoaded.value = true;
      loadedModelPath.value = path;
      log?.info('Model loaded successfully: $filename', source: 'LLM');

      // Enable wake lock for inference on mobile (keeps app from being killed)
      final modelName = p.basenameWithoutExtension(path);
      await wakelockService?.enableForInference(modelName: modelName);

      // Brief delay to show 100%
      await Future.delayed(const Duration(milliseconds: 300));
    } catch (e) {
      isLoaded.value = false;
      loadedModelPath.value = '';
      await _fullTeardown();
      log?.error('Model load failed: $e', source: 'LLM');

      // Provide a clearer error message for common Android failures
      if (Platform.isAndroid) {
        final errStr = e.toString().toLowerCase();
        if (errStr.contains('memory') || errStr.contains('alloc')) {
          throw Exception(
            'Not enough RAM to load this model. '
            'Try a smaller model (e.g. Gemma 2 2B at 1.6 GB).',
          );
        }
      }
      rethrow;
    } finally {
      _resetLoadingState();
    }
  }

  void _resetLoadingState() {
    isLoadingModel.value = false;
    loadingProgress.value = 0.0;
    loadingStatusMsg.value = '';
    _loadingCancelled = false;
  }

  /// Tokens/patterns the model may emit that should be stripped from output.
  /// Covers ChatML, Llama, Gemma, Phi, Mistral, and other common formats.
  /// Includes truncated leaks like `<end|>` (missing the opening `|`).
  static final _stopPatterns = RegExp(
    r'<\|end\|>'
    r'|<end\|>' // truncated <|end|>
    r'|<\|\s*end\s*\|?>'
    r'|<\|eot_id\|>'
    r'|<\|endoftext\|>'
    r'|<\|im_end\|>'
    r'|<\|im_start\|>'
    r'|<end_of_turn>'
    r'|<start_of_turn>'
    r'|<\|assistant\|>'
    r'|<\|user\|>'
    r'|<\|system\|>'
    r'|<\|pad\|>'
    r'|</s>'
    r'|<s>'
    r'|\[INST\]'
    r'|\[/INST\]'
    r'|\[end\]',
  );

  /// Pattern that signals the model is hallucinating a new user turn — stop immediately.
  static final _userTurnPattern = RegExp(
    r'<\|user\|>|<\|im_start\|>\s*user|<start_of_turn>\s*user|\[INST\]',
  );

  /// Earliest index of a chat-template / stop leak. -1 if none.
  static int _controlLeakIndex(String text) {
    const markers = <String>[
      '<|',
      '<end|>',
      '<end_of_turn>',
      '<start_of_turn>',
      '</s>',
      '[INST]',
      '[/INST]',
      '[end]',
    ];
    var cut = -1;
    for (final m in markers) {
      final i = text.indexOf(m);
      if (i >= 0 && (cut < 0 || i < cut)) cut = i;
    }
    return cut;
  }

  /// If the model emitted the same reply twice back-to-back (`A` + `A`),
  /// keep a single copy. Exact match only (optional whitespace between).
  static String collapseExactRepeatedReply(String text) {
    final t = text.trim();
    if (t.length < 40) return t;

    if (t.length.isEven) {
      final mid = t.length ~/ 2;
      final a = t.substring(0, mid);
      if (a == t.substring(mid)) return a;
    }

    final mid = t.length ~/ 2;
    final lo = mid - 48 < 20 ? 20 : mid - 48;
    final hi = mid + 48 > t.length - 20 ? t.length - 20 : mid + 48;
    for (var i = lo; i <= hi; i++) {
      final a = t.substring(0, i).trimRight();
      final b = t.substring(i).trimLeft();
      if (a.length >= 20 && a == b) return a;
    }
    return t;
  }

  /// Strip stop/control token leaks from assistant text (chat UI + voice).
  /// Emotion tags like `[chuckle]` are kept.
  static String stripControlTokens(String raw) {
    var text = raw;
    final leak = _controlLeakIndex(text);
    if (leak >= 0) {
      text = text.substring(0, leak);
    }
    final stop = _stopPatterns.firstMatch(text);
    if (stop != null) {
      text = text.substring(0, stop.start);
    }
    final user = _userTurnPattern.firstMatch(text);
    if (user != null) {
      text = text.substring(0, user.start);
    }
    text = text
        // Orphan / half tokens still left after a bad stream flush
        .replaceAll(RegExp(r'<\|[^|>]*\|?>?'), '')
        .replaceAll(RegExp(r'<?end\|>'), '')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n');
    text = collapseExactRepeatedReply(text);
    text = dedupeTrailingEcho(text);
    return text.trim();
  }

  /// True if [next] is a truncated/echoed copy of the end of [emitted].
  /// Catches: `…my dear.` + ` at sparks your interest, my dear.`
  static bool _isEchoChunk(String emitted, String next) {
    final a = emitted;
    final b = next.trim(); // leading space on echoes is common
    if (a.isEmpty || b.length < 10) return false;
    if (a.endsWith(b) || a.trimRight().endsWith(b)) return true;

    // Allow a few missing/extra leading chars on the repeated tail
    for (var skip = 0; skip <= 8 && skip < b.length; skip++) {
      final frag = b.substring(skip);
      if (frag.length < 10) break;
      if (a.endsWith(frag)) return true;
      if (frag.length <= a.length) {
        final suf = a.substring(a.length - frag.length);
        if (suf == frag) return true;
        // Same tail with 1–3 char prefix mismatch ("what" vs "at")
        for (var d = 1; d <= 3; d++) {
          final n = frag.length - d;
          if (n >= 10 &&
              suf.length >= n &&
              frag.length >= n &&
              suf.substring(suf.length - n) == frag.substring(frag.length - n)) {
            return true;
          }
        }
      }
    }

    // Near-duplicate consecutive windows at the join point
    final combined = a + b;
    for (var n = 12; n <= b.length && n * 2 <= combined.length; n++) {
      final second = combined.substring(combined.length - n);
      final first =
          combined.substring(combined.length - 2 * n, combined.length - n);
      for (var m = n; m >= n - 3 && m >= 10; m--) {
        if (first.length >= m &&
            second.length >= m &&
            first.substring(first.length - m) ==
                second.substring(second.length - m)) {
          return true;
        }
      }
    }
    return false;
  }

  /// Remove a trailing echoed clause inside one string
  /// (`…my dear. at sparks your interest, my dear.` → `…my dear.`).
  static String dedupeTrailingEcho(String text) {
    if (text.length < 24) return text;
    var t = text;
    for (var guard = 0; guard < 6; guard++) {
      var cutAt = -1;
      // Cap echo length — model glitches are short tails, not half the reply
      final limit = t.length < 80 ? t.length ~/ 2 : 120;
      final maxN = limit < t.length ~/ 2 ? limit : t.length ~/ 2;
      // Shortest match first so we don't chop a good sentence + its echo together
      for (var n = 12; n <= maxN; n++) {
        final second = t.substring(t.length - n);
        final before = t.substring(0, t.length - n);
        final st = second.trimLeft();
        if (st.length < 10) continue;
        // Glitch echoes usually restart mid-sentence (lowercase) after `.!?`
        final startsLower = RegExp(r'^[a-z]').hasMatch(st);
        final afterSentence = RegExp(r'[.!?…]\s*$').hasMatch(before.trimRight());
        if (!startsLower && !afterSentence) continue;
        if (!startsLower && afterSentence) {
          // Capitalized restart — only accept if strong shared ending
          final check = st.length < 18 ? st.length : 18;
          final tail = st.substring(st.length - check);
          if (!before.trimRight().endsWith(tail)) {
            final bt = before.trimRight();
            if (bt.length < check) continue;
            final btTail = bt.substring(bt.length - check);
            final m = check - 2;
            if (m < 10 ||
                btTail.substring(btTail.length - m) !=
                    tail.substring(tail.length - m)) {
              continue;
            }
          }
        }
        if (_isEchoChunk(before, second)) {
          cutAt = before.length;
          break;
        }
      }
      if (cutAt < 0) break;
      t = t.substring(0, cutAt).trimRight();
    }
    return t;
  }

  /// Stop strings that end a turn if the model emits them as text.
  /// Primary stop is the model's EOS via chat-template; these are backups.
  static const List<String> _defaultStopSequences = [
    '<end_of_turn>',
    '<start_of_turn>',
    '<|end|>',
    '<end|>',
    '<|eot_id|>',
    '<|im_end|>',
    '</s>',
  ];

  /// Convert UI {role, content} maps (+ optional system) to chat messages.
  static List<LlamaChatMessage> _toChatMessages(
    List<Map<String, String>> messages,
    String? systemPrompt,
  ) {
    final out = <LlamaChatMessage>[];
    if (systemPrompt != null && systemPrompt.trim().isNotEmpty) {
      out.add(
        LlamaChatMessage.fromText(
          role: LlamaChatRole.system,
          text: systemPrompt.trim(),
        ),
      );
    }
    for (final msg in messages) {
      final role = switch (msg['role']) {
        'system' => LlamaChatRole.system,
        'assistant' => LlamaChatRole.assistant,
        _ => LlamaChatRole.user,
      };
      out.add(
        LlamaChatMessage.fromText(
          role: role,
          text: msg['content'] ?? '',
        ),
      );
    }
    return out;
  }

  /// Shared streaming path: model's GGUF chat template + EOS (not raw prompt).
  Stream<String> _streamChatCompletion({
    required List<LlamaChatMessage> messages,
    required GenerationParams params,
  }) async* {
    if (_engine == null || !isLoaded.value) {
      throw StateError('No model loaded. Call loadModel() first.');
    }
    if (isGenerating.value) {
      throw StateError('Another generation is already in progress.');
    }

    isGenerating.value = true;
    tokensPerSecond.value = 0.0;
    final stopwatch = Stopwatch()..start();
    var tokenCount = 0;
    var emitted = '';

    try {
      await for (final chunk in _engine!.create(
        messages,
        params: params,
        toolChoice: ToolChoice.none,
      )) {
        final choice = chunk.choices.isNotEmpty ? chunk.choices.first : null;
        final content = choice?.delta.content;
        if (content == null || content.isEmpty) continue;

        tokenCount++;
        if (stopwatch.elapsedMilliseconds > 0) {
          tokensPerSecond.value =
              tokenCount / (stopwatch.elapsedMilliseconds / 1000);
        }

        // Cut if a control leak still slips through as text
        final merged = emitted + content;
        final leakAt = _controlLeakIndex(merged);
        final stop = _stopPatterns.firstMatch(merged);
        final user = _userTurnPattern.firstMatch(merged);
        var cutAt = -1;
        if (leakAt >= 0) cutAt = leakAt;
        if (stop != null && (cutAt < 0 || stop.start < cutAt)) {
          cutAt = stop.start;
        }
        if (user != null && (cutAt < 0 || user.start < cutAt)) {
          cutAt = user.start;
        }
        if (cutAt >= 0) {
          if (cutAt > emitted.length) {
            yield merged.substring(emitted.length, cutAt);
          }
          break;
        }

        // Exact A+A mid-stream: stop yielding the second copy
        final collapsed = collapseExactRepeatedReply(merged);
        if (collapsed.length < merged.length &&
            collapsed.length >= emitted.length) {
          if (collapsed.length > emitted.length) {
            yield collapsed.substring(emitted.length);
          }
          emitted = collapsed;
          break;
        }

        emitted = merged;
        yield content;
      }
    } finally {
      stopwatch.stop();
      lastGenerationTokens.value = tokenCount;
      lastGenerationSpeed.value = tokensPerSecond.value;
      isGenerating.value = false;
    }
  }

  /// Generate a streaming response for in-app chat / voice.
  ///
  /// Uses the GGUF's native chat template (via [LlamaEngine.create]) so the
  /// model receives correct turn markers and stops on EOS — not a hand-rolled
  /// ChatML string that Gemma will ignore and then re-emit as a second copy.
  Stream<String> generate({
    required List<Map<String, String>> messages,
    String? systemPrompt,
    double temperature = 0.7,
  }) {
    final chatMessages = _toChatMessages(messages, systemPrompt);
    final params = GenerationParams(
      temp: temperature,
      topP: 0.95,
      minP: 0.05,
      penalty: 1.0,
      stopSequences: _defaultStopSequences,
    );
    return _streamChatCompletion(messages: chatMessages, params: params);
  }

  /// Generate a chat completion using llamadart's chat-template API.
  Stream<String> generateChatCompletion({
    required List<LlamaChatMessage> messages,
    GenerationParams params = const GenerationParams(),
  }) {
    final withStops = params.stopSequences.isEmpty
        ? params.copyWith(stopSequences: _defaultStopSequences)
        : params;
    return _streamChatCompletion(messages: messages, params: withStops);
  }

  Future<int> countTokens(String text) async {
    if (_engine == null || !isLoaded.value) return 0;
    try {
      return await _engine!.getTokenCount(text);
    } catch (_) {
      return 0;
    }
  }

  /// Stop ongoing generation.
  Future<void> stopGeneration() async {
    _generateSub?.cancel();
    _generateSub = null;
    _engine?.cancelGeneration();
    isGenerating.value = false;
  }

  /// Full native teardown — dispose engine AND backend to prevent stale state.
  Future<void> _fullTeardown() async {
    if (_engine != null) {
      try {
        await _engine!.dispose();
      } catch (_) {
        // Engine may already be in broken state — ignore
      }
      _engine = null;
    }
    // Also destroy the backend — it can't be reused after engine disposal
    _backend = null;
    isLoaded.value = false;
    loadedModelPath.value = '';
    tokensPerSecond.value = 0.0;
  }

  /// Unload the current model and free memory.
  Future<void> unloadModel() async {
    await _fullTeardown();

    // Disable wake lock when model is unloaded
    try {
      final wakelockService = Get.find<WakelockService>();
      await wakelockService.disable();
    } catch (_) {}
  }

  @override
  void onClose() {
    unloadModel();
    super.onClose();
  }
}
