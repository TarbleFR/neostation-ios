import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_locale.dart';
import '../../models/full_theme_definition.dart';
import '../../models/my_systems.dart';
import '../../models/system_model.dart';
import '../../providers/file_provider.dart';
import '../../providers/sqlite_config_provider.dart';
import '../../providers/sqlite_database_provider.dart';
import '../../services/game_service.dart';
import '../../services/logger_service.dart';
import '../../services/sfx_service.dart';
import '../../utils/game_launch_utils.dart';
import '../../utils/gamepad_nav.dart';
import '../app_screen.dart';
import '../systems_screen/my_systems_section/system_list_builder.dart';
import 'full_theme_games_screen.dart';

/// Full-screen owner for an imported full theme.
///
/// The widget installs itself into the Navigator overlay so it covers
/// NeoStation's normal header/footer as well as the systems body. This is the
/// important distinction from adding a `full_theme` value to the existing
/// grid/carousel setting: while mounted, the imported theme owns the whole home
/// experience. It temporarily removes the overlay before pushing a playlist or
/// launch dialog, then restores it on return.
class FullThemeSystemsView extends StatefulWidget {
  const FullThemeSystemsView({
    super.key,
    required this.theme,
    this.selectedIndex = 0,
    this.onCardTapped,
  });

  final FullThemeDefinition theme;
  final int selectedIndex;
  final ValueChanged<int>? onCardTapped;

  @override
  State<FullThemeSystemsView> createState() => _FullThemeSystemsViewState();
}

class _FullThemeSystemsViewState extends State<FullThemeSystemsView> {
  static final _log = LoggerService.instance;
  static const _layerId = 'full_theme_systems';

  OverlayEntry? _overlayEntry;
  late final GamepadNavigation _gamepadNav;
  int _selectedIndex = 0;
  bool _navigating = false;
  bool _overlaySuspended = false;
  Timer? _clockTimer;
  DateTime _now = DateTime.now();

  Color get _accent {
    final value = widget.theme.accentHex.replaceAll('#', '');
    final six = value.length >= 6 ? value.substring(0, 6) : '565296';
    return Color(int.parse('FF$six', radix: 16));
  }

  @override
  void initState() {
    super.initState();
    _selectedIndex = widget.selectedIndex;
    _gamepadNav = GamepadNavigation(
      onNavigateLeft: () => _move(-1),
      onNavigateRight: () => _move(1),
      onNavigateUp: () => _move(-1),
      onNavigateDown: () => _move(1),
      onSelectItem: _openSelected,
      onPreviousTab: AppScreen.previousTab,
      onNextTab: AppScreen.nextTab,
    );
    _clockTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted) {
        _now = DateTime.now();
        _overlayEntry?.markNeedsBuild();
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _installOverlay();
      _gamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        _layerId,
        onActivate: _gamepadNav.activate,
        onDeactivate: _gamepadNav.deactivate,
      );
    });
  }

  @override
  void didUpdateWidget(covariant FullThemeSystemsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.theme.id != widget.theme.id) {
      _overlayEntry?.markNeedsBuild();
    }
    if (widget.selectedIndex != oldWidget.selectedIndex && !_navigating) {
      _selectedIndex = widget.selectedIndex;
      _overlayEntry?.markNeedsBuild();
    }
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _removeOverlay();
    GamepadNavigationManager.popLayer(_layerId);
    _gamepadNav.dispose();
    super.dispose();
  }

  void _installOverlay() {
    if (!mounted || _overlayEntry != null || _overlaySuspended) return;
    final overlay = Overlay.of(context, rootOverlay: true);
    _overlayEntry = OverlayEntry(
      builder: (overlayContext) => Positioned.fill(
        child: Material(
          color: Colors.transparent,
          child: _buildFullScreen(overlayContext),
        ),
      ),
    );
    overlay.insert(_overlayEntry!);
  }

  void _removeOverlay() {
    try {
      _overlayEntry?.remove();
    } catch (_) {}
    _overlayEntry = null;
  }

  void _suspendOverlay() {
    _overlaySuspended = true;
    _removeOverlay();
  }

  void _resumeOverlay() {
    if (!mounted) return;
    _overlaySuspended = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _installOverlay();
    });
  }

  List<SystemInfo> _systems(BuildContext context) {
    final config = context.read<SqliteConfigProvider>();
    final database = context.read<SqliteDatabaseProvider>();
    final files = context.read<FileProvider>();
    return buildSystemsList(
      context: context,
      configProvider: config,
      dbProvider: database,
      fileProvider: files,
    );
  }

  void _move(int delta) {
    if (_navigating || _overlayEntry == null) return;
    final systems = _systems(context);
    if (systems.isEmpty) return;
    final next = (_selectedIndex + delta).clamp(0, systems.length - 1).toInt();
    if (next == _selectedIndex) return;
    SfxService().playNavSound();
    _selectedIndex = next;
    widget.onCardTapped?.call(next);
    _overlayEntry?.markNeedsBuild();
  }

  Future<void> _openSelected() async {
    if (_navigating) return;
    final systems = _systems(context);
    if (systems.isEmpty) return;
    final index = _selectedIndex.clamp(0, systems.length - 1).toInt();
    await _navigateTo(systems[index]);
  }

  Future<void> _navigateTo(SystemInfo info) async {
    if (_navigating) return;
    _navigating = true;
    final config = context.read<SqliteConfigProvider>();
    final files = context.read<FileProvider>();
    SfxService().playEnterSound();

    try {
      // Recent-game cards remain direct launch shortcuts, but the full-theme
      // overlay is removed first so the standard launch dialog is actually on
      // top and remains usable.
      if (info.isGame && info.gameModel != null) {
        final game = info.gameModel!;
        final system = config.availableSystems.cast<SystemModel?>().firstWhere(
          (candidate) => candidate?.folderName == game.systemFolderName,
          orElse: () => null,
        );
        if (system == null) return;

        _suspendOverlay();
        GamepadNavigationManager.deactivateAll();
        imageCache.clear();
        imageCache.clearLiveImages();
        await launchGameWithDialog(
          context: context,
          game: game,
          system: system,
          fileProvider: files,
          onGameClosed: () {
            if (!mounted) return;
            context.read<SqliteDatabaseProvider>().refresh();
            _resumeOverlay();
            GamepadNavigationManager.reactivate();
          },
          onLaunchFailed: (ctx, result) async {
            _resumeOverlay();
            GamepadNavigationManager.reactivate();
          },
        );
        return;
      }

      final system = _resolveSystem(info, config);
      if (system == null || !mounted) return;

      _suspendOverlay();
      GamepadNavigationManager.deactivateAll();
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => FullThemeGamesScreen(
            theme: widget.theme,
            system: system,
            fileProvider: files,
          ),
        ),
      );
      if (!mounted) return;
      context.read<SqliteDatabaseProvider>().refresh();
    } catch (e, st) {
      _log.e('[FullTheme] System navigation failed', error: e, stackTrace: st);
    } finally {
      _navigating = false;
      if (mounted) {
        _resumeOverlay();
        GamepadNavigationManager.reactivate();
      }
    }
  }

  SystemModel? _resolveSystem(
    SystemInfo info,
    SqliteConfigProvider config,
  ) {
    if (info.folderName == 'all') {
      final existing = config.detectedSystems.cast<SystemModel?>().firstWhere(
        (system) => system?.folderName == 'all',
        orElse: () => null,
      );
      return SystemModel(
        id: 'all',
        folderName: 'all',
        realName: existing?.realName ?? 'All Games',
        iconImage: existing?.iconImage ?? '/images/icons/folder-bulk.png',
        color: existing?.color ?? '#565296',
        customBackgroundPath: existing?.customBackgroundPath,
        customLogoPath: existing?.customLogoPath,
        hideLogo: existing?.hideLogo ?? false,
        imageVersion: existing?.imageVersion ?? 0,
        romCount: config.totalGames,
        detected: true,
      );
    }

    return config.detectedSystems.cast<SystemModel?>().firstWhere(
      (system) => system?.folderName == info.folderName,
      orElse: () => null,
    );
  }

  Widget _buildFullScreen(BuildContext overlayContext) {
    return Consumer2<SqliteConfigProvider, SqliteDatabaseProvider>(
      builder: (context, config, database, _) {
        final files = context.read<FileProvider>();
        final systems = buildSystemsList(
          context: context,
          configProvider: config,
          dbProvider: database,
          fileProvider: files,
        );
        if (systems.isEmpty) {
          return ColoredBox(
            color: const Color(0xFF111017),
            child: Center(
              child: CircularProgressIndicator(color: _accent),
            ),
          );
        }

        if (_selectedIndex >= systems.length) _selectedIndex = systems.length - 1;
        final selected = systems[_selectedIndex];
        final folder = selected.primaryFolderName ?? selected.folderName ?? 'all';
        final themeBackground = widget.theme.systemBackdrop(folder);
        final fallbackBackground = selected.customBackgroundPath;
        final background = fallbackBackground != null &&
                fallbackBackground.isNotEmpty &&
                File(fallbackBackground).existsSync()
            ? fallbackBackground
            : themeBackground;

        return Stack(
          fit: StackFit.expand,
          children: [
            _background(background),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.18),
                    Colors.black.withValues(alpha: 0.02),
                    Colors.black.withValues(alpha: 0.72),
                  ],
                ),
              ),
            ),
            SafeArea(
              child: Padding(
                padding: EdgeInsets.fromLTRB(30.r, 22.r, 30.r, 18.r),
                child: Column(
                  children: [
                    _topBar(selected),
                    const Spacer(),
                    _selectedIdentity(selected),
                    SizedBox(height: 24.r),
                    _systemRibbon(systems),
                    SizedBox(height: 22.r),
                    _bottomBar(selected),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _background(String? path) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 650),
      switchInCurve: Curves.easeOutCubic,
      child: path != null
          ? Image.file(
              File(path),
              key: ValueKey(path),
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => _gradientBackground(),
            )
          : _gradientBackground(),
    );
  }

  Widget _gradientBackground() => DecoratedBox(
    key: const ValueKey('full_theme_gradient'),
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          const Color(0xFF18151D),
          _accent.withValues(alpha: 0.66),
          const Color(0xFF08070B),
        ],
      ),
    ),
  );

  Widget _topBar(SystemInfo selected) {
    final hour = _now.hour.toString().padLeft(2, '0');
    final minute = _now.minute.toString().padLeft(2, '0');
    return Row(
      children: [
        Text(
          widget.theme.name.toUpperCase(),
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.72),
            fontFamily: 'NeoStationFullThemeBold',
            fontSize: 16.r,
            letterSpacing: 2.4,
          ),
        ),
        const Spacer(),
        Text(
          '$hour:$minute',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.58),
            fontFamily: 'NeoStationFullTheme',
            fontSize: 18.r,
          ),
        ),
      ],
    );
  }

  Widget _selectedIdentity(SystemInfo selected) {
    final folder = selected.primaryFolderName ?? selected.folderName ?? 'all';
    final themeLogo = selected.isGame ? selected.customWheelImage : widget.theme.rasterSystemLogo(folder);
    final customLogo = selected.customLogoPath;
    final rasterLogo = _existing(customLogo) ?? _existing(themeLogo);

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 260),
      child: SizedBox(
        key: ValueKey(selected.folderName ?? selected.title),
        height: 150.r,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (rasterLogo != null)
              Expanded(
                child: Image.file(
                  File(rasterLogo),
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              )
            else
              Expanded(
                child: Center(
                  child: Text(
                    (selected.title ?? selected.shortName ?? 'NEOSTATION').toUpperCase(),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontFamily: 'NeoStationFullThemeBold',
                      fontSize: 42.r,
                      letterSpacing: 1.4,
                      shadows: const [
                        Shadow(color: Colors.black87, blurRadius: 12, offset: Offset(0, 2)),
                      ],
                    ),
                  ),
                ),
              ),
            SizedBox(height: 8.r),
            Text(
              selected.totalStorage ?? '${selected.numOfRoms ?? 0} games',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.62),
                fontFamily: 'NeoStationFullTheme',
                fontSize: 15.r,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String? _existing(String? value) {
    if (value == null || value.isEmpty) return null;
    return File(value).existsSync() ? value : null;
  }

  Widget _systemRibbon(List<SystemInfo> systems) {
    const visibleRadius = 3;
    final indices = <int>[];
    for (var offset = -visibleRadius; offset <= visibleRadius; offset++) {
      final index = _selectedIndex + offset;
      if (index >= 0 && index < systems.length) indices.add(index);
    }

    return SizedBox(
      height: 108.r,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: indices.map((index) {
          final system = systems[index];
          final selected = index == _selectedIndex;
          final distance = (index - _selectedIndex).abs();
          return GestureDetector(
            onTap: () {
              if (_navigating) return;
              SfxService().playNavSound();
              _selectedIndex = index;
              widget.onCardTapped?.call(index);
              _overlayEntry?.markNeedsBuild();
            },
            onDoubleTap: selected ? _openSelected : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 190),
              curve: Curves.easeOutCubic,
              width: selected ? 176.r : 116.r,
              height: selected ? 100.r : 72.r,
              margin: EdgeInsets.symmetric(horizontal: 8.r),
              padding: EdgeInsets.all(selected ? 12.r : 9.r),
              decoration: BoxDecoration(
                color: selected
                    ? _accent.withValues(alpha: 0.78)
                    : Colors.black.withValues(alpha: 0.42 - (distance * 0.05)),
                borderRadius: BorderRadius.circular(selected ? 16.r : 12.r),
                border: Border.all(
                  color: selected ? Colors.white70 : Colors.white12,
                  width: selected ? 2 : 1,
                ),
                boxShadow: selected
                    ? [
                        BoxShadow(
                          color: _accent.withValues(alpha: 0.45),
                          blurRadius: 24.r,
                          spreadRadius: 2.r,
                        ),
                      ]
                    : null,
              ),
              child: _systemTileContent(system, selected),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _systemTileContent(SystemInfo system, bool selected) {
    final folder = system.primaryFolderName ?? system.folderName ?? 'all';
    final themeLogo = system.isGame ? system.customWheelImage : widget.theme.rasterSystemLogo(folder);
    final raster = _existing(system.customLogoPath) ?? _existing(themeLogo);
    if (raster != null) {
      return Image.file(File(raster), fit: BoxFit.contain);
    }

    final asset = 'assets/images/logos/$folder.webp';
    return Image.asset(
      asset,
      fit: BoxFit.contain,
      errorBuilder: (_, __, ___) => Center(
        child: Text(
          system.shortName ?? system.title ?? folder.toUpperCase(),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: selected ? Colors.white : Colors.white70,
            fontFamily: 'NeoStationFullThemeBold',
            fontSize: selected ? 17.r : 13.r,
          ),
        ),
      ),
    );
  }

  Widget _bottomBar(SystemInfo selected) {
    return Row(
      children: [
        _hint('◀ ▶', 'Select'),
        SizedBox(width: 16.r),
        _hint('A', selected.isGame ? 'Play' : 'Enter'),
        SizedBox(width: 16.r),
        _hint('LB / RB', 'NeoStation tabs'),
        const Spacer(),
        if (widget.theme.author != null)
          Text(
            '${widget.theme.author} · ${widget.theme.license ?? ''}',
            style: TextStyle(color: Colors.white38, fontSize: 10.r),
          ),
      ],
    );
  }

  Widget _hint(String key, String label) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 4.r),
        decoration: BoxDecoration(
          color: _accent.withValues(alpha: 0.78),
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
      Text(
        label,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.62),
          fontFamily: 'NeoStationFullTheme',
          fontSize: 11.r,
        ),
      ),
    ],
  );
}
