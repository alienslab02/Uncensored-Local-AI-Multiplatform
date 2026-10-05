import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../theme/app_colors.dart';
import '../controllers/chat_controller.dart';
import '../controllers/theme_controller.dart';
import '../controllers/model_controller.dart';
import '../services/local_api_server_service.dart';
import '../services/model_manager.dart';
import '../services/background_optimizer_service.dart';
import '../services/chat_storage_service.dart';
import '../services/voice_runtime_service.dart';

class SettingsScreen extends StatelessWidget {
  /// When true, no Scaffold — just the body content for embedding in tabs.
  final bool embedded;

  const SettingsScreen({super.key, this.embedded = false});

  @override
  Widget build(BuildContext context) {
    if (embedded) {
      return _SettingsBody(showBackButton: false);
    }
    return Scaffold(
      backgroundColor: context.bg,
      body: _SettingsBody(showBackButton: true),
    );
  }
}

class _SettingsBody extends StatelessWidget {
  final bool showBackButton;

  const _SettingsBody({this.showBackButton = false});

  @override
  Widget build(BuildContext context) {
    final chatCtrl = Get.find<ChatController>();
    final modelManager = Get.find<ModelManager>();
    final themeCtrl = Get.find<ThemeController>();
    final apiServer = Get.find<LocalApiServerService>();
    final storage = Get.find<ChatStorageService>();

    return Column(
      children: [
        // ── Top bar ──────────────────────────────────
        Container(
          padding: EdgeInsets.only(
            top: showBackButton ? MediaQuery.of(context).padding.top : 0,
            left: 4,
            right: 4,
          ),
          decoration: BoxDecoration(
            color: context.bg,
            border: Border(
              bottom: BorderSide(color: context.border, width: 0.5),
            ),
          ),
          child: SizedBox(
            height: 52,
            child: Row(
              children: [
                if (showBackButton)
                  IconButton(
                    icon: Icon(Icons.arrow_back_rounded, color: context.text),
                    onPressed: () => Get.back(),
                  ),
                if (!showBackButton) const SizedBox(width: 16),
                Text(
                  'Settings',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: context.text,
                  ),
                ),
              ],
            ),
          ),
        ),

        // ── Body ─────────────────────────────────────
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              // ── Appearance ────────────────────────────────
              _sectionHeader(context, 'Appearance'),
              const SizedBox(height: 12),
              _card(
                context,
                child: Obx(
                  () => SwitchListTile(
                    title: Text(
                      'Dark Mode',
                      style: TextStyle(color: context.text, fontSize: 14),
                    ),
                    subtitle: Text(
                      themeCtrl.isDarkMode
                          ? 'Using dark theme'
                          : 'Using light theme',
                      style: TextStyle(color: context.textD, fontSize: 12),
                    ),
                    secondary: Icon(
                      themeCtrl.isDarkMode
                          ? Icons.dark_mode_rounded
                          : Icons.light_mode_rounded,
                      color: context.textM,
                    ),
                    value: themeCtrl.isDarkMode,
                    onChanged: (val) => themeCtrl.toggleTheme(),
                    activeThumbColor: AppColors.accent,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                  ),
                ),
              ),

              if (Platform.isAndroid) ...[
                const SizedBox(height: 12),
                _card(
                  context,
                  child: ListTile(
                    title: Text(
                      'Battery Optimization',
                      style: TextStyle(color: context.text, fontSize: 14),
                    ),
                    subtitle: Text(
                      'Disable to prevent background killing',
                      style: TextStyle(color: context.textD, fontSize: 12),
                    ),
                    trailing: FutureBuilder<bool>(
                      future: BackgroundOptimizerService.isOptimizationDisabled(),
                      builder: (context, snapshot) {
                        final disabled = snapshot.data ?? false;
                        if (disabled) {
                          return const Icon(Icons.check_circle_rounded,
                              color: AppColors.green, size: 20);
                        }
                        return const Icon(Icons.arrow_forward_ios_rounded,
                            size: 14, color: AppColors.orange);
                      },
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    onTap: () async {
                      await BackgroundOptimizerService.openBatterySettings();
                      // Ignore setState, it will rebuild on next visit
                    },
                  ),
                ),
              ],

              const SizedBox(height: 28),

              // ── System Prompt ─────────────────────────────
              _sectionHeader(context, 'Global System Prompt'),
              const SizedBox(height: 8),
              Text(
                'Applied to all new chats. Existing chats keep their own prompt.',
                style: TextStyle(fontSize: 12, color: context.textD),
              ),
              const SizedBox(height: 12),
              Obx(
                () => TextField(
                  controller:
                      TextEditingController(text: chatCtrl.systemPrompt.value)
                        ..selection = TextSelection.fromPosition(
                          TextPosition(
                            offset: chatCtrl.systemPrompt.value.length,
                          ),
                        ),
                  maxLines: 4,
                  style: TextStyle(
                    fontSize: 14,
                    color: context.text,
                    height: 1.5,
                  ),
                  decoration: InputDecoration(
                    hintText: 'e.g. You are a helpful assistant...',
                    hintStyle: TextStyle(color: context.textD),
                    filled: true,
                    fillColor: context.bgInput,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: context.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: context.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: AppColors.accent),
                    ),
                  ),
                  onChanged: (v) => chatCtrl.setGlobalSystemPrompt(v),
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () {
                    chatCtrl.clearGlobalSystemPrompt();
                    Get.snackbar(
                      'Cleared',
                      'Global system prompt removed.',
                      snackPosition: SnackPosition.BOTTOM,
                    );
                  },
                  icon: const Icon(Icons.clear_rounded, size: 16),
                  style: TextButton.styleFrom(foregroundColor: AppColors.red),
                  label: const Text(
                    'Clear Prompt',
                    style: TextStyle(fontSize: 13),
                  ),
                ),
              ),

              const SizedBox(height: 28),

              // ── Temperature ───────────────────────────────
              _sectionHeader(context, 'Temperature'),
              const SizedBox(height: 12),
              _card(
                context,
                child: Obx(
                  () => Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.thermostat_rounded,
                          size: 20,
                          color: context.textM,
                        ),
                        Expanded(
                          child: Slider(
                            value: chatCtrl.temperature.value,
                            min: 0.0,
                            max: 2.0,
                            divisions: 20,
                            activeColor: AppColors.accent,
                            inactiveColor: context.border,
                            label: chatCtrl.temperature.value.toStringAsFixed(
                              1,
                            ),
                            onChanged: (v) => chatCtrl.updateTemperature(v),
                          ),
                        ),
                        Container(
                          width: 44,
                          alignment: Alignment.center,
                          child: Text(
                            chatCtrl.temperature.value.toStringAsFixed(1),
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: context.text,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 28),

              // ── Hardware Configuration ──────────────────────────
              _sectionHeader(context, 'Hardware Configuration'),
              const SizedBox(height: 8),
              _HardwareSettingsCard(storage: storage),

              const SizedBox(height: 28),

              // ── Voice TTS ─────────────────────────────────
              if (Platform.isMacOS) ...[
                _sectionHeader(context, 'Voice TTS'),
                const SizedBox(height: 8),
                Text(
                  'Choose the local speech engine. Changes restart the voice sidecar.',
                  style: TextStyle(fontSize: 12, color: context.textD),
                ),
                const SizedBox(height: 12),
                _VoiceTtsSettingsCard(storage: storage),
                const SizedBox(height: 20),
                _sectionHeader(context, 'Voices'),
                const SizedBox(height: 8),
                Text(
                  'Pick a speaking voice. Chatterbox uses clone WAVs; Kokoro uses built-in presets. '
                  'Add your own WAV (clear speech, ideally >5s) for a custom clone.',
                  style: TextStyle(fontSize: 12, color: context.textD),
                ),
                const SizedBox(height: 12),
                const _VoicePickerCard(),
                const SizedBox(height: 28),
              ],

              // ── Local API Server ──────────────────────────
              _sectionHeader(context, 'Local API Server'),
              const SizedBox(height: 8),
              Text(
                'Expose the loaded model to OpenAI-compatible local clients.',
                style: TextStyle(fontSize: 12, color: context.textD),
              ),
              const SizedBox(height: 12),
              _card(
                context,
                child: Obx(() {
                  final running = apiServer.isRunning.value;
                  final starting = apiServer.isStarting.value;
                  final ready = apiServer.hasLoadedModel;
                  final busy = apiServer.isBusy;
                  final statusText = starting
                      ? 'Starting'
                      : running
                      ? ready
                            ? busy
                                  ? 'Busy'
                                  : 'Running'
                            : 'No model loaded'
                      : 'Stopped';
                  final statusColor = running && ready
                      ? AppColors.green
                      : running
                      ? AppColors.orange
                      : context.textD;

                  return Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SwitchListTile(
                          title: Text(
                            'Local API server',
                            style: TextStyle(color: context.text, fontSize: 14),
                          ),
                          subtitle: Text(
                            'OpenAI base URL: ${apiServer.baseUrl}',
                            style: TextStyle(
                              color: context.textD,
                              fontSize: 12,
                            ),
                          ),
                          secondary: Icon(
                            Icons.api_rounded,
                            color: running ? AppColors.accent : context.textM,
                          ),
                          value: running,
                          onChanged: starting
                              ? null
                              : (enabled) async {
                                  try {
                                    if (enabled) {
                                      await apiServer.start();
                                    } else {
                                      await apiServer.stop();
                                    }
                                  } catch (e) {
                                    Get.snackbar(
                                      'Local API Error',
                                      e.toString(),
                                      snackPosition: SnackPosition.BOTTOM,
                                    );
                                  }
                                },
                          activeThumbColor: AppColors.accent,
                          contentPadding: EdgeInsets.zero,
                        ),
                        const SizedBox(height: 12),
                        SwitchListTile(
                          title: Text(
                            'Allow External Connections',
                            style: TextStyle(color: context.text, fontSize: 14),
                          ),
                          subtitle: Text(
                            'Listen on 0.0.0.0 instead of localhost',
                            style: TextStyle(
                              color: context.textD,
                              fontSize: 12,
                            ),
                          ),
                          value: apiServer.allInterfaces.value,
                          onChanged: starting
                              ? null
                              : (enabled) async {
                                  try {
                                    await apiServer.setAllInterfaces(enabled);
                                  } catch (e) {
                                    Get.snackbar(
                                      'Settings Error',
                                      e.toString(),
                                      snackPosition: SnackPosition.BOTTOM,
                                    );
                                  }
                                },
                          activeThumbColor: AppColors.orange,
                          contentPadding: EdgeInsets.zero,
                        ),
                        if (apiServer.allInterfaces.value)
                          Container(
                            margin: const EdgeInsets.only(top: 4, bottom: 8),
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: AppColors.orange.withOpacity(0.1),
                              border: Border.all(color: AppColors.orange.withOpacity(0.3)),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.warning_amber_rounded, size: 16, color: AppColors.orange),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Anyone on your network can access your loaded model.',
                                    style: TextStyle(fontSize: 11, color: context.text),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            _statusChip(context, statusText, statusColor),
                            const SizedBox(width: 10),
                            Expanded(
                              child: FutureBuilder<String?>(
                                future: apiServer.allInterfaces.value
                                    ? apiServer.getDeviceIp()
                                    : Future.value(null),
                                builder: (context, snapshot) {
                                  String url = apiServer.baseUrl;
                                  if (apiServer.allInterfaces.value && snapshot.hasData) {
                                    url = 'http://${snapshot.data}:${apiServer.port.value}/v1';
                                  }
                                  return SelectableText(
                                    url,
                                    style: TextStyle(
                                      color: context.text,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  );
                                }
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          key: ValueKey('api-port-${apiServer.port.value}'),
                          initialValue: apiServer.port.value.toString(),
                          keyboardType: TextInputType.number,
                          style: TextStyle(color: context.text, fontSize: 13),
                          decoration: InputDecoration(
                            labelText: 'Port',
                            helperText:
                                'Use API key "local" in clients that require one.',
                            labelStyle: TextStyle(color: context.textM),
                            helperStyle: TextStyle(
                              color: context.textD,
                              fontSize: 11,
                            ),
                            filled: true,
                            fillColor: context.bgInput,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide(color: context.border),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide(color: context.border),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: const BorderSide(
                                color: AppColors.accent,
                              ),
                            ),
                          ),
                          onFieldSubmitted: (value) async {
                            final parsed = int.tryParse(value.trim());
                            if (parsed == null ||
                                parsed < 1024 ||
                                parsed > 65535) {
                              Get.snackbar(
                                'Invalid Port',
                                'Choose a port from 1024 to 65535.',
                                snackPosition: SnackPosition.BOTTOM,
                              );
                              return;
                            }
                            try {
                              await apiServer.setPort(parsed);
                              Get.snackbar(
                                'Local API Updated',
                                'Base URL is ${apiServer.baseUrl}',
                                snackPosition: SnackPosition.BOTTOM,
                              );
                            } catch (e) {
                              Get.snackbar(
                                'Local API Error',
                                e.toString(),
                                snackPosition: SnackPosition.BOTTOM,
                              );
                            }
                          },
                        ),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: () {
                              Get.toNamed('/api-endpoints');
                            },
                            icon: const Icon(Icons.api_rounded, size: 18),
                            label: const Text('Sample Endpoints & Testing'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: context.text,
                              side: BorderSide(color: context.border),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                          ),
                        ),
                        if (apiServer.errorMessage.value.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Text(
                            apiServer.errorMessage.value,
                            style: const TextStyle(
                              color: AppColors.red,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ],
                    ),
                  );
                }),
              ),

              const SizedBox(height: 28),

              // ── Storage ───────────────────────────────────
              _sectionHeader(context, 'Storage'),
              const SizedBox(height: 12),
              _card(
                context,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Icon(
                        Icons.folder_outlined,
                        size: 20,
                        color: context.textM,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          modelManager.modelsDir,
                          style: TextStyle(fontSize: 13, color: context.text),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 28),

              // ── Danger Zone ───────────────────────────────
              _sectionHeader(context, 'Danger Zone'),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.delete_forever_rounded, size: 18),
                label: const Text(
                  'Delete All Chats',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                ),
                onPressed: () {
                  Get.dialog(
                    AlertDialog(
                      backgroundColor: context.bgPanel,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      title: Text(
                        'Delete All Chats?',
                        style: TextStyle(color: context.text),
                      ),
                      content: Text(
                        'This cannot be undone.',
                        style: TextStyle(color: context.textM),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Get.back(),
                          child: Text(
                            'Cancel',
                            style: TextStyle(color: context.textD),
                          ),
                        ),
                        ElevatedButton(
                          onPressed: () {
                            chatCtrl.chats.clear();
                            chatCtrl.activeChatId.value = null;
                            Get.back();
                            Get.snackbar(
                              'Done',
                              'All chats deleted.',
                              snackPosition: SnackPosition.BOTTOM,
                            );
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.red,
                            elevation: 0,
                          ),
                          child: const Text(
                            'Delete All',
                            style: TextStyle(color: Colors.white),
                          ),
                        ),
                      ],
                    ),
                  );
                },
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.red,
                  side: const BorderSide(color: AppColors.red),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),

              const SizedBox(height: 12),
              
              OutlinedButton.icon(
                icon: const Icon(Icons.cleaning_services_rounded, size: 18),
                label: const Text(
                  'Clear Temporary Cache',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                ),
                onPressed: () => Get.find<ModelController>().clearCache(),
                style: OutlinedButton.styleFrom(
                  foregroundColor: context.text,
                  side: BorderSide(color: context.border),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),

              const SizedBox(height: 40),

              // ── About ─────────────────────────────────────
              Center(
                child: Column(
                  children: [
                    Text(
                      'Mate v2.0.0',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: context.textM,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Powered by llamadart + llama.cpp',
                      style: TextStyle(fontSize: 11, color: context.textD),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 28),

              // ── App Logs ──────────────────────────────────
              _sectionHeader(context, 'Debugging'),
              const SizedBox(height: 8),
              _card(
                context,
                child: ListTile(
                  leading: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: AppColors.orange.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.article_outlined,
                        size: 18, color: AppColors.orange),
                  ),
                  title: Text(
                    'App Logs',
                    style: TextStyle(color: context.text, fontSize: 14),
                  ),
                  subtitle: Text(
                    'View logs, errors & share with developers',
                    style: TextStyle(color: context.textD, fontSize: 12),
                  ),
                  trailing: Icon(Icons.arrow_forward_ios_rounded,
                      size: 14, color: context.textD),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  onTap: () => Get.toNamed('/logs'),
                ),
              ),

              const SizedBox(height: 32),
            ],
          ),
        ),
      ],
    );
  }

  Widget _sectionHeader(BuildContext context, String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: context.textM,
        letterSpacing: 0.3,
      ),
    );
  }

  Widget _card(BuildContext context, {required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        color: context.bgPanel,
        border: Border.all(color: context.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: child,
    );
  }

  Widget _statusChip(BuildContext context, String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _VoiceTtsSettingsCard extends StatefulWidget {
  final ChatStorageService storage;

  const _VoiceTtsSettingsCard({required this.storage});

  @override
  State<_VoiceTtsSettingsCard> createState() => _VoiceTtsSettingsCardState();
}

class _VoiceTtsSettingsCardState extends State<_VoiceTtsSettingsCard> {
  late String _selected;
  bool _applying = false;

  VoiceRuntimeService get _voice => Get.find<VoiceRuntimeService>();

  @override
  void initState() {
    super.initState();
    _selected = _voice.resolvedTtsBackend;
    unawaited(_voice.ping());
  }

  Future<void> _apply(String id) async {
    if (_applying || envLocked) return;
    setState(() {
      _selected = id;
      _applying = true;
    });
    final ok = await _voice.applyTtsBackend(id);
    if (!mounted) return;
    setState(() => _applying = false);
    Get.snackbar(
      ok ? 'Voice TTS' : 'Voice TTS Error',
      ok
          ? (_voice.fallbackUsed.value
              ? 'Active: ${_voice.activeBackend.value} (fallback)'
              : 'Active: ${_voice.activeBackend.value}')
          : _voice.lastError.value,
      snackPosition: SnackPosition.BOTTOM,
    );
  }

  bool get envLocked => _voice.envOverridesBackend;

  @override
  Widget build(BuildContext context) {
    final options = VoiceRuntimeService.ttsBackendOptions;
    final envLocked = _voice.envOverridesBackend;

    return Container(
      decoration: BoxDecoration(
        color: context.bgPanel,
        border: Border.all(color: context.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.record_voice_over_rounded, color: AppColors.accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Speech engine',
                    style: TextStyle(
                      color: context.text,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Obx(() {
                  final active = _voice.activeBackend.value;
                  if (active.isEmpty) {
                    return Text(
                      'Not running',
                      style: TextStyle(color: context.textD, fontSize: 12),
                    );
                  }
                  return Text(
                    _voice.fallbackUsed.value ? '$active (fallback)' : active,
                    style: TextStyle(
                      color: AppColors.green,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  );
                }),
              ],
            ),
            if (envLocked) ...[
              const SizedBox(height: 10),
              Text(
                'Locked by shell env VOICE_TTS_BACKEND=${_voice.resolvedTtsBackend}. '
                'Unset it to change from Settings.',
                style: TextStyle(fontSize: 12, color: AppColors.orange),
              ),
            ],
            const SizedBox(height: 12),
            ...options.map((opt) {
              final selected = _selected == opt.id;
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Material(
                  color: selected
                      ? AppColors.accent.withValues(alpha: 0.12)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: (_applying || envLocked)
                        ? null
                        : () => _apply(opt.id),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 10,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            selected
                                ? Icons.radio_button_checked
                                : Icons.radio_button_off,
                            size: 20,
                            color: selected
                                ? AppColors.accent
                                : context.textM,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  opt.label,
                                  style: TextStyle(
                                    color: context.text,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  opt.blurb,
                                  style: TextStyle(
                                    color: context.textD,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }),
            if (_applying) ...[
              const SizedBox(height: 8),
              Obx(
                () => Text(
                  _voice.statusMessage.value.isEmpty
                      ? 'Switching engine…'
                      : _voice.statusMessage.value,
                  style: TextStyle(fontSize: 12, color: context.textM),
                ),
              ),
            ],
            const SizedBox(height: 4),
            Text(
              'CLI: export VOICE_TTS_BACKEND=kokoro|chatterbox_nano|…',
              style: TextStyle(fontSize: 11, color: context.textD),
            ),
          ],
        ),
      ),
    );
  }
}

class _VoicePickerCard extends StatefulWidget {
  const _VoicePickerCard();

  @override
  State<_VoicePickerCard> createState() => _VoicePickerCardState();
}

class _VoicePickerCardState extends State<_VoicePickerCard> {
  bool _importing = false;

  VoiceRuntimeService get _voice => Get.find<VoiceRuntimeService>();

  @override
  void initState() {
    super.initState();
    unawaited(_voice.refreshVoices());
  }

  Future<void> _pickAndImport() async {
    if (_importing) return;
    setState(() => _importing = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['wav'],
        allowMultiple: false,
        withData: false,
      );
      final path = result?.files.single.path;
      if (path == null || path.isEmpty) return;
      final opt = await _voice.importReferenceWav(path);
      if (!mounted) return;
      Get.snackbar(
        opt != null ? 'Voice added' : 'Import failed',
        opt != null
            ? 'Selected “${opt.label}”. Use a Chatterbox engine for clones.'
            : _voice.lastError.value,
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 5),
      );
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _select(VoiceOption opt) async {
    await _voice.applyTtsVoice(opt.id);
    if (!mounted) return;
    Get.snackbar(
      'Voice',
      'Using “${opt.label}”',
      snackPosition: SnackPosition.BOTTOM,
      duration: const Duration(seconds: 2),
    );
  }

  Future<void> _confirmDelete(VoiceOption opt) async {
    if (!opt.isReference) return;
    final ok = await Get.dialog<bool>(
          AlertDialog(
            title: const Text('Remove voice?'),
            content: Text(
              'Delete “${opt.label}” from your custom clones? '
              'This removes the WAV file from Mate’s voice library.',
            ),
            actions: [
              TextButton(
                onPressed: () => Get.back(result: false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Get.back(result: true),
                child: Text(
                  'Remove',
                  style: TextStyle(color: AppColors.red),
                ),
              ),
            ],
          ),
        ) ??
        false;
    if (!ok) return;
    final deleted = await _voice.deleteReferenceVoice(opt.id);
    if (!mounted) return;
    Get.snackbar(
      deleted ? 'Voice removed' : 'Remove failed',
      deleted ? '“${opt.label}” deleted' : _voice.lastError.value,
      snackPosition: SnackPosition.BOTTOM,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: context.bgPanel,
        border: Border.all(color: context.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Obx(() {
          final list = _voice.voices.toList();
          final selected = _voice.selectedVoiceId.value;
          final loading = _voice.voicesLoading.value;
          final backend = _voice.activeBackend.value.isNotEmpty
              ? _voice.activeBackend.value
              : _voice.resolvedTtsBackend;
          final refs =
              list.where((v) => v.isReference).toList(growable: false);
          final kokoro =
              list.where((v) => v.isKokoro).toList(growable: false);

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.voice_chat_rounded, color: AppColors.accent),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Speaking voice',
                      style: TextStyle(
                        color: context.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: loading
                        ? null
                        : () => unawaited(_voice.refreshVoices()),
                    icon: loading
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('Refresh'),
                  ),
                ],
              ),
              Text(
                'Engine: $backend',
                style: TextStyle(fontSize: 12, color: context.textD),
              ),
              if (_voice.envOverridesVoice) ...[
                const SizedBox(height: 8),
                Text(
                  'Locked by VOICE_TTS_VOICE=${_voice.resolvedTtsVoice}',
                  style: TextStyle(fontSize: 12, color: AppColors.orange),
                ),
              ],
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: (_importing || _voice.envOverridesVoice)
                      ? null
                      : _pickAndImport,
                  icon: _importing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.add_rounded, size: 18),
                  label: Text(
                    _importing ? 'Importing…' : 'Add voice (WAV)',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: context.text,
                    side: BorderSide(color: context.border),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              if (list.isEmpty && !loading)
                Text(
                  'No voices yet — start the voice sidecar or add a WAV.',
                  style: TextStyle(fontSize: 12, color: context.textM),
                ),
              if (refs.isNotEmpty) ...[
                Text(
                  'Custom clones (Chatterbox)',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: context.textM,
                  ),
                ),
                const SizedBox(height: 6),
                ...refs.map((v) => _voiceTile(context, v, selected)),
                const SizedBox(height: 10),
              ],
              if (kokoro.isNotEmpty) ...[
                Text(
                  'Built-in presets (Kokoro)',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: context.textM,
                  ),
                ),
                const SizedBox(height: 6),
                SizedBox(
                  height: 220,
                  child: ListView.builder(
                    itemCount: kokoro.length,
                    itemBuilder: (context, i) =>
                        _voiceTile(context, kokoro[i], selected),
                  ),
                ),
              ],
              const SizedBox(height: 6),
              Text(
                'Tip: for a custom voice, add a WAV then keep Chatterbox as the engine. '
                'Kokoro presets need the Kokoro engine.',
                style: TextStyle(fontSize: 11, color: context.textD),
              ),
            ],
          );
        }),
      ),
    );
  }

  Widget _voiceTile(BuildContext context, VoiceOption v, String selected) {
    final isSel = selected == v.id;
    final locked = _voice.envOverridesVoice;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: isSel
            ? AppColors.accent.withValues(alpha: 0.12)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: locked ? null : () => unawaited(_select(v)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                Icon(
                  isSel
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  size: 18,
                  color: isSel ? AppColors.accent : context.textM,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        v.label,
                        style: TextStyle(
                          color: context.text,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        v.isReference
                            ? 'Clone WAV · ${v.id}'
                            : 'Preset · ${v.id}',
                        style: TextStyle(
                          color: context.textD,
                          fontSize: 11,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (v.isReference)
                  IconButton(
                    tooltip: 'Remove voice',
                    onPressed: locked
                        ? null
                        : () => unawaited(_confirmDelete(v)),
                    icon: Icon(
                      Icons.delete_outline_rounded,
                      size: 20,
                      color: context.textM,
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HardwareSettingsCard extends StatefulWidget {
  final ChatStorageService storage;

  const _HardwareSettingsCard({required this.storage});

  @override
  State<_HardwareSettingsCard> createState() => _HardwareSettingsCardState();
}

class _HardwareSettingsCardState extends State<_HardwareSettingsCard> {
  late String _backend;
  late double _gpuLayers;
  bool _showManual = false;

  // Auto-detect the best backend and GPU layers for this device
  static Map<String, dynamic> _detectBestConfig() {
    if (!Platform.isAndroid && !Platform.isIOS) {
      // Desktop: CPU is safest, Vulkan if available
      return {'backend': 'cpu', 'gpuLayers': 0, 'reason': 'CPU mode — most compatible on desktop'};
    }

    // Android/iOS: detect available RAM and processor count
    final cores = Platform.numberOfProcessors;
    
    if (cores >= 8) {
      // High-end device (e.g. Snapdragon 8 Gen 2+, Dimensity 9000+)
      return {
        'backend': 'opencl',
        'gpuLayers': 33,
        'reason': 'OpenCL GPU — best for high-end SoC ($cores cores detected)',
      };
    } else if (cores >= 6) {
      // Mid-range device
      return {
        'backend': 'cpu',
        'gpuLayers': 0,
        'reason': 'CPU mode — safe for mid-range devices ($cores cores)',
      };
    } else {
      // Low-end device
      return {
        'backend': 'cpu',
        'gpuLayers': 0,
        'reason': 'CPU mode — optimized for lower-end devices ($cores cores)',
      };
    }
  }

  @override
  void initState() {
    super.initState();
    _backend = widget.storage.backendType;
    _gpuLayers = widget.storage.gpuLayers.toDouble();
  }

  void _applyAutoConfig() {
    final config = _detectBestConfig();
    setState(() {
      _backend = config['backend'] as String;
      _gpuLayers = (config['gpuLayers'] as int).toDouble();
    });
    widget.storage.backendType = _backend;
    widget.storage.gpuLayers = _gpuLayers.toInt();
    Get.snackbar(
      'Auto Config Applied',
      config['reason'] as String,
      snackPosition: SnackPosition.BOTTOM,
      duration: const Duration(seconds: 2),
    );
  }

  void _saveBackend(String val) {
    setState(() => _backend = val);
    widget.storage.backendType = val;
    // Auto-set sensible GPU layers when switching
    if (val == 'cpu') {
      setState(() => _gpuLayers = 0);
      widget.storage.gpuLayers = 0;
    } else if (_gpuLayers == 0) {
      setState(() => _gpuLayers = 33);
      widget.storage.gpuLayers = 33;
    }
  }

  void _saveGpuLayers(double val) {
    setState(() => _gpuLayers = val);
    widget.storage.gpuLayers = val.toInt();
  }

  String get _currentConfigLabel {
    switch (_backend) {
      case 'vulkan':
        return 'GPU (Vulkan) • ${_gpuLayers.toInt()} layers';
      case 'opencl':
        return 'GPU (OpenCL) • ${_gpuLayers.toInt()} layers';
      default:
        return 'CPU Only';
    }
  }

  @override
  Widget build(BuildContext context) {
    final autoConfig = _detectBestConfig();

    return Container(
      decoration: BoxDecoration(
        color: context.bgPanel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.border),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Recommended Auto Config ──
          Row(
            children: [
              Icon(Icons.auto_awesome_rounded, size: 18, color: AppColors.accent),
              const SizedBox(width: 8),
              Text(
                'Compute Device',
                style: TextStyle(color: context.text, fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Current: $_currentConfigLabel',
            style: TextStyle(color: context.textM, fontSize: 12),
          ),
          const SizedBox(height: 12),

          // Recommended button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _applyAutoConfig,
              icon: const Icon(Icons.tune_rounded, size: 16),
              label: const Text('Apply Recommended Settings'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.accent.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline_rounded, size: 14, color: AppColors.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    autoConfig['reason'] as String,
                    style: TextStyle(color: context.textM, fontSize: 11),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // ── Manual Override Toggle ──
          InkWell(
            onTap: () => setState(() => _showManual = !_showManual),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Icon(
                    _showManual ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: context.textM,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'Manual Override',
                    style: TextStyle(
                      color: context.textM,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),

          if (_showManual) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                _buildBackendButton('CPU', 'cpu'),
                const SizedBox(width: 8),
                _buildBackendButton('Vulkan', 'vulkan'),
                const SizedBox(width: 8),
                _buildBackendButton('OpenCL', 'opencl'),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'GPU Layers',
                  style: TextStyle(color: context.text, fontSize: 14),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: context.bgInput,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _gpuLayers.toInt().toString(),
                    style: TextStyle(color: context.text, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: AppColors.accent,
                inactiveTrackColor: context.border,
                thumbColor: AppColors.accent,
                overlayColor: AppColors.accent.withValues(alpha: 0.2),
              ),
              child: Slider(
                value: _gpuLayers,
                min: 0,
                max: 99,
                divisions: 99,
                onChanged: _backend == 'cpu' ? null : _saveGpuLayers,
              ),
            ),
            Text(
              'If the app crashes when loading a model, reduce GPU layers or switch to CPU. Reload the model after changing settings.',
              style: TextStyle(color: context.textD, fontSize: 11, height: 1.4),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBackendButton(String label, String value) {
    final selected = _backend == value;
    return Expanded(
      child: InkWell(
        onTap: () => _saveBackend(value),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? AppColors.accent : context.bgInput,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? AppColors.accent : context.border,
            ),
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                color: selected ? Colors.white : context.text,
                fontSize: 12,
                fontWeight: selected ? FontWeight.bold : FontWeight.normal,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}

