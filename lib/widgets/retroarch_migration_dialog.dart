import 'dart:async';
import 'dart:io';

import 'package:external_folder_access/external_folder_access.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:retroarch_internal_bridge/retroarch_internal_bridge.dart';

import '../l10n/retroarch_locale.dart';
import '../services/retroarch_data_migration.dart';
import '../services/retroarch_internal_service.dart';
import '../services/retroarch_migration_service.dart';

typedef RetroArchMigrationAvailabilityProbe = Future<bool> Function();
typedef RetroArchMigrationFolderPicker = Future<String?> Function();

/// One upgrade offer. Copying data is optional and requires a source explicitly
/// picked in Files; choosing or cancelling a picker never changes execution mode.
class RetroArchMigrationDialog extends StatefulWidget {
  const RetroArchMigrationDialog({
    super.key,
    required this.service,
    required this.availabilityProbe,
    this.folderPicker,
    this.targetRoot,
  });

  final RetroArchMigrationService service;
  final RetroArchMigrationAvailabilityProbe availabilityProbe;
  final RetroArchMigrationFolderPicker? folderPicker;
  final Directory? targetRoot;
  static const _bookmark = 'retroarch_migration_source';
  static bool _dialogVisible = false;

  static Future<bool> _available() async {
    try {
      final status = await RetroArchInternalBridge.diagnostics();
      // This native flag includes a loaded frontend ABI and packaged cores.
      // Platform support or an installed framework alone is insufficient.
      return status['embeddedAvailable'] == true;
    } catch (_) {
      return false;
    }
  }

  static Future<RetroArchExecutionMode?> showIfNeeded(
    BuildContext context, {
    RetroArchMigrationService? service,
    RetroArchMigrationAvailabilityProbe? availabilityProbe,
    RetroArchMigrationFolderPicker? folderPicker,
    Directory? targetRoot,
  }) async {
    final preferences = service ?? RetroArchMigrationService.instance;
    final probe = availabilityProbe ?? _available;
    await preferences.load();
    if (!preferences.needsMigration) return null;
    bool available;
    try {
      available = await probe();
    } catch (_) {
      available = false;
    }
    if (!context.mounted || !available) return null;
    return show(
      context,
      service: preferences,
      availabilityProbe: probe,
      folderPicker: folderPicker,
      targetRoot: targetRoot,
    );
  }

  /// Explicit Settings entry. A saved choice does not hide this dialog, and
  /// unavailable embedded code never prevents a user switching back external.
  static Future<RetroArchExecutionMode?> show(
    BuildContext context, {
    RetroArchMigrationService? service,
    RetroArchMigrationAvailabilityProbe? availabilityProbe,
    RetroArchMigrationFolderPicker? folderPicker,
    Directory? targetRoot,
  }) async {
    final preferences = service ?? RetroArchMigrationService.instance;
    await preferences.load();
    if (!context.mounted || _dialogVisible) return null;
    _dialogVisible = true;
    try {
      return await showDialog<RetroArchExecutionMode>(
        context: context,
        barrierDismissible: false,
        builder: (_) => RetroArchMigrationDialog(
          service: preferences,
          availabilityProbe: availabilityProbe ?? _available,
          folderPicker: folderPicker,
          targetRoot: targetRoot,
        ),
      );
    } finally {
      _dialogVisible = false;
    }
  }

  @override
  State<RetroArchMigrationDialog> createState() =>
      _RetroArchMigrationDialogState();
}

class _RetroArchMigrationDialogState extends State<RetroArchMigrationDialog> {
  bool _busy = false;
  bool _copy = false;
  Directory? _source;
  String? _errorKey;
  String? _details;
  int _done = 0;
  int _total = 0;
  RetroArchMigrationCopyReport? _report;
  bool _releaseGrantAfterWork = false;
  final _categories = RetroArchMigrationCategory.values.toSet();
  RetroArchMigrationCollision _collision =
      RetroArchMigrationCollision.keepExisting;

  String _text(String key) => RetroArchLocale.text(context, key);

  Future<void> _pick() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _errorKey = null;
    });
    try {
      final picker = widget.folderPicker;
      final selected = picker != null
          ? await picker()
          : Platform.isIOS
          ? await ExternalFolderAccess.pickAndActivateFolder(
              key: RetroArchMigrationDialog._bookmark,
            )
          : await FilePicker.getDirectoryPath();
      if (mounted && selected != null) {
        setState(() {
          _source = Directory(selected);
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _errorKey = 'migrationSourceMissing';
          _details = '$error';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
      if (_releaseGrantAfterWork) await _releaseSourceBookmark();
    }
  }

  Future<void> _choose({required bool embedded, bool copy = false}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _errorKey = null;
      _details = null;
    });
    try {
      if (!embedded) {
        await widget.service.keepExternal();
      } else {
        if (!await widget.availabilityProbe()) {
          throw const RetroArchMigrationUnavailable();
        }
        if (copy) {
          if (_source == null) {
            if (mounted) {
              setState(() {
                _errorKey = 'migrationSourceMissing';
              });
            }
            return;
          }
          final target =
              widget.targetRoot ??
              await RetroArchInternalService.rootDirectory();
          _report = await RetroArchDataMigration.copy(
            sourceRoot: _source!,
            targetRoot: target,
            categories: _categories.toSet(),
            collision: _collision,
            onProgress: (done, total) {
              if (mounted) {
                setState(() {
                  _done = done;
                  _total = total;
                });
              }
            },
          );
          if (!_report!.complete) {
            if (mounted) {
              setState(() {
                _errorKey = 'migrationCopyFailure';
                _details = _report!.errors.entries
                    .map((entry) => '${entry.key}: ${entry.value}')
                    .join('\n');
              });
            }
            return;
          }
          // Keep external routing if the backend changed while a long copy ran.
          if (!await widget.availabilityProbe()) {
            throw const RetroArchMigrationUnavailable();
          }
        }
        // Written only after every selected file was verified or explicitly
        // skipped by the user's collision policy. Retry preserves partial work.
        await widget.service.chooseEmbedded(backendAvailable: true);
      }
      if (mounted) {
        final messenger = ScaffoldMessenger.maybeOf(context);
        final report = _report;
        final summary = embedded && copy && report != null
            ? RetroArchLocale.format(context, 'migrationCopied', {
                'count': report.copied,
                'skipped': report.skipped,
              })
            : null;
        Navigator.of(context).pop(widget.service.mode);
        if (summary != null) {
          messenger?.showSnackBar(SnackBar(content: Text(summary)));
        }
      }
    } on RetroArchMigrationUnavailable {
      if (mounted) {
        setState(() {
          _errorKey = 'retroarchMigrationUnavailable';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _errorKey = copy && _report?.complete != true
              ? 'migrationCopyFailure'
              : 'retroarchMigrationFailure';
          _details = '$error';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
      if (_releaseGrantAfterWork) await _releaseSourceBookmark();
    }
  }

  Future<void> _releaseSourceBookmark() async {
    if (widget.folderPicker == null && Platform.isIOS) {
      await ExternalFolderAccess.clearBookmark(
        key: RetroArchMigrationDialog._bookmark,
      );
    }
  }

  @override
  void dispose() {
    // This independent slot never changes the existing external library grant.
    // Forced route disposal must not release a grant while awaited file I/O is
    // still running. Its handler's finally releases it after the operation.
    if (_busy) {
      _releaseGrantAfterWork = true;
    } else {
      unawaited(_releaseSourceBookmark());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        scrollable: true,
        title: Text(_text('retroarchMigrationTitle')),
        content: SizedBox(
          width: 500,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_text('retroarchMigrationBody')),
              if (_copy) ...[
                const SizedBox(height: 16),
                Text(_text('migrationFolderHelp')),
                TextButton.icon(
                  key: const ValueKey('retroarchMigrationChooseFolder'),
                  onPressed: _busy ? null : _pick,
                  icon: const Icon(Icons.folder_open),
                  label: Text(_text('migrationChooseFolder')),
                ),
                if (_source != null)
                  SelectableText(
                    _source!.path,
                    style: theme.textTheme.bodySmall,
                  ),
                const SizedBox(height: 8),
                Text(
                  _text('migrationCategories'),
                  style: theme.textTheme.titleSmall,
                ),
                for (final category in RetroArchMigrationCategory.values)
                  CheckboxListTile(
                    key: ValueKey(
                      'retroarchMigrationCategory:${category.name}',
                    ),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      _text(switch (category) {
                        RetroArchMigrationCategory.bios => 'migrationBios',
                        RetroArchMigrationCategory.games => 'migrationGames',
                        RetroArchMigrationCategory.saves => 'migrationSaves',
                        RetroArchMigrationCategory.states => 'migrationStates',
                        RetroArchMigrationCategory.configs =>
                          'migrationConfigs',
                        RetroArchMigrationCategory.shaders =>
                          'migrationShaders',
                        RetroArchMigrationCategory.overlays =>
                          'migrationOverlays',
                        RetroArchMigrationCategory.cheats => 'migrationCheats',
                      }),
                    ),
                    value: _categories.contains(category),
                    onChanged: _busy
                        ? null
                        : (selected) => setState(() {
                            if (selected == true) {
                              _categories.add(category);
                            } else {
                              _categories.remove(category);
                            }
                          }),
                  ),
                DropdownButtonFormField<RetroArchMigrationCollision>(
                  key: const ValueKey('retroarchMigrationCollision'),
                  initialValue: _collision,
                  isExpanded: true,
                  items: [
                    for (final policy in RetroArchMigrationCollision.values)
                      DropdownMenuItem(
                        value: policy,
                        child: Text(
                          _text(
                            policy == RetroArchMigrationCollision.keepExisting
                                ? 'migrationKeepExisting'
                                : 'migrationReplaceWithBackup',
                          ),
                          maxLines: 2,
                        ),
                      ),
                  ],
                  onChanged: _busy
                      ? null
                      : (value) => setState(() {
                          if (value != null) _collision = value;
                        }),
                ),
              ],
              if (_busy) ...[
                const SizedBox(height: 12),
                const LinearProgressIndicator(),
                if (_total > 0)
                  Text(
                    RetroArchLocale.format(context, 'migrationProgress', {
                      'done': _done,
                      'total': _total,
                    }),
                  ),
              ],
              if (_report != null) ...[
                const SizedBox(height: 12),
                Text(
                  RetroArchLocale.format(context, 'migrationCopied', {
                    'count': _report!.copied,
                    'skipped': _report!.skipped,
                  }),
                ),
              ],
              if (_errorKey != null) ...[
                const SizedBox(height: 12),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _text(_errorKey!),
                    key: const ValueKey('retroarchMigrationError'),
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
                if (_details != null)
                  ExpansionTile(
                    title: Text(_text('technicalDetails')),
                    children: [
                      SelectableText(
                        _details!,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('retroarchMigrationKeepExternal'),
            onPressed: _busy ? null : () => _choose(embedded: false),
            child: Text(_text('retroarchMigrationKeepExternal')),
          ),
          TextButton(
            key: const ValueKey('retroarchMigrationSwitchOnly'),
            onPressed: _busy ? null : () => _choose(embedded: true),
            child: Text(_text('migrationSwitchOnly')),
          ),
          FilledButton(
            key: const ValueKey('retroarchMigrationCopyAndSwitch'),
            onPressed: _busy || (_copy && _categories.isEmpty)
                ? null
                : () {
                    if (!_copy) {
                      setState(() {
                        _copy = true;
                      });
                    } else {
                      _choose(embedded: true, copy: true);
                    }
                  },
            child: Text(_text('migrationCopyAndSwitch')),
          ),
        ],
      ),
    );
  }
}
