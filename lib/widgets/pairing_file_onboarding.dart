import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:neostation/l10n/pairing_file_locale.dart';
import 'package:neostation/services/pairing_file_service.dart';

class PairingFileOnboarding extends StatefulWidget {
  const PairingFileOnboarding({
    super.key,
    required this.onFinished,
  });

  final VoidCallback onFinished;

  @override
  State<PairingFileOnboarding> createState() => _PairingFileOnboardingState();
}

class _PairingFileOnboardingState extends State<PairingFileOnboarding> {
  bool _busy = false;
  String? _error;

  Future<void> _choosePairingFile() async {
    if (_busy) return;

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final result = await PairingFileService.importFromPicker(
        dialogTitle: PairingFileLocale.get(
          context,
          PairingFileLocale.pickerTitle,
        ),
      );
      if (!mounted) return;
      if (result != null) {
        widget.onFinished();
      }
    } on PairingFileException catch (error) {
      if (!mounted) return;
      setState(() => _error = _messageFor(error.error));
    } catch (_) {
      if (!mounted) return;
      setState(
        () => _error = PairingFileLocale.get(
          context,
          PairingFileLocale.importFailed,
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _messageFor(PairingFileError error) {
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

    return SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: EdgeInsets.all(24.r),
          child: Container(
            constraints: BoxConstraints(maxWidth: 680.w),
            padding: EdgeInsets.all(28.r),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(28.r),
              border: Border.all(
                color: theme.colorScheme.primary.withValues(alpha: 0.22),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Symbols.key_rounded,
                  size: 58.r,
                  color: theme.colorScheme.primary,
                ),
                SizedBox(height: 18.r),
                Text(
                  PairingFileLocale.get(
                    context,
                    PairingFileLocale.setupTitle,
                  ),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 25.r,
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                SizedBox(height: 14.r),
                Text(
                  PairingFileLocale.get(
                    context,
                    PairingFileLocale.setupBody,
                  ),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14.r,
                    height: 1.45,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.76),
                  ),
                ),
                if (_error != null) ...[
                  SizedBox(height: 16.r),
                  Container(
                    width: double.infinity,
                    padding: EdgeInsets.all(12.r),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.errorContainer.withValues(
                        alpha: 0.55,
                      ),
                      borderRadius: BorderRadius.circular(12.r),
                    ),
                    child: Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12.r,
                        color: theme.colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                ],
                SizedBox(height: 26.r),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 12.r,
                  runSpacing: 10.r,
                  children: [
                    TextButton(
                      onPressed: _busy ? null : widget.onFinished,
                      child: Text(
                        PairingFileLocale.get(
                          context,
                          PairingFileLocale.later,
                        ),
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: _busy ? null : _choosePairingFile,
                      icon: _busy
                          ? SizedBox(
                              width: 16.r,
                              height: 16.r,
                              child: const CircularProgressIndicator(
                                strokeWidth: 2,
                              ),
                            )
                          : const Icon(Symbols.folder_open_rounded),
                      label: Text(
                        PairingFileLocale.get(
                          context,
                          PairingFileLocale.chooseFile,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
