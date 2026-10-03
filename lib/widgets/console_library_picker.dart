import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';

import '../l10n/app_locale.dart';
import '../l10n/library_visibility_locale.dart';
import '../models/system_model.dart';
import '../providers/sqlite_config_provider.dart';
import '../services/gamepad/gamepad_navigation_manager.dart';
import '../services/library_visibility_service.dart';
import '../services/retroarch_core_catalog.dart';
import '../services/retroarch_core_preferences.dart';
import '../services/retroarch_internal_service.dart';
import '../services/retroarch_migration_service.dart';
import '../utils/gamepad_nav.dart';

String consoleLibraryName(BuildContext context, SystemModel system) =>
    system.folderName == 'ports'
    ? LibraryVisibilityLocale.text(context, 'ports')
    : system.realName;

String consoleLibraryEmulator(SystemModel system) =>
    switch (system.folderName) {
      'ps2' => 'ARMSX2',
      'ps3' => 'RPCS3',
      'gc' || 'wii' => 'DolphiniOS',
      'ports' => 'DuskLight / Mario Kart Pad',
      _ =>
        RetroArchCoreCatalog.supportedSystems.contains(system.folderName)
            ? 'RetroArch'
            : system.folderName,
    };

Future<bool?> showConsoleLibraryPicker(
  BuildContext context,
  SqliteConfigProvider provider,
) => showDialog<bool>(
  context: context,
  builder: (dialogContext) => Dialog(
    child: SizedBox(
      width: 680,
      height: MediaQuery.sizeOf(dialogContext).height * 0.85,
      child: ConsoleLibraryPicker(
        libraries: provider.selectableLibrarySystems,
        initiallyEnabled: provider.enabledLibraryFolders,
        onSave: provider.saveLibrarySelection,
        onFinished: () async => Navigator.of(dialogContext).pop(true),
        onCancel: () => Navigator.of(dialogContext).pop(false),
      ),
    ),
  ),
);

/// The same opt-in console list is used on first launch and when reopened.
/// Selecting a console only controls visibility; it downloads no emulator.
class ConsoleLibraryPicker extends StatefulWidget {
  const ConsoleLibraryPicker({
    super.key,
    required this.libraries,
    required this.initiallyEnabled,
    required this.onSave,
    required this.onFinished,
    this.onCancel,
    this.firstLaunch = false,
    this.loadPackagedCores,
    this.loadPreferredCore,
    this.savePreferredCores,
    this.executionMode,
  });

  final List<SystemModel> libraries;
  final Set<String> initiallyEnabled;
  final Future<void> Function(Set<String>) onSave;
  final Future<void> Function() onFinished;
  final VoidCallback? onCancel;
  final bool firstLaunch;
  final Future<Set<String>> Function()? loadPackagedCores;
  final Future<String?> Function(String folder)? loadPreferredCore;
  final Future<void> Function(Map<String, String> choices)? savePreferredCores;
  final RetroArchExecutionMode? executionMode;

  @override
  State<ConsoleLibraryPicker> createState() => _ConsoleLibraryPickerState();
}

class _ConsoleLibraryPickerState extends State<ConsoleLibraryPicker> {
  late final Set<String> _enabled = {...widget.initiallyEnabled};
  final Map<String, GlobalKey> _rowKeys = {};
  late final GamepadNavigation _navigation;
  final _scrollController = ScrollController();
  int _selectedIndex = 0;
  bool _saving = false;
  bool _saveFailed = false;
  bool _loadingCores = true;
  bool _coreLoadFailed = false;
  final Map<String, List<RetroArchCoreDescriptor>> _coreChoices = {};
  final Map<String, String> _selectedCores = {};

  RetroArchExecutionMode get _executionMode =>
      widget.executionMode ??
      (widget.firstLaunch
          ? RetroArchExecutionMode.embedded
          : RetroArchMigrationService.instance.mode);

  List<SystemModel> get _libraries => widget.libraries.where((system) {
    if (_executionMode == RetroArchExecutionMode.external) return true;
    if (!RetroArchCoreCatalog.supportsSystem(system.folderName)) return true;
    return _loadingCores ||
        _coreLoadFailed ||
        (_coreChoices[system.folderName]?.isNotEmpty ?? false) ||
        _isEnabled(system.folderName);
  }).toList();

  bool _isEnabled(String folder) =>
      LibraryVisibilitySelection.consoleFolders(folder).any(_enabled.contains);

  bool get _hasActiveRetroArch => widget.libraries.any(
    (system) =>
        _isEnabled(system.folderName) &&
        RetroArchCoreCatalog.supportsSystem(system.folderName),
  );

  bool get _canSave =>
      !_saving &&
      (_executionMode == RetroArchExecutionMode.external ||
          !_hasActiveRetroArch ||
          (!_loadingCores &&
              !_coreLoadFailed &&
              widget.libraries
                  .where(
                    (system) =>
                        _isEnabled(system.folderName) &&
                        RetroArchCoreCatalog.supportsSystem(system.folderName),
                  )
                  .every(
                    (system) => (_coreChoices[system.folderName] ?? []).any(
                      (core) =>
                          core.identifier == _selectedCores[system.folderName],
                    ),
                  )));

  @override
  void initState() {
    super.initState();
    _navigation = GamepadNavigation(
      onNavigateUp: () => _move(-1),
      onNavigateDown: () => _move(1),
      onNavigateLeft: () => _cycleCore(-1),
      onNavigateRight: () => _cycleCore(1),
      onSelectItem: _select,
      onBack: () {
        if (!_saving) widget.onCancel?.call();
      },
    )..initialize();
    GamepadNavigationManager.pushLayer(
      'console_library_picker',
      modal: true,
      onActivate: _navigation.activate,
      onDeactivate: _navigation.deactivate,
    );
    unawaited(_loadCoreChoices());
  }

  Future<void> _loadCoreChoices() async {
    // The verified external game URL launches the playlist's own core. Do not
    // offer a NeoStation override that the other application cannot receive.
    if (_executionMode == RetroArchExecutionMode.external) {
      setState(() => _loadingCores = false);
      return;
    }
    setState(() {
      _loadingCores = true;
      _coreLoadFailed = false;
    });
    try {
      final packaged =
          await (widget.loadPackagedCores?.call() ??
              RetroArchInternalService.packagedCoreIdentifiers());
      final choices = <String, List<RetroArchCoreDescriptor>>{};
      final selected = <String, String>{};
      for (final system in widget.libraries) {
        final folder = system.folderName;
        if (!RetroArchCoreCatalog.supportsSystem(folder)) continue;
        final available = RetroArchCoreCatalog.coresForSystem(
          folder,
        ).where((core) => packaged.contains(core.identifier)).toList();
        choices[folder] = available;
        if (available.isEmpty) continue;
        String? saved;
        try {
          final preferenceFolder = LibraryVisibilitySelection.consoleFolders(
            folder,
          ).firstWhere(_enabled.contains, orElse: () => folder);
          saved = widget.loadPreferredCore != null
              ? await widget.loadPreferredCore!(preferenceFolder)
              : (await RetroArchCorePreferences.preferredCore(
                  preferenceFolder,
                )).identifier;
        } on StateError catch (error) {
          // A retired/non-packaged choice cannot stay selectable. The reviewed
          // compatible default is proposed without changing persisted data.
          if (!error.message.toString().startsWith(
            'RETROARCH_UNSUPPORTED_CORE',
          )) {
            rethrow;
          }
        }
        selected[folder] = available.any((core) => core.identifier == saved)
            ? saved!
            : available.first.identifier;
      }
      if (!mounted) return;
      setState(() {
        _coreChoices
          ..clear()
          ..addAll(choices);
        // Retain unsaved drafts after a retry when their package still exists.
        for (final entry in selected.entries) {
          if (!(choices[entry.key] ?? []).any(
            (core) => core.identifier == _selectedCores[entry.key],
          )) {
            _selectedCores[entry.key] = entry.value;
          }
        }
        _loadingCores = false;
        _selectedIndex = _selectedIndex.clamp(0, _libraries.length);
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loadingCores = false;
          _coreLoadFailed = true;
        });
      }
    }
  }

  void _cycleCore(int direction) {
    if (_executionMode == RetroArchExecutionMode.external) return;
    final libraries = _libraries;
    if (_saving || _selectedIndex >= libraries.length) return;
    final folder = libraries[_selectedIndex].folderName;
    final choices = _coreChoices[folder] ?? [];
    if (!_isEnabled(folder) || choices.length < 2) return;
    final current = choices.indexWhere(
      (core) => core.identifier == _selectedCores[folder],
    );
    setState(
      () => _selectedCores[folder] =
          choices[(current + direction + choices.length) % choices.length]
              .identifier,
    );
  }

  void _move(int direction) {
    if (_saving) return;
    setState(
      () => _selectedIndex = (_selectedIndex + direction).clamp(
        0,
        _libraries.length,
      ),
    );
    if (_selectedIndex < _libraries.length) {
      final folder = _libraries[_selectedIndex].folderName;
      final rowContext = _rowKeys[folder]?.currentContext;
      if (rowContext != null) {
        unawaited(
          Scrollable.ensureVisible(
            rowContext,
            duration: const Duration(milliseconds: 120),
          ),
        );
      } else if (_scrollController.hasClients) {
        // Lazy rows may not exist yet. Bring their approximate position into
        // view before the next directional input resolves their real context.
        _scrollController.jumpTo(
          (_selectedIndex * 72.0).clamp(
            0.0,
            _scrollController.position.maxScrollExtent,
          ),
        );
      }
    }
  }

  void _select() {
    if (_saving) return;
    if (_selectedIndex == _libraries.length) {
      unawaited(_save());
    } else {
      final folder = _libraries[_selectedIndex].folderName;
      if (_isEnabled(folder) ||
          _executionMode == RetroArchExecutionMode.external ||
          _loadingCores ||
          !RetroArchCoreCatalog.supportsSystem(folder) ||
          (_coreChoices[folder]?.isNotEmpty ?? false)) {
        _toggle(folder);
      }
    }
  }

  void _toggle(String folder) => setState(() {
    final aliases = LibraryVisibilitySelection.consoleFolders(folder);
    if (aliases.any(_enabled.contains)) {
      _enabled.removeAll(aliases);
    } else {
      _enabled.addAll(aliases);
    }
  });

  Future<void> _save() async {
    if (!_canSave) return;
    setState(() {
      _saving = true;
      _saveFailed = false;
    });
    try {
      final choices = <String, String>{};
      for (final library in widget.libraries) {
        final folder = library.folderName;
        if (_executionMode == RetroArchExecutionMode.external ||
            !_isEnabled(folder) ||
            !RetroArchCoreCatalog.supportsSystem(folder)) {
          continue;
        }
        for (final alias in LibraryVisibilitySelection.consoleFolders(folder)) {
          if (_enabled.contains(alias)) {
            choices[alias] = _selectedCores[folder]!;
          }
        }
      }
      if (choices.isNotEmpty && widget.savePreferredCores != null) {
        await widget.savePreferredCores!(choices);
      } else {
        for (final choice in choices.entries) {
          await RetroArchCorePreferences.setPreferredCore(
            choice.key,
            choice.value,
          );
        }
      }
      // Activation and first-run completion are last: a failed core preference
      // write leaves the prior library visibility untouched and can be retried.
      await widget.onSave({..._enabled});
      if (!mounted) return;
      await widget.onFinished();
    } catch (_) {
      if (mounted) setState(() => _saveFailed = true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer('console_library_picker');
    _navigation.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final libraries = _libraries;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              LibraryVisibilityLocale.text(context, 'title'),
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(LibraryVisibilityLocale.text(context, 'description')),
            const SizedBox(height: 8),
            Text(
              LibraryVisibilityLocale.text(context, 'keepData'),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            if (_loadingCores)
              Text(LibraryVisibilityLocale.text(context, 'coreLoading')),
            if (_coreLoadFailed)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      LibraryVisibilityLocale.text(context, 'coreLoadFailed'),
                    ),
                  ),
                  TextButton(
                    onPressed: _loadCoreChoices,
                    child: Text(AppLocale.retry.getString(context)),
                  ),
                ],
              ),
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                itemCount: libraries.length,
                itemBuilder: (context, index) {
                  final system = libraries[index];
                  final folder = system.folderName;
                  final isRetroArch = RetroArchCoreCatalog.supportsSystem(
                    folder,
                  );
                  final enabled = _isEnabled(folder);
                  final cores = _coreChoices[folder] ?? [];
                  return Column(
                    key: _rowKeys.putIfAbsent(folder, GlobalKey.new),
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      CheckboxListTile(
                        selected: index == _selectedIndex,
                        value: enabled,
                        title: Text(consoleLibraryName(context, system)),
                        subtitle: Text(
                          isRetroArch
                              ? LibraryVisibilityLocale.text(
                                  context,
                                  _executionMode ==
                                          RetroArchExecutionMode.external
                                      ? 'externalEngine'
                                      : 'embeddedEngine',
                                )
                              : consoleLibraryEmulator(system),
                        ),
                        onChanged:
                            _saving ||
                                (isRetroArch &&
                                    _executionMode !=
                                        RetroArchExecutionMode.external &&
                                    !_loadingCores &&
                                    cores.isEmpty &&
                                    !enabled)
                            ? null
                            : (_) => _toggle(system.folderName),
                        controlAffinity: ListTileControlAffinity.leading,
                      ),
                      if (enabled &&
                          isRetroArch &&
                          _executionMode == RetroArchExecutionMode.external)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(56, 0, 16, 12),
                          child: Text(
                            LibraryVisibilityLocale.text(
                              context,
                              'chooseInRetroArch',
                            ),
                          ),
                        ),
                      if (enabled &&
                          isRetroArch &&
                          _executionMode == RetroArchExecutionMode.embedded &&
                          !_loadingCores &&
                          !_coreLoadFailed)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(56, 0, 16, 12),
                          child: cores.isEmpty
                              ? Text(
                                  LibraryVisibilityLocale.text(
                                    context,
                                    'coreUnavailable',
                                  ),
                                )
                              : DropdownButtonFormField<String>(
                                  key: ValueKey(
                                    'library-core-$folder-${_selectedCores[folder]}',
                                  ),
                                  initialValue: _selectedCores[folder],
                                  isExpanded: true,
                                  decoration: InputDecoration(
                                    labelText: LibraryVisibilityLocale.text(
                                      context,
                                      'coreLabel',
                                    ),
                                    border: const OutlineInputBorder(),
                                  ),
                                  items: cores
                                      .map(
                                        (core) => DropdownMenuItem(
                                          value: core.identifier,
                                          child: Text(
                                            'RetroArch — ${core.displayName}',
                                          ),
                                        ),
                                      )
                                      .toList(),
                                  onChanged: _saving
                                      ? null
                                      : (value) {
                                          if (value != null) {
                                            setState(
                                              () => _selectedCores[folder] =
                                                  value,
                                            );
                                          }
                                        },
                                ),
                        ),
                    ],
                  );
                },
              ),
            ),
            if (_saveFailed)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  LibraryVisibilityLocale.text(context, 'saveFailed'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (widget.onCancel != null)
                  TextButton(
                    onPressed: _saving ? null : widget.onCancel,
                    child: Text(AppLocale.cancel.getString(context)),
                  ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  autofocus: libraries.isEmpty,
                  style: _selectedIndex == libraries.length
                      ? FilledButton.styleFrom(
                          side: BorderSide(
                            color: theme.colorScheme.onPrimary,
                            width: 2,
                          ),
                        )
                      : null,
                  onPressed: _canSave ? _save : null,
                  icon: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check_rounded),
                  label: Text(
                    widget.firstLaunch
                        ? LibraryVisibilityLocale.text(context, 'continue')
                        : AppLocale.apply.getString(context),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class ConsoleLibraryEmptyState extends StatelessWidget {
  const ConsoleLibraryEmptyState({super.key, required this.provider});
  final SqliteConfigProvider provider;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.videogame_asset_outlined, size: 48),
          const SizedBox(height: 16),
          Text(
            LibraryVisibilityLocale.text(context, 'empty'),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () => showConsoleLibraryPicker(context, provider),
            icon: const Icon(Icons.add_rounded),
            label: Text(LibraryVisibilityLocale.text(context, 'manage')),
          ),
        ],
      ),
    ),
  );
}
