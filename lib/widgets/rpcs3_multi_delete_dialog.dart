import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/rpcs3_ui_locale.dart';
import '../models/game_model.dart';
import '../models/system_model.dart';
import '../providers/file_provider.dart';
import '../providers/sqlite_database_provider.dart';
import '../repositories/game_repository.dart';
import '../services/rpcs3_internal_service.dart';
import '../services/rpcs3_library_service.dart';
import '../services/rpcs3_launch_service.dart';

/// Multi-selection deletion UI for NeoStation's embedded RPCS3 library.
///
/// Uses the same verified installation deletion as the per-game settings.
/// It works without JIT and retains saves, firmware and savestates.
class Rpcs3MultiDeleteDialog extends StatefulWidget {
  const Rpcs3MultiDeleteDialog({
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
    if (!Platform.isIOS || system.folderName.toLowerCase() != 'ps3') {
      return Future<bool?>.value(false);
    }
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => Rpcs3MultiDeleteDialog(
        system: system,
        games: games,
        initialGame: initialGame,
      ),
    );
  }

  @override
  State<Rpcs3MultiDeleteDialog> createState() => _Rpcs3MultiDeleteDialogState();
}

class _Rpcs3MultiDeleteDialogState extends State<Rpcs3MultiDeleteDialog> {
  final Set<String> _selected = <String>{};
  bool _deleting = false;
  int _deletedCount = 0;
  int _targetCount = 0;
  String? _error;

  String _t(String key) => Rpcs3UiLocale.text(context, key);
  String _tf(String key, Map<String, Object?> values) =>
      Rpcs3UiLocale.format(context, key, values);

  String? _titleId(GameModel game) {
    final direct = Rpcs3LaunchService.normalizeTitleId(game.titleId);
    if (direct != null) return direct;

    final romPath = game.romPath;
    if (romPath != null && Rpcs3LibraryService.isVirtualLibraryPath(romPath)) {
      final uri = Uri.tryParse(romPath);
      final fromUri = Rpcs3LaunchService.normalizeTitleId(
        uri?.queryParameters['title-id'],
      );
      if (fromUri != null) return fromUri;
    }

    return Rpcs3LaunchService.normalizeTitleId(game.romname);
  }

  List<GameModel> get _deletableGames => widget.games
      .where((game) => _titleId(game) != null)
      .toList(growable: false);

  @override
  void initState() {
    super.initState();
    final initial = _titleId(widget.initialGame);
    if (initial != null) _selected.add(initial);
  }

  void _toggle(GameModel game) {
    if (_deleting) return;
    final titleId = _titleId(game);
    if (titleId == null) return;
    setState(() {
      if (!_selected.add(titleId)) _selected.remove(titleId);
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
          ..addAll(games.map(_titleId).whereType<String>());
      }
    });
  }

  Future<void> _deleteSelected() async {
    if (_deleting || _selected.isEmpty) return;
    final selectedGames = _deletableGames
        .where((game) => _selected.contains(_titleId(game)))
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
        final titleId = _titleId(game)!;
        await Rpcs3InternalService.deleteInstalledGame(titleId);

        await GameRepository.deleteNeoStationScrapedMedia(
          systemFolderName: 'ps3',
          filename: game.romname,
          romBaseName: game.romname,
          fileProvider: fileProvider,
        );

        if (mounted)
          setState(() {
            _deletedCount++;
            _selected.remove(titleId);
          });
      }

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
      key: const ValueKey('rpcs3-multi-delete-dialog'),
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
                  final titleId = _titleId(game)!;
                  final checked = _selected.contains(titleId);
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
                      titleId,
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
                value: _targetCount == 0 ? null : _deletedCount / _targetCount,
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
