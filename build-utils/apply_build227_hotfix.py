#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)


def patch_rpcs3_bridge() -> None:
    bridge = r'''import 'package:flutter/services.dart';

class Rpcs3InternalBridge {
  Rpcs3InternalBridge._();

  static const MethodChannel _channel = MethodChannel(
    'neostation/rpcs3_internal',
  );
  static const MethodChannel _jitChannel = MethodChannel(
    'neostation/rpcs3_jit',
  );

  static Future<Map<String, dynamic>> diagnostics() async =>
      Map<String, dynamic>.from(
        await _channel.invokeMapMethod<String, dynamic>('diagnostics') ??
            const <String, dynamic>{},
      );

  static Future<Map<String, dynamic>> jitStatus() async =>
      Map<String, dynamic>.from(
        await _jitChannel.invokeMapMethod<String, dynamic>('status') ??
            const <String, dynamic>{},
      );

  static Future<Map<String, dynamic>> prepareJit({
    required String pairingFilePath,
  }) async => Map<String, dynamic>.from(
    await _jitChannel.invokeMapMethod<String, dynamic>('prepareJit', {
          'pairingFilePath': pairingFilePath,
        }) ??
        const <String, dynamic>{},
  );

  static Future<Map<String, dynamic>> initialize({
    required String supportPath,
    required String cachePath,
    bool expandedJitRegion = false,
  }) async => Map<String, dynamic>.from(
    await _channel.invokeMapMethod<String, dynamic>('initialize', {
          'supportPath': supportPath,
          'cachePath': cachePath,
          'expandedJitRegion': expandedJitRegion,
        }) ??
        const <String, dynamic>{},
  );

  /// Call only after initialize has prepared and sealed the Core JIT arena.
  static Future<Map<String, dynamic>> completeJit() async =>
      Map<String, dynamic>.from(
        await _jitChannel.invokeMapMethod<String, dynamic>('completeJit') ??
            const <String, dynamic>{},
      );

  static Future<Map<String, dynamic>> shutdown() async =>
      Map<String, dynamic>.from(
        await _channel.invokeMapMethod<String, dynamic>('shutdown') ??
            const <String, dynamic>{},
      );

  static Future<String> firmwareVersion() async =>
      (await _channel.invokeMethod<String>('firmwareVersion')) ?? '';

  static Future<Map<String, dynamic>> installFirmware(String path) async =>
      Map<String, dynamic>.from(
        await _channel.invokeMapMethod<String, dynamic>('installFirmware', {
              'path': path,
            }) ??
            const <String, dynamic>{},
      );

  static Future<Map<String, dynamic>> installPackage(String path) async =>
      Map<String, dynamic>.from(
        await _channel.invokeMapMethod<String, dynamic>('installPackage', {
              'path': path,
            }) ??
            const <String, dynamic>{},
      );

  static Future<Map<String, dynamic>> installIso(
    String path, {
    String? keyPath,
  }) async => Map<String, dynamic>.from(
    await _channel.invokeMapMethod<String, dynamic>('installIso', {
          'path': path,
          if (keyPath != null) 'keyPath': keyPath,
        }) ??
        const <String, dynamic>{},
  );

  static Future<Map<String, dynamic>> installZip(String path) async =>
      Map<String, dynamic>.from(
        await _channel.invokeMapMethod<String, dynamic>('installZip', {
              'path': path,
            }) ??
            const <String, dynamic>{},
      );

  static Future<Map<String, dynamic>> installFolder(String path) async =>
      Map<String, dynamic>.from(
        await _channel.invokeMapMethod<String, dynamic>('installFolder', {
              'path': path,
            }) ??
        const <String, dynamic>{},
  );

  static Future<Map<String, dynamic>> launchGame({
    required String titleId,
    String? savestateId,
  }) async => Map<String, dynamic>.from(
    await _channel.invokeMapMethod<String, dynamic>('launchGame', {
          'titleId': titleId,
          if (savestateId != null) 'savestateId': savestateId,
        }) ??
        const <String, dynamic>{},
  );

  static Future<int> emulationState() async =>
      (await _channel.invokeMethod<int>('emulationState')) ?? 0;

  static Future<bool> stop() async =>
      (await _channel.invokeMethod<bool>('stop')) ?? false;
}
'''
    (ROOT / 'packages/rpcs3_internal_bridge/lib/rpcs3_internal_bridge.dart').write_text(
        bridge, encoding='utf-8'
    )

    service_path = ROOT / 'lib/services/rpcs3_internal_service.dart'
    service = service_path.read_text(encoding='utf-8')
    service = replace_once(
        service,
        '          expandedJitRegion: true,\n',
        '          expandedJitRegion: false,\n',
        'RPCS3 regular-arena initialize policy',
    )
    service = replace_once(
        service,
        "      _log.i('RPCS3 internal Core initialized with validated expanded JIT.');",
        "      _log.i('RPCS3 internal Core initialized with validated regular JIT arena.');",
        'RPCS3 runtime log',
    )
    service_path.write_text(service, encoding='utf-8')


def patch_dolphin_grid() -> None:
    path = ROOT / 'lib/screens/game_screen/my_games_grid.dart'
    text = path.read_text(encoding='utf-8')

    text = replace_once(
        text,
        "import 'package:neostation/services/game_service.dart';\n",
        "import 'package:neostation/services/game_service.dart';\n"
        "import 'package:neostation/services/dolphin_internal_v2_service.dart';\n"
        "import 'package:neostation/widgets/confirm_action_dialog.dart';\n",
        'Dolphin delete imports',
    )

    text = replace_once(
        text,
        "  // RetroAchievements info for the selected game (shown in the footer pill).\n",
        '''  // Long-press removal mode for the private DolphiniOS GameCube/Wii library.
  // A long press enters selection mode with one game selected; subsequent taps
  // add/remove games and the floating toolbar deletes the whole selection.
  final Set<String> _dolphinDeleteSelection = <String>{};
  bool _dolphinDeleteBusy = false;

  // RetroAchievements info for the selected game (shown in the footer pill).
''',
        'Dolphin delete state',
    )

    methods = r'''  bool _isDolphinGame(GameModel game) =>
      Platform.isIOS &&
      DolphinInternalV2Service.isDolphinSystem(_folderForGame(game));

  String _dolphinDeleteKey(GameModel game) =>
      '${_folderForGame(game)}|${game.romname}|${game.romPath ?? ''}';

  void _enterDolphinDeleteSelection(int index) {
    if (index < 0 || index >= widget.games.length) return;
    final game = widget.games[index];
    if (!_isDolphinGame(game) || _dolphinDeleteBusy) return;

    setState(() {
      _selectedIndex = index;
      _settledIndex = index;
      _dolphinDeleteSelection.add(_dolphinDeleteKey(game));
      _rowCache.clear();
    });
    _settleTimer?.cancel();
    widget.onGameSelected(game);
    _scheduleAchievementsLoad();
    SfxService().playNavSound();
  }

  void _toggleDolphinDeleteSelection(int index) {
    if (index < 0 || index >= widget.games.length || _dolphinDeleteBusy) return;
    final game = widget.games[index];
    if (!_isDolphinGame(game)) return;
    final key = _dolphinDeleteKey(game);

    setState(() {
      if (!_dolphinDeleteSelection.remove(key)) {
        _dolphinDeleteSelection.add(key);
      }
      _selectedIndex = index;
      _settledIndex = index;
      _rowCache.clear();
    });
    _settleTimer?.cancel();
    widget.onGameSelected(game);
    _scheduleAchievementsLoad();
    SfxService().playNavSound();
  }

  void _cancelDolphinDeleteSelection() {
    if (_dolphinDeleteBusy || _dolphinDeleteSelection.isEmpty) return;
    setState(() {
      _dolphinDeleteSelection.clear();
      _rowCache.clear();
    });
    SfxService().playBackSound();
  }

  Future<void> _confirmDeleteSelectedDolphinGames() async {
    if (_dolphinDeleteBusy || _dolphinDeleteSelection.isEmpty) return;
    final selected = widget.games
        .where(
          (game) =>
              _isDolphinGame(game) &&
              _dolphinDeleteSelection.contains(_dolphinDeleteKey(game)),
        )
        .toList(growable: false);
    if (selected.isEmpty) {
      _cancelDolphinDeleteSelection();
      return;
    }

    final fr = Localizations.localeOf(context).languageCode == 'fr';
    final count = selected.length;
    SfxService().playNavSound();
    final confirmed = await ConfirmActionDialog.show(
      context,
      title: fr
          ? (count == 1 ? 'Supprimer ce jeu ?' : 'Supprimer $count jeux ?')
          : (count == 1 ? 'Delete this game?' : 'Delete $count games?'),
      body: fr
          ? 'Les images de jeu sélectionnées seront supprimées définitivement de la bibliothèque DolphiniOS.'
          : 'The selected game images will be permanently removed from the DolphiniOS library.',
      confirmLabel: AppLocale.delete.getString(context),
      icon: Icons.delete_forever_rounded,
    );
    if (confirmed == true && mounted) {
      await _deleteSelectedDolphinGames(selected);
    }
  }

  Future<void> _deleteSelectedDolphinGames(List<GameModel> selected) async {
    if (_dolphinDeleteBusy) return;
    setState(() => _dolphinDeleteBusy = true);

    final failed = <String>{};
    final refreshFolders = <String>{};

    for (final game in selected) {
      final key = _dolphinDeleteKey(game);
      final folder = _folderForGame(game);
      try {
        await GameRepository.deleteGame(
          appSystemId: game.systemId ?? widget.system.id,
          filename: game.romname,
          systemFolderName: folder,
          romBaseName: game.romname,
          romPath: game.romPath,
          fileProvider: widget.fileProvider,
        );
        refreshFolders.add(folder);
      } catch (error) {
        failed.add(key);
        debugPrint('DolphiniOS multi-delete failed for ${game.romname}: $error');
      }
    }

    if (!mounted) return;
    final config = context.read<SqliteConfigProvider>();
    for (final folder in refreshFolders) {
      try {
        await config.refreshDolphinInternalLibrary(folder);
      } catch (error) {
        debugPrint('DolphiniOS library refresh failed for $folder: $error');
      }
      if (!mounted) return;
    }

    setState(() {
      _dolphinDeleteBusy = false;
      _dolphinDeleteSelection
        ..clear()
        ..addAll(failed);
      _rowCache.clear();
    });
  }

  Widget _buildDolphinDeleteOverlay(ThemeData theme) {
    return Positioned.fill(
      child: IgnorePointer(
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12.r),
            border: Border.all(
              color: theme.colorScheme.error,
              width: 4.r,
            ),
            color: theme.colorScheme.error.withValues(alpha: 0.10),
          ),
          child: Align(
            alignment: Alignment.topRight,
            child: Container(
              margin: EdgeInsets.all(6.r),
              padding: EdgeInsets.all(4.r),
              decoration: BoxDecoration(
                color: theme.colorScheme.error,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.check_rounded,
                color: theme.colorScheme.onError,
                size: 18.r,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDolphinDeleteToolbar(ThemeData theme) {
    final fr = Localizations.localeOf(context).languageCode == 'fr';
    final count = _dolphinDeleteSelection.length;
    return SafeArea(
      child: Material(
        elevation: 8,
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(18.r),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 5.r),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18.r),
            border: Border.all(
              color: theme.colorScheme.outline.withValues(alpha: 0.45),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: fr ? 'Annuler la sélection' : 'Cancel selection',
                onPressed:
                    _dolphinDeleteBusy ? null : _cancelDolphinDeleteSelection,
                icon: const Icon(Icons.close_rounded),
              ),
              Text(
                fr
                    ? '$count sélectionné${count > 1 ? 's' : ''}'
                    : '$count selected',
                style: TextStyle(
                  fontSize: 13.r,
                  fontWeight: FontWeight.w700,
                ),
              ),
              SizedBox(width: 6.r),
              _dolphinDeleteBusy
                  ? Padding(
                      padding: EdgeInsets.all(10.r),
                      child: SizedBox(
                        width: 20.r,
                        height: 20.r,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.r,
                          color: theme.colorScheme.error,
                        ),
                      ),
                    )
                  : IconButton(
                      tooltip: fr
                          ? 'Supprimer la sélection'
                          : 'Delete selection',
                      onPressed: _confirmDeleteSelectedDolphinGames,
                      color: theme.colorScheme.error,
                      icon: const Icon(Icons.delete_forever_rounded),
                    ),
            ],
          ),
        ),
      ),
    );
  }

'''
    text = replace_once(
        text,
        "  @override\n  void dispose() {\n",
        methods + "  @override\n  void dispose() {\n",
        'Dolphin delete methods',
    )

    text = replace_once(
        text,
        "    if (widget.selectedIndex != oldWidget.selectedIndex) {\n",
        '''    if (widget.games != oldWidget.games &&
        _dolphinDeleteSelection.isNotEmpty) {
      final validKeys = widget.games
          .where(_isDolphinGame)
          .map(_dolphinDeleteKey)
          .toSet();
      _dolphinDeleteSelection.removeWhere((key) => !validKeys.contains(key));
    }
    if (widget.selectedIndex != oldWidget.selectedIndex) {
''',
        'Dolphin stale selection cleanup',
    )

    tap_guard = r'''      onTap: () {
        if (_dolphinDeleteSelection.isNotEmpty) {
          _toggleDolphinDeleteSelection(index);
          return;
        }
'''
    text = replace_once(
        text,
        "      onTap: () {\n        // Second tap on the already-selected card plays it — touch users have\n",
        '''      onLongPress: _isDolphinGame(game)
          ? () => _enterDolphinDeleteSelection(index)
          : null,
''' + tap_guard +
        "        // Second tap on the already-selected card plays it — touch users have\n",
        'Dolphin box-card long press',
    )
    text = replace_once(
        text,
        "      onTap: () {\n        // Second tap on the already-selected card plays it — touch users have\n",
        '''      onLongPress: _isDolphinGame(game)
          ? () => _enterDolphinDeleteSelection(index)
          : null,
''' + tap_guard +
        "        // Second tap on the already-selected card plays it — touch users have\n",
        'Dolphin fanart-card long press',
    )

    text = replace_once(
        text,
        "            if (game.isFavorite == true)\n",
        '''            if (_dolphinDeleteSelection.contains(_dolphinDeleteKey(game)))
              _buildDolphinDeleteOverlay(theme),
            if (game.isFavorite == true)
''',
        'Dolphin box-card selection overlay',
    )
    text = replace_once(
        text,
        "                if (game.isFavorite == true)\n",
        '''                if (_dolphinDeleteSelection.contains(_dolphinDeleteKey(game)))
                  _buildDolphinDeleteOverlay(theme),
                if (game.isFavorite == true)
''',
        'Dolphin fanart-card selection overlay',
    )

    text = replace_once(
        text,
        "        // Touch: swipe-right from the left edge reveals a hidden legend.\n        const LegendEdgeReshowZone(),\n",
        '''        if (_dolphinDeleteSelection.isNotEmpty)
          Positioned(
            top: 8.r,
            left: 0,
            right: 0,
            child: Align(
              alignment: Alignment.topCenter,
              child: _buildDolphinDeleteToolbar(Theme.of(context)),
            ),
          ),
        // Touch: swipe-right from the left edge reveals a hidden legend.
        const LegendEdgeReshowZone(),
''',
        'Dolphin delete toolbar',
    )

    path.write_text(text, encoding='utf-8')


def patch_contract_test() -> None:
    test = r'''import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('RPCS3 attaches JIT before loading Core and uses the regular arena', () {
    final bridge = File(
      'packages/rpcs3_internal_bridge/lib/rpcs3_internal_bridge.dart',
    ).readAsStringSync();
    final service = File(
      'lib/services/rpcs3_internal_service.dart',
    ).readAsStringSync();

    expect(bridge, isNot(contains('DynamicLibrary.open(')));
    expect(bridge, isNot(contains('preloadCoreImage(')));
    expect(bridge, contains('bool expandedJitRegion = false'));
    expect(service, contains('expandedJitRegion: false'));

    final prepare = service.indexOf('Rpcs3InternalBridge.prepareJit');
    final initialize = service.indexOf('Rpcs3InternalBridge.initialize');
    expect(prepare, greaterThanOrEqualTo(0));
    expect(initialize, greaterThan(prepare));
  });

  test('Dolphin grid supports long-press multi-selection deletion', () {
    final grid = File(
      'lib/screens/game_screen/my_games_grid.dart',
    ).readAsStringSync();

    expect(grid, contains('onLongPress: _isDolphinGame(game)'));
    expect(grid, contains('_dolphinDeleteSelection'));
    expect(grid, contains('_confirmDeleteSelectedDolphinGames'));
    expect(grid, contains('_deleteSelectedDolphinGames'));
    expect(grid, contains('GameRepository.deleteGame('));
    expect(grid, contains('refreshDolphinInternalLibrary(folder)'));
  });
}
'''
    (ROOT / 'test/rpcs3_preload_and_dolphin_delete_contract_test.dart').write_text(
        test, encoding='utf-8'
    )


def main() -> None:
    patch_rpcs3_bridge()
    patch_dolphin_grid()
    patch_contract_test()
    print('Build 227 hotfix applied: RPCS3 regular arena + DolphiniOS long-press multi-delete.')


if __name__ == '__main__':
    main()
