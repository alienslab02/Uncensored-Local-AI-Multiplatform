import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/voice_chat_controller.dart';
import '../theme/app_colors.dart';

/// Always-visible voice turn status above the composer.
class VoiceStatusBar extends StatelessWidget {
  const VoiceStatusBar({super.key});

  @override
  Widget build(BuildContext context) {
    final voice = Get.find<VoiceChatController>();

    return Obx(() {
      final phase = voice.phase.value;
      if (phase == VoiceChatPhase.idle) {
        return const SizedBox.shrink();
      }

      final Color color;
      switch (phase) {
        case VoiceChatPhase.recording:
          color = AppColors.red;
        case VoiceChatPhase.error:
          color = AppColors.red;
        case VoiceChatPhase.speaking:
          color = AppColors.green;
        default:
          color = AppColors.accent;
      }

      return Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Row(
          children: [
            Icon(
              phase == VoiceChatPhase.recording
                  ? Icons.mic
                  : phase == VoiceChatPhase.speaking
                      ? Icons.volume_up_rounded
                      : phase == VoiceChatPhase.error
                          ? Icons.error_outline
                          : Icons.auto_awesome,
              size: 18,
              color: color,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                voice.statusText.value,
                style: TextStyle(
                  fontSize: 13,
                  color: context.text,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            if (phase == VoiceChatPhase.recording ||
                phase == VoiceChatPhase.thinking ||
                phase == VoiceChatPhase.speaking ||
                phase == VoiceChatPhase.transcribing)
              TextButton(
                onPressed: voice.cancel,
                child: const Text('Cancel'),
              ),
          ],
        ),
      );
    });
  }
}
