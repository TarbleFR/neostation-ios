import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/game_model.dart';
import '../models/system_model.dart';
import '../providers/sqlite_config_provider.dart';
import '../providers/sqlite_database_provider.dart';
import '../repositories/game_repository.dart';
import '../services/dolphin_internal_v2_service.dart';

/// Multi-selection deletion UI for NeoStation's private DolphiniOS playlists.
///
/// The dialog is intentionally restricted to the embedded GameCube/Wii
/// libraries. A long press selects the touched game first, then the user may
/// select additional games before deleting the underlying images. The private
/// playlist is rescanned immediately afterwards so removed games disappear
/// without restarting NeoStation.
class DolphinMultiDeleteDialog extends StatefulWidget {
  const DolphinMultiDeleteDialog({
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
    if (!Platform.isIOS ||
        !DolphinInternalV2Service.isDolphinSystem(system.folderName)) {
      return Future<bool?>.value(false);
    }
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => DolphinMultiDeleteDialog(
        system: system,
        games: games,
        initialGame: initialGame,
      ),
    );
  }

  @override
  State<DolphinMultiDeleteDialog> createState() =>
      _DolphinMultiDeleteDialogState();
}

class _DolphinMultiDeleteDialogState extends State<DolphinMultiDeleteDialog> {
  final Set<String> _selected = <String>{};
  bool _deleting = false;
  int _deletedCount = 0;
  int _targetCount = 0;
  String? _error;

  bool get _fr => Localizations.localeOf(context).languageCode == 'fr';

  String _key(GameModel game) =>
      game.romPath ?? '${game.systemId ?? widget.system.id}:${game.romname}';

  @override
  void initState() {
    super.initState();
    _selected.add(_key(widget.initialGame));
  }

  void _toggle(GameModel game) {
    if (_deleting) return;
    final key = _key(game);
    setState(() {
      if (!_selected.add(key)) _selected.remove(key);
    });
  }

  void _toggleAll() {
    if (_deleting) return;
    setState(() {
      if (_selected.length == widget.games.length) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(widget.games.map(_key));
      }
    });
  }

  Future<void> _deleteSelected() async {
    if (_deleting || _selected.isEmpty) return;
    final selectedGames = widget.games
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
      for (final game in selectedGames) {
        await GameRepository.deleteGame(
          appSystemId: game.systemId ?? widget.system.id,
          filename: game.romname,
          systemFolderName: widget.system.folderName,
          romBaseName: game.romname,
          romPath: game.romPath,
        );
        if (mounted) setState(() => _deletedCount++);
      }

      if (!mounted) return;
      await context
          .read<SqliteConfigProvider>()
          .refreshDolphinInternalLibrary(widget.system.folderName);
      if (!mounted) return;
      await context.read<SqliteDatabaseProvider>().loadDatabase();
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = _fr
            ? 'La suppression a échoué : $error'
            : 'Deletion failed: $error';
        _deleting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final allSelected =
        widget.games.isNotEmpty && _selected.length == widget.games.length;

    return AlertDialog(
      title: Text(_fr ? 'Supprimer des jeux' : 'Delete games'),
      content: SizedBox(
        width: 520,
        height: 420,
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _fr
                        ? '${_selected.length} jeu(x) sélectionné(s)'
                        : '${_selected.length} game(s) selected',
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
                        ? (_fr ? 'Tout désélectionner' : 'Deselect all')
                        : (_fr ? 'Tout sélectionner' : 'Select all'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: widget.games.length,
                itemBuilder: (context, index) {
                  final game = widget.games[index];
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
                _fr
                    ? 'Suppression $_deletedCount / $_targetCount…'
                    : 'Deleting $_deletedCount / $_targetCount…',
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _deleting ? null : () => Navigator.of(context).pop(false),
          child: Text(_fr ? 'Annuler' : 'Cancel'),
        ),
        FilledButton.icon(
          onPressed: _deleting || _selected.isEmpty ? null : _deleteSelected,
          icon: const Icon(Icons.delete_forever_rounded),
          label: Text(
            _fr
                ? 'Supprimer (${_selected.length})'
                : 'Delete (${_selected.length})',
          ),
        ),
      ],
    );
  }
}
