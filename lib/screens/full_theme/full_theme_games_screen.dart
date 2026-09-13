import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../constants/system_folder_names.dart';
import '../../models/full_theme_definition.dart';
import '../../models/game_model.dart';
import '../../models/system_model.dart';
import '../../providers/file_provider.dart';
import '../../providers/sqlite_config_provider.dart';
import '../../providers/sqlite_database_provider.dart';
import '../../services/game_service.dart';
import '../../services/logger_service.dart';
import '../../services/music_player_service.dart';
import '../../services/sfx_service.dart';
import '../../utils/game_launch_utils.dart';
import '../../utils/gamepad_nav.dart';
import '../game_screen/game_settings_dialog/game_settings_dialog.dart';

/// Arcade Planet-inspired playlist that belongs to the active full theme.
///
/// This is intentionally not a fourth `gameViewMode`: when a full theme is
/// active every normal game playlist routes here and the user's old
/// list/grid/carousel preference is ignored until the full theme is removed.
class FullThemeGamesScreen extends StatefulWidget {
  const FullThemeGamesScreen({
    super.key,
    required this.theme,
    required this.system,
    required this.fileProvider,
  });

  final FullThemeDefinition theme;
  final SystemModel system;
  final FileProvider fileProvider;

  @override
  State<FullThemeGamesScreen> createState() => _FullThemeGamesScreenState();
}

class _FullThemeGamesScreenState extends State<FullThemeGamesScreen> {
  static final _log = LoggerService.instance;
  static const _layerId = 'full_theme_games';

  final ScrollController _listController = ScrollController();
  late final GamepadNavigation _gamepadNav;

  List<GameModel> _games = const [];
  int _selectedIndex = 0;
  bool _loading = true;
  bool _launching = false;

  GameModel? get _selected =>
      _games.isEmpty ? null : _games[_selectedIndex.clamp(0, _games.length - 1)];

  Color get _accent {
    final value = widget.theme.accentHex.replaceAll('#', '');
    final six = value.length >= 6 ? value.substring(0, 6) : '565296';
    return Color(int.parse('FF$six', radix: 16));
  }

  @override
  void initState() {
    super.initState();
    _gamepadNav = GamepadNavigation(
      onNavigateUp: () => _move(-1),
      onNavigateDown: () => _move(1),
      onNavigateLeft: () => _move(-5),
      onNavigateRight: () => _move(5),
      onSelectItem: _launchSelected,
      onBack: _goBack,
      onFavorite: _toggleFavorite,
      onSettings: _openSettings,
      accelerateRepeats: true,
    );
    _loadGames();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _gamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        _layerId,
        onActivate: _gamepadNav.activate,
        onDeactivate: _gamepadNav.deactivate,
      );
    });
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer(_layerId);
    _gamepadNav.dispose();
    _listController.dispose();
    super.dispose();
  }

  Future<void> _loadGames({String? preserveRom}) async {
    try {
      final games = await GameService.loadGamesForSystem(widget.system);
      if (!mounted) return;
      var index = 0;
      if (preserveRom != null) {
        final preserved = games.indexWhere((g) => g.romname == preserveRom);
        if (preserved >= 0) index = preserved;
      }
      setState(() {
        _games = games;
        _selectedIndex = games.isEmpty ? 0 : index.clamp(0, games.length - 1);
        _loading = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _ensureSelectionVisible());
    } catch (e, st) {
      _log.e('[FullTheme] Could not load playlist', error: e, stackTrace: st);
      if (mounted) setState(() => _loading = false);
    }
  }

  void _move(int delta) {
    if (_games.isEmpty || _launching) return;
    final next = (_selectedIndex + delta).clamp(0, _games.length - 1);
    if (next == _selectedIndex) return;
    SfxService().playNavSound();
    setState(() => _selectedIndex = next);
    _ensureSelectionVisible();
  }

  void _ensureSelectionVisible() {
    if (!_listController.hasClients || _games.isEmpty) return;
    // Rows are intentionally fixed-height to make gamepad centering cheap and
    // deterministic even with very large libraries.
    final target = (_selectedIndex * 54.r) - (_listController.position.viewportDimension / 2) + 27.r;
    _listController.animateTo(
      target.clamp(0.0, _listController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
    );
  }

  String _mediaFolder(GameModel game) {
    if ((widget.system.folderName == SystemFolderNames.all ||
            widget.system.folderName == SystemFolderNames.favorites) &&
        game.systemFolderName != null &&
        game.systemFolderName!.isNotEmpty) {
      return game.systemFolderName!;
    }
    return widget.system.primaryFolderName;
  }

  String? _existingPath(String path) {
    if (path.isEmpty) return null;
    final file = File(path);
    return file.existsSync() ? file.path : null;
  }

  String? _fanart(GameModel game) => _existingPath(
    game.getImagePath(_mediaFolder(game), 'fanarts', widget.fileProvider),
  );

  String? _box(GameModel game) => _existingPath(
    game.getImagePath(_mediaFolder(game), 'box2d', widget.fileProvider),
  );

  String? _wheel(GameModel game) => _existingPath(
    game.getImagePath(_mediaFolder(game), 'wheels', widget.fileProvider),
  );

  String? _screenshot(GameModel game) =>
      _existingPath(game.getScreenshotPath(_mediaFolder(game), widget.fileProvider));

  Future<SystemModel> _systemForLaunch(GameModel game) async {
    if ((widget.system.folderName == SystemFolderNames.all ||
            widget.system.folderName == SystemFolderNames.favorites) &&
        game.systemFolderName != null) {
      final systems = context.read<SqliteConfigProvider>().availableSystems;
      return systems.firstWhere(
        (system) => system.folderName == game.systemFolderName,
        orElse: () => widget.system,
      );
    }
    return widget.system;
  }

  Future<void> _launchSelected() async {
    final game = _selected;
    if (game == null || _launching) return;

    if (widget.system.folderName == 'music') {
      final music = MusicPlayerService();
      final current = music.activeTrack?.romPath == game.romPath;
      if (music.isPlaying && current) {
        music.pause();
      } else if (current && music.isStarted) {
        music.resume();
      } else {
        music.start(index: _selectedIndex);
      }
      if (mounted) setState(() {});
      return;
    }

    final system = await _systemForLaunch(game);
    if (!mounted) return;

    setState(() => _launching = true);
    GamepadNavigationManager.deactivateAll();
    imageCache.clear();
    imageCache.clearLiveImages();

    try {
      await launchGameWithDialog(
        context: context,
        game: game,
        system: system,
        fileProvider: widget.fileProvider,
        onGameClosed: () async {
          if (!mounted) return;
          await _loadGames(preserveRom: game.romname);
          if (!mounted) return;
          setState(() => _launching = false);
          context.read<SqliteDatabaseProvider>().refresh();
          GamepadNavigationManager.reactivate();
        },
        onLaunchFailed: (ctx, result) async {
          if (!mounted) return;
          setState(() => _launching = false);
          GamepadNavigationManager.reactivate();
          ScaffoldMessenger.of(ctx).showSnackBar(
            SnackBar(content: Text('Unable to launch ${game.name}')),
          );
        },
      );
    } catch (e, st) {
      _log.e('[FullTheme] Launch failed', error: e, stackTrace: st);
      if (mounted) setState(() => _launching = false);
      GamepadNavigationManager.reactivate();
    }
  }

  Future<void> _toggleFavorite() async {
    final game = _selected;
    if (game == null) return;
    try {
      await GameService.toggleFavorite(game);
      await context.read<SqliteConfigProvider>().refreshDetectedSystems();
      await _loadGames(preserveRom: game.romname);
    } catch (e) {
      _log.w('[FullTheme] Favorite toggle failed: $e');
    }
  }

  Future<void> _openSettings() async {
    final game = _selected;
    if (game == null) return;
    final system = await _systemForLaunch(game);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => GameSettingsDialog(
        game: game,
        system: system,
        fileProvider: widget.fileProvider,
        isAllMode:
            widget.system.folderName == SystemFolderNames.all ||
            widget.system.folderName == SystemFolderNames.favorites,
        onGameUpdated: () => _loadGames(preserveRom: game.romname),
        onGameDeleted: (_) => _loadGames(),
      ),
    );
  }

  void _goBack() {
    if (_launching) return;
    SfxService().playBackSound();
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final game = _selected;
    final backdrop = game == null
        ? widget.theme.systemBackdrop(widget.system.folderName)
        : (_fanart(game) ?? widget.theme.systemBackdrop(_mediaFolder(game)));

    return PopScope(
      canPop: !_launching,
      child: Scaffold(
        backgroundColor: const Color(0xFF111017),
        body: Stack(
          fit: StackFit.expand,
          children: [
            _FullThemeBackdrop(path: backdrop, accent: _accent),
            Container(color: Colors.black.withValues(alpha: 0.36)),
            SafeArea(
              child: _loading
                  ? Center(child: CircularProgressIndicator(color: _accent))
                  : _games.isEmpty
                      ? _emptyView()
                      : Padding(
                          padding: EdgeInsets.fromLTRB(26.r, 18.r, 26.r, 18.r),
                          child: Column(
                            children: [
                              _header(game!),
                              SizedBox(height: 12.r),
                              Expanded(
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    SizedBox(width: 0.36.sw, child: _gameList()),
                                    SizedBox(width: 24.r),
                                    Expanded(child: _gamePresentation(game)),
                                  ],
                                ),
                              ),
                              SizedBox(height: 10.r),
                              _footer(game),
                            ],
                          ),
                        ),
            ),
            if (_launching)
              ColoredBox(
                color: Colors.black.withValues(alpha: 0.62),
                child: const Center(child: CircularProgressIndicator()),
              ),
          ],
        ),
      ),
    );
  }

  Widget _emptyView() => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.sports_esports_rounded, color: _accent, size: 54.r),
        SizedBox(height: 12.r),
        Text(
          widget.system.realName,
          style: TextStyle(
            color: Colors.white,
            fontFamily: 'NeoStationFullThemeBold',
            fontSize: 28.r,
          ),
        ),
        SizedBox(height: 6.r),
        Text('No games found', style: TextStyle(color: Colors.white70, fontSize: 15.r)),
      ],
    ),
  );

  Widget _header(GameModel game) {
    final themeLogo = widget.theme.rasterSystemLogo(widget.system.folderName);
    return SizedBox(
      height: 76.r,
      child: Row(
        children: [
          if (themeLogo != null)
            Image.file(File(themeLogo), height: 62.r, width: 180.r, fit: BoxFit.contain)
          else
            Text(
              widget.system.realName.toUpperCase(),
              style: TextStyle(
                color: Colors.white,
                fontFamily: 'NeoStationFullThemeBold',
                fontSize: 29.r,
                letterSpacing: 1.1,
                shadows: const [Shadow(color: Colors.black, blurRadius: 8)],
              ),
            ),
          const Spacer(),
          Text(
            '${_selectedIndex + 1} / ${_games.length}',
            style: TextStyle(
              color: Colors.white70,
              fontFamily: 'NeoStationFullTheme',
              fontSize: 16.r,
            ),
          ),
        ],
      ),
    );
  }

  Widget _gameList() {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xDD1B1A21),
        borderRadius: BorderRadius.circular(14.r),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14.r),
        child: ListView.builder(
          controller: _listController,
          padding: EdgeInsets.symmetric(vertical: 10.r),
          itemExtent: 54.r,
          itemCount: _games.length,
          itemBuilder: (context, index) {
            final item = _games[index];
            final selected = index == _selectedIndex;
            return InkWell(
              onTap: () {
                SfxService().playNavSound();
                setState(() => _selectedIndex = index);
              },
              onDoubleTap: _launchSelected,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 130),
                margin: EdgeInsets.symmetric(horizontal: 8.r, vertical: 3.r),
                padding: EdgeInsets.symmetric(horizontal: 14.r),
                decoration: BoxDecoration(
                  color: selected ? _accent.withValues(alpha: 0.78) : Colors.transparent,
                  borderRadius: BorderRadius.circular(7.r),
                ),
                child: Row(
                  children: [
                    if (item.isFavorite == true)
                      Padding(
                        padding: EdgeInsets.only(right: 8.r),
                        child: Icon(Icons.star_rounded, size: 17.r, color: Colors.amberAccent),
                      ),
                    Expanded(
                      child: Text(
                        item.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: selected ? Colors.white : Colors.white70,
                          fontFamily: selected ? 'NeoStationFullThemeBold' : 'NeoStationFullTheme',
                          fontSize: 17.r,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _gamePresentation(GameModel game) {
    final screenshot = _screenshot(game);
    final box = _box(game);
    final wheel = _wheel(game);
    final locale = Localizations.localeOf(context).languageCode;
    final description = game.getDescriptionForLanguage(locale) ??
        game.getDescriptionForLanguage('en') ??
        '';

    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.38),
        borderRadius: BorderRadius.circular(16.r),
        border: Border.all(color: Colors.white.withValues(alpha: 0.09)),
      ),
      child: Padding(
        padding: EdgeInsets.all(18.r),
        child: Column(
          children: [
            Expanded(
              flex: 7,
              child: Row(
                children: [
                  Expanded(
                    flex: 6,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12.r),
                      child: screenshot != null
                          ? Image.file(File(screenshot), fit: BoxFit.cover, width: double.infinity, height: double.infinity)
                          : _artPlaceholder(Icons.image_rounded),
                    ),
                  ),
                  SizedBox(width: 18.r),
                  Expanded(
                    flex: 3,
                    child: box != null
                        ? Image.file(File(box), fit: BoxFit.contain)
                        : _artPlaceholder(Icons.view_in_ar_rounded),
                  ),
                ],
              ),
            ),
            SizedBox(height: 14.r),
            if (wheel != null)
              SizedBox(height: 66.r, child: Image.file(File(wheel), fit: BoxFit.contain))
            else
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  game.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white,
                    fontFamily: 'NeoStationFullThemeBold',
                    fontSize: 28.r,
                  ),
                ),
              ),
            SizedBox(height: 10.r),
            Expanded(
              flex: 3,
              child: Align(
                alignment: Alignment.topLeft,
                child: Text(
                  description,
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.72),
                    fontFamily: 'NeoStationFullTheme',
                    height: 1.28,
                    fontSize: 14.r,
                  ),
                ),
              ),
            ),
            _metadata(game),
          ],
        ),
      ),
    );
  }

  Widget _metadata(GameModel game) {
    final items = <String>[
      if (game.year.isNotEmpty) game.year,
      if (game.genre.isNotEmpty) game.genre,
      if (game.players.isNotEmpty) game.players,
      if (game.developer.isNotEmpty) game.developer,
    ];
    return Align(
      alignment: Alignment.centerLeft,
      child: Wrap(
        spacing: 8.r,
        runSpacing: 6.r,
        children: items
            .map(
              (value) => Container(
                padding: EdgeInsets.symmetric(horizontal: 9.r, vertical: 5.r),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(20.r),
                ),
                child: Text(
                  value,
                  style: TextStyle(color: Colors.white70, fontSize: 11.r),
                ),
              ),
            )
            .toList(),
      ),
    );
  }

  Widget _artPlaceholder(IconData icon) => ColoredBox(
    color: Colors.black.withValues(alpha: 0.28),
    child: Center(child: Icon(icon, size: 54.r, color: Colors.white24)),
  );

  Widget _footer(GameModel game) {
    return Row(
      children: [
        _hint('A', widget.system.folderName == 'music' ? 'Play / Pause' : 'Play'),
        SizedBox(width: 16.r),
        _hint('B', 'Back'),
        SizedBox(width: 16.r),
        _hint('Y', game.isFavorite == true ? 'Unfavorite' : 'Favorite'),
        SizedBox(width: 16.r),
        _hint('START', 'Game settings'),
        const Spacer(),
        Text(
          widget.theme.name,
          style: TextStyle(color: Colors.white38, fontSize: 11.r),
        ),
      ],
    );
  }

  Widget _hint(String key, String label) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        padding: EdgeInsets.symmetric(horizontal: 7.r, vertical: 3.r),
        decoration: BoxDecoration(
          color: _accent.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(5.r),
        ),
        child: Text(
          key,
          style: TextStyle(
            color: Colors.white,
            fontFamily: 'NeoStationFullThemeBold',
            fontSize: 10.r,
          ),
        ),
      ),
      SizedBox(width: 5.r),
      Text(label, style: TextStyle(color: Colors.white60, fontSize: 11.r)),
    ],
  );
}

class _FullThemeBackdrop extends StatelessWidget {
  const _FullThemeBackdrop({required this.path, required this.accent});

  final String? path;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (path != null)
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 420),
            child: Image.file(
              File(path!),
              key: ValueKey(path),
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
          ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                const Color(0xFF17141D).withValues(alpha: 0.86),
                accent.withValues(alpha: 0.28),
                const Color(0xFF09080C).withValues(alpha: 0.94),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
