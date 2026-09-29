import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/armsx2_ui_locale.dart';
import '../models/game_model.dart';
import '../models/system_model.dart';
import '../providers/file_provider.dart';
import '../providers/sqlite_config_provider.dart';
import '../providers/sqlite_database_provider.dart';
import '../repositories/game_repository.dart';
import '../services/armsx2_folder_service.dart';
import '../services/config_service.dart';

/// Multi-selection deletion UI for NeoStation's private embedded ARMSX2 library.
///
/// Restricted to PS2 on iOS and to physical files owned by
/// NeoStation/Documents/ARMSX2/Games. BIOS, memory cards and save states are
/// outside that ownership root and can never be selected by this dialog.
class Armsx2MultiDeleteDialog extends StatefulWidget {
  const Armsx2MultiDeleteDialog({
    super.key,
    required this.system,
    required this.games,
    required this.initialGame,
  });

  final SystemModel system;
  final List<GameModel> games;
  final GameModel initialGame;

  static Future<bool?> show({
    required BuildContext context,
    required SystemModel system,
    required List<GameModel> games,
    required GameModel initialGame,
  }) {
    if (!Platform.isIOS || system.folderName.toLowerCase() != 'ps2') {
      return Future<bool?>.value(false);
    }
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => Armsx2MultiDeleteDialog(
        system: system,
        games: games,
        initialGame: initialGame,
      ),
    );
  }

  @override
  State<Armsx2MultiDeleteDialog> createState() =>
      _Armsx2MultiDeleteDialogState();
}

class _Armsx2MultiDeleteDialogState
    extends State<Armsx2MultiDeleteDialog> {
  final Set<String> _selected = <String>{};
  bool _deleting = false;
  int _deletedCount = 0;
  int _targetCount = 0;
  String? _error;

  String _t(String key) => Armsx2UiLocale.text(context, key);
  String _tf(String key, Map<String, Object?> values) =>
      Armsx2UiLocale.format(context, key, values);

  String _key(GameModel game) =>
      game.romPath ?? '${game.systemId ?? widget.system.id}:${game.romname}';

  bool _isOwnedGame(GameModel game) => Armsx2FolderService.ownsRomPath(
        game.romPath,
        ConfigService.linkedArmsx2GameFolderPath,
      );

  List<GameModel> get _deletableGames =>
      widget.games.where(_isOwnedGame).toList(growable: false);

  @override
  void initState() {
    super.initState();
    if (_isOwnedGame(widget.initialGame)) {
      _selected.add(_key(widget.initialGame));
    }
  }

  void _toggle(GameModel game) {
    if (_deleting || !_isOwnedGame(game)) return;
    final key = _key(game);
    setState(() {
      if (!_selected.add(key)) _selected.remove(key);
    });
  }

  void _toggleAll() {
    if (_deleting) return;
    final games = _deletableGames;
    setState(() {
      if (games.isNotEmpty && _selected.length == games.length) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(games.map(_key));
      }
    });
  }

  Future<void> _deleteSelected() async {
    if (_deleting || _selected.isEmpty) return;
    final selectedGames = _deletableGames
        .where((game) => _selected.contains(_key(game)))
        .toList(growable: false);
    if (selectedGames.isEmpty) return;

    setState(() {
      _deleting = true;
      _deletedCount = 0;
      _targetCount = selectedGames.length;
      _error = null;
    });

    try {
      final fileProvider = context.read<FileProvider>();
      for (final game in selectedGames) {
        // Re-check ownership at the destructive boundary. This guarantees the
        // dialog cannot ever remove ARMSX2/BIOS or ARMSX2/Saves.
        if (!_isOwnedGame(game)) {
          throw StateError(_t('outsideRoot'));
        }
        await GameRepository.deleteGame(
          appSystemId: game.systemId ?? widget.system.id,
          filename: game.romname,
          systemFolderName: 'ps2',
          romBaseName: game.romname,
          romPath: game.romPath,
          fileProvider: fileProvider,
        );
        if (mounted) {
          setState(() {
            _deletedCount++;
            _selected.remove(_key(game));
          });
        }
      }

      if (!mounted) return;
      await context.read<SqliteConfigProvider>().refreshArmsx2InternalLibrary();
      if (!mounted) return;
      await context.read<SqliteDatabaseProvider>().loadDatabase();
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = _tf('deleteFailed', {'error': error});
        _deleting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final games = _deletableGames;
    final allSelected = games.isNotEmpty && _selected.length == games.length;

    return AlertDialog(
      key: const ValueKey('armsx2-multi-delete-dialog'),
      title: Text(_t('deleteGames')),
      content: SizedBox(
        width: 520,
        height: 420,
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _tf('selectedCount', {'count': _selected.length}),
                  ),
                ),
                TextButton.icon(
                  onPressed: _deleting ? null : _toggleAll,
                  icon: Icon(
                    allSelected
                        ? Icons.deselect_rounded
                        : Icons.select_all_rounded,
                  ),
                  label: Text(
                    allSelected
                        ? _t('deselectAll')
                        : _t('selectAll'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: games.length,
                itemBuilder: (context, index) {
                  final game = games[index];
                  final checked = _selected.contains(_key(game));
                  return CheckboxListTile(
                    value: checked,
                    onChanged: _deleting ? null : (_) => _toggle(game),
                    controlAffinity: ListTileControlAffinity.leading,
                    dense: true,
                    title: Text(
                      game.name.isNotEmpty ? game.name : game.romname,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      game.romname,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  );
                },
              ),
            ),
            if (_deleting) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: _targetCount == 0
                    ? null
                    : _deletedCount / _targetCount,
              ),
              const SizedBox(height: 6),
              Text(
                _tf('deleting', {'done': _deletedCount, 'total': _targetCount}),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _deleting ? null : () => Navigator.of(context).pop(false),
          child: Text(_t('cancel')),
        ),
        FilledButton.icon(
          onPressed: _deleting || _selected.isEmpty ? null : _deleteSelected,
          icon: const Icon(Icons.delete_forever_rounded),
          label: Text(_tf('deleteCount', {'count': _selected.length})),
        ),
      ],
    );
  }
}
