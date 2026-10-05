import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/voice_chat_controller.dart';
import '../services/voice_recorder_service.dart';
import '../services/voice_runtime_service.dart';
import '../theme/app_colors.dart';

/// Hold to talk (same as Right ⌥ keyboard PTT).
class VoicePttButton extends StatelessWidget {
  const VoicePttButton({super.key});

  @override
  Widget build(BuildContext context) {
    final voice = Get.find<VoiceChatController>();
    final runtime = Get.find<VoiceRuntimeService>();
    final recorder = Get.find<VoiceRecorderService>();

    return Obx(() {
      final phase = voice.phase.value;
      final starting =
          phase == VoiceChatPhase.starting || runtime.isStarting.value;
      final listening = phase == VoiceChatPhase.recording;
      final errored = phase == VoiceChatPhase.error;
      final processing = voice.isProcessing && !listening && !starting;
      final hearing = listening && recorder.amplitudeDb.value > -45;
      final armed = !starting && !processing;

      final Color bg;
      final Color fg;
      final IconData icon;
      if (listening) {
        bg = hearing ? AppColors.red : AppColors.red.withValues(alpha: 0.75);
        fg = Colors.white;
        icon = Icons.mic_rounded;
      } else if (errored) {
        bg = AppColors.red.withValues(alpha: 0.2);
        fg = AppColors.red;
        icon = Icons.mic_off_rounded;
      } else if (starting || processing) {
        bg = AppColors.accent.withValues(alpha: 0.25);
        fg = AppColors.accent;
        icon = Icons.hourglass_top_rounded;
      } else {
        bg = AppColors.accent;
        fg = Colors.white;
        icon = Icons.mic_rounded;
      }

      return Tooltip(
        message: listening
            ? 'Release to send'
            : 'Hold ${VoiceChatController.pttKeyLabel} or mic to talk',
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: armed
              ? (_) {
                  voice.onPttPress();
                }
              : null,
          onPointerUp: (_) {
            voice.onPttRelease();
          },
          onPointerCancel: (_) {
            voice.onPttRelease();
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: bg,
              shape: BoxShape.circle,
              boxShadow: hearing
                  ? [
                      BoxShadow(
                        color: AppColors.red.withValues(alpha: 0.45),
                        blurRadius: 10,
                      ),
                    ]
                  : null,
            ),
            child: (starting || processing)
                ? Padding(
                    padding: const EdgeInsets.all(8),
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: fg,
                    ),
                  )
                : Icon(icon, color: fg, size: 20),
          ),
        ),
      );
    });
  }
}
