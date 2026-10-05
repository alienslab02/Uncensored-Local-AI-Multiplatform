import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:get/get.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';

import 'app_paths.dart';
import 'log_service.dart';

/// Robust mic capture for macOS: PCM stream → WAV under ~/.uncensored-ai/voice.
class VoiceRecorderService extends GetxService {
  static const sampleRate = 16000;
  static const numChannels = 1;

  final AudioRecorder _recorder = AudioRecorder();
  final isRecording = false.obs;
  final amplitudeDb = (-160.0).obs;
  final hasPermission = false.obs;

  final _pcm = BytesBuilder(copy: true);
  StreamSubscription<List<int>>? _streamSub;
  StreamSubscription<Amplitude>? _ampSub;
  DateTime? _startedAt;
  Uint8List? _lastWavBytes;
  String? _lastWavPath;

  LogService get _log {
    try {
      return Get.find<LogService>();
    } catch (_) {
      return LogService();
    }
  }

  Duration get elapsed =>
      _startedAt == null ? Duration.zero : DateTime.now().difference(_startedAt!);

  /// Last captured WAV bytes (preferred for upload — avoids path races).
  Uint8List? get lastWavBytes => _lastWavBytes;
  String? get lastWavPath => _lastWavPath;

  Future<bool> ensureMicPermission() async {
    final ok = await _recorder.hasPermission();
    hasPermission.value = ok;
    return ok;
  }

  Future<void> openMicSettings() async {
    final urls = [
      'x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone',
      'x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone',
    ];
    for (final url in urls) {
      final r = await Process.run('open', [url]);
      if (r.exitCode == 0) return;
    }
    await Process.run('open', [
      '/System/Library/PreferencePanes/Security.prefPane',
    ]);
  }

  Future<void> start() async {
    if (isRecording.value) return;
    if (!await ensureMicPermission()) {
      throw StateError('mic_denied');
    }

    _pcm.clear();
    _lastWavBytes = null;
    _lastWavPath = null;
    await _streamSub?.cancel();
    await _ampSub?.cancel();

    InputDevice? device;
    try {
      final devices = await _recorder.listInputDevices();
      if (devices.isNotEmpty) device = devices.first;
      _log.info(
        'Mic devices: ${devices.map((d) => d.label).join(', ')}',
        source: 'VoiceRec',
      );
    } catch (e) {
      _log.warn('listInputDevices failed: $e', source: 'VoiceRec');
    }

    final stream = await _recorder.startStream(
      RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: numChannels,
        device: device,
      ),
    );

    _streamSub = stream.listen(
      _pcm.add,
      onError: (Object e) {
        _log.error('Mic stream error: $e', source: 'VoiceRec');
      },
    );

    _ampSub = _recorder
        .onAmplitudeChanged(const Duration(milliseconds: 200))
        .listen((a) {
      amplitudeDb.value = a.current;
    });

    _startedAt = DateTime.now();
    isRecording.value = true;
    _log.info('PCM stream recording started', source: 'VoiceRec');
  }

  /// Stops capture, writes WAV under ~/.uncensored-ai/voice, keeps bytes in memory.
  Future<File?> stopToWavFile() async {
    if (!isRecording.value && _pcm.isEmpty) {
      try {
        await _recorder.stop();
      } catch (_) {}
      return null;
    }

    await _streamSub?.cancel();
    _streamSub = null;
    await _ampSub?.cancel();
    _ampSub = null;

    try {
      await _recorder.stop();
    } catch (_) {}

    isRecording.value = false;
    final pcm = _pcm.takeBytes();
    _pcm.clear();
    _startedAt = null;

    if (pcm.isEmpty) {
      _log.error('PCM buffer empty after stop', source: 'VoiceRec');
      return null;
    }

    final wavBytes = _pcm16ToWav(pcm, sampleRate, numChannels);
    _lastWavBytes = wavBytes;

    await AppPaths.ensureInitialized();
    final dir = Directory(AppPaths.voiceDir);
    await dir.create(recursive: true);
    final out = File(
      p.join(dir.path, 'voice_ptt_${DateTime.now().millisecondsSinceEpoch}.wav'),
    );
    await out.writeAsBytes(wavBytes, flush: true);
    // Verify immediately
    if (!await out.exists() || await out.length() == 0) {
      _log.error('WAV write verification failed: ${out.path}', source: 'VoiceRec');
      return null;
    }
    _lastWavPath = out.path;
    _log.info('Wrote WAV ${out.path} (${wavBytes.length} bytes)', source: 'VoiceRec');
    return out;
  }

  Future<void> cancel() async {
    await _streamSub?.cancel();
    _streamSub = null;
    await _ampSub?.cancel();
    _ampSub = null;
    try {
      await _recorder.cancel();
    } catch (_) {
      try {
        await _recorder.stop();
      } catch (_) {}
    }
    _pcm.clear();
    isRecording.value = false;
    _startedAt = null;
    amplitudeDb.value = -160;
    _lastWavBytes = null;
    _lastWavPath = null;
  }

  static Uint8List _pcm16ToWav(List<int> pcm, int rate, int channels) {
    final dataSize = pcm.length;
    final byteRate = rate * channels * 2;
    final buffer = BytesBuilder(copy: true);

    void writeString(String s) => buffer.add(s.codeUnits);
    void writeUint32(int v) {
      final b = ByteData(4)..setUint32(0, v, Endian.little);
      buffer.add(b.buffer.asUint8List());
    }

    void writeUint16(int v) {
      final b = ByteData(2)..setUint16(0, v, Endian.little);
      buffer.add(b.buffer.asUint8List());
    }

    writeString('RIFF');
    writeUint32(36 + dataSize);
    writeString('WAVE');
    writeString('fmt ');
    writeUint32(16);
    writeUint16(1);
    writeUint16(channels);
    writeUint32(rate);
    writeUint32(byteRate);
    writeUint16(channels * 2);
    writeUint16(16);
    writeString('data');
    writeUint32(dataSize);
    buffer.add(Uint8List.fromList(pcm));
    return buffer.toBytes();
  }

  @override
  void onClose() {
    unawaited(cancel());
    unawaited(_recorder.dispose());
    super.onClose();
  }
}
