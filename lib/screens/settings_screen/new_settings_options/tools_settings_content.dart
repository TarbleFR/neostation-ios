import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/l10n/pairing_file_locale.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/pairing_file_service.dart';
import 'package:neostation/widgets/custom_notification.dart';
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

  @override
  void initState() {
    super.initState();
    _refreshPairingState();
  }

  int getItemCount() => 1;

  void scrollToIndex(int index) {}

  void selectItem(int index) {
    if (index == 0) {
      _importOrReplacePairingFile();
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
    final isSelected =
        widget.isContentFocused && widget.selectedContentIndex == 0;

    final status = !_pairingStateLoaded
        ? PairingFileLocale.get(context, PairingFileLocale.checking)
        : _hasPairingFile
        ? PairingFileLocale.get(context, PairingFileLocale.configured)
        : PairingFileLocale.get(context, PairingFileLocale.notConfigured);

    final description = _hasPairingFile
        ? PairingFileLocale.get(
            context,
            PairingFileLocale.configuredSubtitle,
          )
        : PairingFileLocale.get(
            context,
            PairingFileLocale.notConfiguredSubtitle,
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
                subtitle:
                    '$status — $description\nJIT: MeloNX • ARMSX2 • RPCS3',
                subtitleMaxLines: 4,
                selected: isSelected,
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
                        selected: isSelected,
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
