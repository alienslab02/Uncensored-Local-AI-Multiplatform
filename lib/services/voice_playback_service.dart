import 'dart:async';
import 'dart:io';

import 'package:get/get.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;

import 'app_paths.dart';

/// Serial queue of wav chunks under ~/.uncensored-ai/voice.
class VoicePlaybackService extends GetxService {
  final AudioPlayer _player = AudioPlayer();
  final _queue = <File>[];
  var _playing = false;
  final isPlaying = false.obs;

  bool get hasQueuedAudio => _queue.isNotEmpty || _playing;

  Future<Directory> _dir() async {
    await AppPaths.ensureInitialized();
    final d = Directory(p.join(AppPaths.voiceDir, 'playback'));
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<void> enqueueWavBytes(List<int> bytes, {String? name}) async {
    final dir = await _dir();
    final file = File(
      p.join(
        dir.path,
        name ?? 'chunk_${DateTime.now().microsecondsSinceEpoch}.wav',
      ),
    );
    await file.writeAsBytes(bytes, flush: true);
    _queue.add(file);
    unawaited(_pump());
  }

  Future<void> _pump() async {
    if (_playing) return;
    _playing = true;
    isPlaying.value = true;
    try {
      while (_queue.isNotEmpty) {
        final file = _queue.removeAt(0);
        await _player.setFilePath(file.path);
        await _player.play();
        await _player.playerStateStream.firstWhere(
          (s) => s.processingState == ProcessingState.completed,
        );
        try {
          await file.delete();
        } catch (_) {}
      }
    } finally {
      _playing = false;
      isPlaying.value = false;
    }
  }

  Future<void> stop() async {
    _queue.clear();
    await _player.stop();
    _playing = false;
    isPlaying.value = false;
  }

  @override
  void onClose() {
    _player.dispose();
    super.onClose();
  }
}
