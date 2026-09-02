import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/l10n/jit_fallback_locale.dart';
import 'package:neostation/l10n/pairing_file_locale.dart';
import 'package:neostation/services/jit_backend_preference_service.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/pairing_file_service.dart';
import 'package:neostation/widgets/custom_notification.dart';
import 'package:neostation/widgets/custom_toggle_switch.dart';
import 'settings_title.dart';
import 'widgets/settings_card_row.dart';
import 'widgets/settings_action_button.dart';

class ToolsSettingsContent extends StatefulWidget {
  final bool isContentFocused;
  final int selectedContentIndex;

  const ToolsSettingsContent({
    super.key,
    required this.isContentFocused,
    required this.selectedContentIndex,
  });

  @override
  State<ToolsSettingsContent> createState() => ToolsSettingsContentState();
}

class ToolsSettingsContentState extends State<ToolsSettingsContent> {
  static final _log = LoggerService.instance;

  bool _pairingStateLoaded = false;
  bool _hasPairingFile = false;
  bool _isImportingPairingFile = false;

  bool _jitFallbackStateLoaded = false;
  bool _useStikDebugFallback = false;
  bool _isUpdatingJitFallback = false;

  @override
  void initState() {
    super.initState();
    _refreshPairingState();
    _refreshJitFallbackState();
  }

  int getItemCount() => 2;

  void scrollToIndex(int index) {}

  void selectItem(int index) {
    if (index == 0) {
      _importOrReplacePairingFile();
      return;
    }
    if (index == 1 &&
        _jitFallbackStateLoaded &&
        !_isUpdatingJitFallback) {
      _setUseStikDebugFallback(!_useStikDebugFallback);
    }
  }

  Future<void> _refreshPairingState() async {
    try {
      final configured = await PairingFileService.hasStoredPairingFile();
      if (!mounted) return;
      setState(() {
        _hasPairingFile = configured;
        _pairingStateLoaded = true;
      });
    } catch (error, stackTrace) {
      _log.log(
        'Could not inspect the stored pairing file.',
        level: LogLevel.warning,
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      setState(() {
        _hasPairingFile = false;
        _pairingStateLoaded = true;
      });
    }
  }

  Future<void> _refreshJitFallbackState() async {
    try {
      final enabled =
          await JitBackendPreferenceService.useStikDebugFallback();
      if (!mounted) return;
      setState(() {
        _useStikDebugFallback = enabled;
        _jitFallbackStateLoaded = true;
      });
    } catch (error, stackTrace) {
      _log.e(
        'Could not load the global JIT fallback preference.',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      setState(() {
        _useStikDebugFallback = false;
        _jitFallbackStateLoaded = true;
      });
    }
  }

  Future<void> _setUseStikDebugFallback(bool value) async {
    if (!_jitFallbackStateLoaded || _isUpdatingJitFallback) return;

    final previousValue = _useStikDebugFallback;
    setState(() {
      _useStikDebugFallback = value;
      _isUpdatingJitFallback = true;
    });

    try {
      await JitBackendPreferenceService.setUseStikDebugFallback(value);
      if (!mounted) return;
      AppNotification.showNotification(
        context,
        JitFallbackLocale.get(
          context,
          value ? JitFallbackLocale.enabled : JitFallbackLocale.disabled,
        ),
        type: NotificationType.success,
      );
    } catch (error, stackTrace) {
      _log.e(
        'Could not save the global JIT fallback preference.',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      setState(() => _useStikDebugFallback = previousValue);
      AppNotification.showNotification(
        context,
        JitFallbackLocale.get(context, JitFallbackLocale.saveFailed),
        type: NotificationType.error,
      );
    } finally {
      if (mounted) setState(() => _isUpdatingJitFallback = false);
    }
  }

  Future<void> _importOrReplacePairingFile() async {
    if (_isImportingPairingFile) return;

    setState(() => _isImportingPairingFile = true);

    try {
      final result = await PairingFileService.importFromPicker(
        dialogTitle: PairingFileLocale.get(
          context,
          PairingFileLocale.pickerTitle,
        ),
      );
      if (!mounted || result == null) return;

      setState(() {
        _hasPairingFile = true;
        _pairingStateLoaded = true;
      });

      AppNotification.showNotification(
        context,
        PairingFileLocale.get(
          context,
          result.replacedExisting
              ? PairingFileLocale.replaced
              : PairingFileLocale.imported,
        ),
        type: NotificationType.success,
      );
    } on PairingFileException catch (error) {
      if (!mounted) return;
      AppNotification.showNotification(
        context,
        _localizedPairingError(error.error),
        type: NotificationType.error,
      );
    } catch (error, stackTrace) {
      _log.e(
        'Failed to import the pairing file.',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      AppNotification.showNotification(
        context,
        PairingFileLocale.get(
          context,
          PairingFileLocale.importFailed,
        ),
        type: NotificationType.error,
      );
    } finally {
      if (mounted) setState(() => _isImportingPairingFile = false);
    }
  }

  String _localizedPairingError(PairingFileError error) {
    switch (error) {
      case PairingFileError.invalidExtension:
        return PairingFileLocale.get(
          context,
          PairingFileLocale.invalidExtension,
        );
      case PairingFileError.invalidFile:
        return PairingFileLocale.get(
          context,
          PairingFileLocale.invalidFile,
        );
      case PairingFileError.unreadable:
        return PairingFileLocale.get(
          context,
          PairingFileLocale.importFailed,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pairingSelected =
        widget.isContentFocused && widget.selectedContentIndex == 0;
    final fallbackSelected =
        widget.isContentFocused && widget.selectedContentIndex == 1;

    final pairingStatus = !_pairingStateLoaded
        ? PairingFileLocale.get(context, PairingFileLocale.checking)
        : _hasPairingFile
        ? PairingFileLocale.get(context, PairingFileLocale.configured)
        : PairingFileLocale.get(context, PairingFileLocale.notConfigured);

    final pairingDescription = _hasPairingFile
        ? PairingFileLocale.get(
            context,
            PairingFileLocale.configuredSubtitle,
          )
        : PairingFileLocale.get(
            context,
            PairingFileLocale.notConfiguredSubtitle,
          );

    final fallbackStatus = !_jitFallbackStateLoaded
        ? JitFallbackLocale.get(context, JitFallbackLocale.checking)
        : JitFallbackLocale.get(
            context,
            _useStikDebugFallback
                ? JitFallbackLocale.fallbackStatus
                : JitFallbackLocale.integratedStatus,
          );

    final fallbackDescription = JitFallbackLocale.get(
      context,
      _useStikDebugFallback
          ? JitFallbackLocale.fallbackDescription
          : JitFallbackLocale.integratedDescription,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsTitle(
          title: AppLocale.tools.getString(context),
          subtitle: AppLocale.toolsSubtitle.getString(context),
        ),
        SizedBox(height: 12.r),
        Expanded(
          child: ListView(
            physics: const ClampingScrollPhysics(),
            children: [
              SettingsCardRow(
                icon: Symbols.key_rounded,
                title: PairingFileLocale.get(
                  context,
                  PairingFileLocale.title,
                ),
                subtitle: '$pairingStatus — $pairingDescription',
                subtitleMaxLines: 3,
                selected: pairingSelected,
                onTap: _isImportingPairingFile
                    ? null
                    : _importOrReplacePairingFile,
                trailing: _isImportingPairingFile
                    ? SizedBox(
                        width: 22.r,
                        height: 22.r,
                        child: const CircularProgressIndicator(strokeWidth: 2),
                      )
                    : SettingsActionButton(
                        icon: _hasPairingFile
                            ? Symbols.change_circle_rounded
                            : Symbols.upload_file_rounded,
                        selected: pairingSelected,
                      ),
              ),
              SettingsCardRow(
                icon: Symbols.swap_horiz_rounded,
                title: JitFallbackLocale.get(
                  context,
                  JitFallbackLocale.title,
                ),
                subtitle: '$fallbackStatus — $fallbackDescription',
                subtitleMaxLines: 4,
                selected: fallbackSelected,
                onTap: !_jitFallbackStateLoaded || _isUpdatingJitFallback
                    ? null
                    : () => _setUseStikDebugFallback(
                        !_useStikDebugFallback,
                      ),
                trailing: !_jitFallbackStateLoaded || _isUpdatingJitFallback
                    ? SizedBox(
                        width: 22.r,
                        height: 22.r,
                        child: const CircularProgressIndicator(strokeWidth: 2),
                      )
                    : IgnorePointer(
                        child: CustomToggleSwitch(
                          value: _useStikDebugFallback,
                          onChanged: null,
                          activeColor: theme.colorScheme.primary,
                        ),
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
