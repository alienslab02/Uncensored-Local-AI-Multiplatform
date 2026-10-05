import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as p;

import '../models/message_model.dart';
import '../services/chat_storage_service.dart';
import '../services/llm_service.dart';
import '../services/log_service.dart';
import '../services/voice_playback_service.dart';
import '../services/voice_recorder_service.dart';
import '../services/voice_runtime_service.dart';
import 'chat_controller.dart';

enum VoiceChatPhase {
  idle,
  starting,
  recording,
  transcribing,
  thinking,
  speaking,
  error,
}

/// Hold-to-talk: press key/mic → listen → release → STT → LLM → TTS → play.
class VoiceChatController extends GetxController {
  final phase = VoiceChatPhase.idle.obs;
  final statusText = 'Hold Right ⌥ (Option) or mic to talk'.obs;
  final lastTranscript = ''.obs;
  final lastError = ''.obs;
  final turnBusy = false.obs;
  final canSend = false.obs;

  /// Desktop PTT key (macOS Right Option). Does not conflict with typing.
  static const pttKey = LogicalKeyboardKey.altRight;
  static const pttKeyLabel = 'Right ⌥';
  static const idleHint = 'Hold Right ⌥ (Option) or mic to talk';

  static const _minListen = Duration(milliseconds: 900);
  static const _voiceSystemHint =
      'Reply in 1-3 short spoken sentences, like a natural conversation. '
      'No markdown, no lists, no code. '
      'For emotion/sound cues use ONLY these bracket tags when helpful: '
      '[happy], [chuckle], [laugh], [sigh], [angry], [sarcastic], [surprised], '
      '[whispering], [gasp], [cough]. Never invent tags like [smile].';

  var _stopRequested = false;
  var _pttHeld = false;
  Timer? _listenTicker;
  /// Chains enqueue order while allowing parallel /speak synthesis.
  Future<void> _speakChain = Future<void>.value();

  VoiceRuntimeService get _runtime => Get.find<VoiceRuntimeService>();
  VoicePlaybackService get _playback => Get.find<VoicePlaybackService>();
  VoiceRecorderService get _recorder => Get.find<VoiceRecorderService>();
  ChatController get _chat => Get.find<ChatController>();
  LlmService get _llm => Get.find<LlmService>();
  ChatStorageService get _storage => Get.find<ChatStorageService>();
  LogService get _log => Get.find<LogService>();

  bool get isListening => phase.value == VoiceChatPhase.recording;
  bool get isProcessing =>
      phase.value == VoiceChatPhase.starting ||
      phase.value == VoiceChatPhase.transcribing ||
      phase.value == VoiceChatPhase.thinking ||
      phase.value == VoiceChatPhase.speaking ||
      turnBusy.value;

  @override
  void onInit() {
    super.onInit();
    HardwareKeyboard.instance.addHandler(_onKeyEvent);
  }

  /// Press-and-hold start (keyboard or mic button).
  Future<void> onPttPress() async {
    if (_pttHeld) return;
    if (phase.value == VoiceChatPhase.recording) return;
    if (isProcessing) return;

    _pttHeld = true;
    await _startListening();

    // Released while still starting — finish as soon as recording begins.
    if (!_pttHeld && phase.value == VoiceChatPhase.recording) {
      await _releaseAfterMinListen();
    }
    _notifyErrorIfNeeded();
  }

  /// Release ends the utterance and runs the voice turn.
  Future<void> onPttRelease() async {
    if (!_pttHeld) return;
    _pttHeld = false;

    if (phase.value == VoiceChatPhase.starting) {
      for (var i = 0; i < 80; i++) {
        if (phase.value == VoiceChatPhase.recording) break;
        if (phase.value != VoiceChatPhase.starting) return;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }

    if (phase.value != VoiceChatPhase.recording) return;
    await _releaseAfterMinListen();
    _notifyErrorIfNeeded();
  }

  Future<void> _releaseAfterMinListen() async {
    while (phase.value == VoiceChatPhase.recording &&
        _recorder.elapsed < _minListen) {
      statusText.value = 'Got it… (${_remainingMs()}ms)';
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (phase.value == VoiceChatPhase.recording) {
      await _finishListeningAndRunTurn();
    }
  }

  bool _onKeyEvent(KeyEvent event) {
    if (event.logicalKey != pttKey) return false;
    if (event is KeyDownEvent) {
      unawaited(onPttPress());
      return true;
    }
    if (event is KeyUpEvent) {
      unawaited(onPttRelease());
      return true;
    }
    return false;
  }

  void _notifyErrorIfNeeded() {
    if (phase.value != VoiceChatPhase.error || lastError.value.isEmpty) return;
    if (lastError.value.contains('Microphone permission')) return;
    Get.snackbar(
      'Voice',
      lastError.value,
      snackPosition: SnackPosition.BOTTOM,
      duration: const Duration(seconds: 6),
    );
  }

  int _remainingMs() {
    final left = _minListen - _recorder.elapsed;
    return left.isNegative ? 0 : left.inMilliseconds;
  }

  Future<void> _startListening() async {
    _stopRequested = false;
    lastError.value = '';
    canSend.value = false;

    if (!_llm.isLoaded.value) {
      _fail('Load a model first, then hold $pttKeyLabel or the mic');
      return;
    }

    phase.value = VoiceChatPhase.starting;
    statusText.value = 'Starting voice…';
    turnBusy.value = true;

    try {
      if (!await _runtime.ping()) {
        statusText.value = 'Starting voice engine…';
        final ok = await _runtime.ensureRunning();
        if (!ok) {
          _fail(_runtime.lastError.value.isEmpty
              ? 'Could not start voice runtime'
              : _runtime.lastError.value);
          return;
        }
      }

      statusText.value = 'Checking microphone…';
      final permitted = await _recorder.ensureMicPermission();
      if (!permitted) {
        await _failMicDenied();
        return;
      }

      await _recorder.start();
      phase.value = VoiceChatPhase.recording;
      statusText.value = 'Listening… release $pttKeyLabel / mic to send';
      turnBusy.value = false;

      _listenTicker?.cancel();
      _listenTicker = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (phase.value != VoiceChatPhase.recording) return;
        final ready = _recorder.elapsed >= _minListen;
        canSend.value = ready;
        final hearing = _recorder.amplitudeDb.value > -45;
        if (!ready) {
          statusText.value =
              'Listening… speak (${(_remainingMs() / 1000).toStringAsFixed(1)}s)';
        } else if (hearing) {
          statusText.value = 'Hearing you… release to send';
        } else {
          statusText.value = 'Listening… release to send';
        }
      });
    } catch (e) {
      _log.error('Start listening failed: $e', source: 'VoiceChat');
      if (e.toString().contains('mic_denied')) {
        await _failMicDenied();
      } else {
        _fail('Mic failed: $e');
      }
    }
  }

  Future<void> _failMicDenied() async {
    phase.value = VoiceChatPhase.error;
    lastError.value =
        'Microphone permission is off. Enable “Mate” in System Settings → Privacy & Security → Microphone, then try again.';
    statusText.value = lastError.value;
    turnBusy.value = false;
    _pttHeld = false;
    Get.snackbar(
      'Microphone blocked',
      'Enable Mate in Microphone settings, then hold $pttKeyLabel or mic',
      snackPosition: SnackPosition.BOTTOM,
      duration: const Duration(seconds: 8),
      mainButton: TextButton(
        onPressed: _recorder.openMicSettings,
        child: const Text(
          'Open Settings',
          style: TextStyle(color: Color(0xFF818CF8)),
        ),
      ),
    );
    await _recorder.openMicSettings();
  }

  Future<void> _finishListeningAndRunTurn() async {
    if (phase.value != VoiceChatPhase.recording) return;
    _listenTicker?.cancel();
    turnBusy.value = true;
    canSend.value = false;

    try {
      phase.value = VoiceChatPhase.transcribing;
      statusText.value = 'Saving audio…';

      final file = await _recorder.stopToWavFile();
      final wavBytes = _recorder.lastWavBytes;
      if (wavBytes == null || wavBytes.length < 1000) {
        _fail(
          'No speech captured — hold $pttKeyLabel or mic and speak clearly for 1–2 seconds',
        );
        return;
      }

      statusText.value = 'Transcribing…';
      // Prefer in-memory bytes — avoids PathNotFound races on temp files.
      final text = await _runtime.transcribeBytes(
        wavBytes,
        filename: file != null ? p.basename(file.path) : 'audio.wav',
      );
      try {
        await file?.delete();
      } catch (_) {}

      if (text.isEmpty) {
        phase.value = VoiceChatPhase.idle;
        statusText.value = 'No speech heard — try again closer to the mic';
        turnBusy.value = false;
        return;
      }

      lastTranscript.value = text;
      statusText.value = 'You: $text';
      _log.info('Transcript: $text', source: 'VoiceChat');
      await _streamThinkAndSpeak(text);
    } catch (e) {
      _log.error('Voice turn failed: $e', source: 'VoiceChat');
      _fail(e.toString());
    } finally {
      if (phase.value != VoiceChatPhase.error) {
        turnBusy.value = false;
      }
    }
  }

  Future<void> _streamThinkAndSpeak(String userText) async {
    if (_chat.activeChat == null) _chat.newChat();
    final chat = _chat.activeChat!;

    chat.messages.add(MessageModel(role: MessageRole.user, content: userText));
    chat.autoTitle();
    chat.updatedAt = DateTime.now();
    _storage.saveChat(chat);
    _chat.chats.refresh();

    final history = chat.messages
        .where((m) => !m.isSystem)
        .map((m) => m.toLlamaMessage())
        .toList();

    final baseSystem = chat.systemPrompt.isNotEmpty
        ? chat.systemPrompt
        : _chat.systemPrompt.value;
    final system = [
      if (baseSystem.trim().isNotEmpty) baseSystem.trim(),
      _voiceSystemHint,
    ].join('\n');

    phase.value = VoiceChatPhase.thinking;
    statusText.value = 'Thinking…';
    _chat.isGenerating.value = true;
    _chat.streamedResponse.value = '';

    final aiMsg = MessageModel(role: MessageRole.assistant, content: '');
    chat.messages.add(aiMsg);
    _chat.chats.refresh();

    var pending = '';
    var speakingStarted = false;
    var speakQueued = false;
    _speakChain = Future<void>.value();

    try {
      final stream = _llm.generate(
        messages: history,
        systemPrompt: system,
        temperature: _chat.temperature.value,
      );

      await for (final token in stream) {
        if (_stopRequested) break;
        _chat.streamedResponse.value += token;
        aiMsg.content = _chat.streamedResponse.value;
        _chat.chats.refresh();

        pending += token;
        final parts = _splitSentences(pending);
        if (parts.complete.isEmpty) continue;
        pending = parts.rest;
        for (final sentence in parts.complete) {
          if (!speakingStarted) {
            speakingStarted = true;
            phase.value = VoiceChatPhase.speaking;
            statusText.value = 'Speaking…';
          }
          if (_queueSpeak(sentence)) speakQueued = true;
        }
      }

      final tail = pending.trim();
      if (tail.isNotEmpty && !_stopRequested) {
        if (!speakingStarted) {
          phase.value = VoiceChatPhase.speaking;
          statusText.value = 'Speaking…';
        }
        if (_queueSpeak(tail)) speakQueued = true;
      }

      if (!speakQueued &&
          aiMsg.content.trim().isNotEmpty &&
          !_stopRequested) {
        phase.value = VoiceChatPhase.speaking;
        statusText.value = 'Speaking…';
        _queueSpeak(aiMsg.content.trim());
      }

      await _speakChain;

      statusText.value = 'Playing…';
      for (var i = 0; i < 120; i++) {
        if (!_playback.isPlaying.value && !_playback.hasQueuedAudio) break;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    } catch (e) {
      if (aiMsg.content.isEmpty) aiMsg.content = '⚠ Error: $e';
      rethrow;
    } finally {
      aiMsg.content = LlmService.stripControlTokens(aiMsg.content);
      _chat.isGenerating.value = false;
      _chat.streamedResponse.value = '';
      chat.updatedAt = DateTime.now();
      _storage.saveChat(chat);
      _chat.chats.refresh();
      if (!_stopRequested) {
        phase.value = VoiceChatPhase.idle;
        statusText.value = idleHint;
      }
      turnBusy.value = false;
    }
  }

  static const _chatterboxTags = {
    'advertisement',
    'angry',
    'chuckle',
    'clear throat',
    'cough',
    'crying',
    'dramatic',
    'fear',
    'gasp',
    'groan',
    'happy',
    'laugh',
    'narration',
    'sarcastic',
    'shush',
    'sigh',
    'sniff',
    'surprised',
    'whispering',
  };

  static const _tagAliases = {
    'smile': 'happy',
    'smiling': 'happy',
    'grin': 'happy',
    'giggle': 'chuckle',
    'chuckling': 'chuckle',
    'lol': 'laugh',
    'haha': 'laugh',
    'cry': 'crying',
    'sob': 'crying',
    'whisper': 'whispering',
    'wow': 'surprised',
    'shock': 'surprised',
    'scared': 'fear',
    'sad': 'sigh',
    'ahem': 'clear throat',
  };

  /// Strip model control tokens / markdown; normalize Chatterbox tags.
  String _sanitizeForTts(String raw) {
    var text = LlmService.stripControlTokens(raw.trim());
    text = text.replaceAll(
      RegExp(
        r'<\|[^|>]*\|?>?'
        r'|<?end\|>'
        r'|</?(?:end_of_turn|start_of_turn|s|pad)(?:\s[^>]*)?>',
        caseSensitive: false,
      ),
      ' ',
    );
    // Drop emoji — voice tags carry emotion instead
    text = text.replaceAll(
      RegExp(
        r'[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}\u{FE0F}\u{200D}]',
        unicode: true,
      ),
      ' ',
    );
    text = text.replaceAll(RegExp(r'[`*_#~>{}|\\]'), ' ');
    text = text.replaceAllMapped(RegExp(r'\[([^\]]+)\]'), (m) {
      var inner = m.group(1)!.trim().toLowerCase();
      inner = _tagAliases[inner] ?? inner;
      if (_chatterboxTags.contains(inner)) return '[$inner]';
      return ' ';
    });
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (!RegExp(r'[A-Za-z0-9\u00C0-\u024F\u0400-\u04FF\u4E00-\u9FFF]').hasMatch(text) &&
        !RegExp(r'\[[^\]]+\]').hasMatch(text)) {
      return '';
    }
    return text;
  }

  /// Start TTS immediately (parallel), but enqueue audio in sentence order.
  /// Returns false if [sentence] was empty after sanitize.
  bool _queueSpeak(String sentence) {
    final text = _sanitizeForTts(sentence);
    if (text.isEmpty) return false;

    // Kick off synthesis now — do not await before chaining.
    final synth = () async {
      try {
        return await _runtime.speak(text);
      } catch (e) {
        _log.error('TTS skip: $e', source: 'VoiceChat');
        return null;
      }
    }();

    _speakChain = _speakChain.then((_) async {
      if (_stopRequested) return;
      try {
        final bytes = await synth;
        if (_stopRequested || bytes == null || bytes.isEmpty) return;
        await _playback.enqueueWavBytes(bytes);
      } catch (e) {
        _log.error('TTS enqueue skip: $e', source: 'VoiceChat');
      }
    });
    return true;
  }

  ({List<String> complete, String rest}) _splitSentences(String buffer) {
    final complete = <String>[];
    final re = RegExp(r'([^.!?]+[.!?]+)(\s+|$)');
    var idx = 0;
    for (final m in re.allMatches(buffer)) {
      complete.add(m.group(1)!.trim());
      idx = m.end;
    }
    return (complete: complete, rest: buffer.substring(idx));
  }

  Future<void> cancel() async {
    _stopRequested = true;
    _pttHeld = false;
    _listenTicker?.cancel();
    await _recorder.cancel();
    await _playback.stop();
    _llm.stopGeneration();
    // Reset speak chain so a later turn does not wait on cancelled work.
    _speakChain = Future<void>.value();
    phase.value = VoiceChatPhase.idle;
    statusText.value = idleHint;
    turnBusy.value = false;
    canSend.value = false;
  }

  void _fail(String message) {
    _listenTicker?.cancel();
    _pttHeld = false;
    phase.value = VoiceChatPhase.error;
    lastError.value = message;
    statusText.value = message;
    turnBusy.value = false;
    canSend.value = false;
  }

  @override
  void onClose() {
    HardwareKeyboard.instance.removeHandler(_onKeyEvent);
    _listenTicker?.cancel();
    super.onClose();
  }
}
