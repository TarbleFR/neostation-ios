import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../models/full_theme_definition.dart';
import '../../models/my_systems.dart';
import '../../models/system_model.dart';
import '../../providers/file_provider.dart';
import '../../providers/sqlite_config_provider.dart';
import '../../providers/sqlite_database_provider.dart';
import '../../services/gamepad/gamepad_navigation_manager.dart';
import '../../services/logger_service.dart';
import '../../services/sfx_service.dart';
import '../../utils/game_launch_utils.dart';
import '../../utils/gamepad_nav.dart';
import '../app_screen.dart';
import '../systems_screen/my_systems_section/system_list_builder.dart';
import 'arcade_planet_system_scene.dart';
import 'full_theme_games_screen.dart';

/// Full-screen owner for an imported full theme.
///
/// This is intentionally not another systems layout. The normal Systems widget
/// remains mounted only as a lifecycle anchor while this view paints through a
/// root [OverlayEntry], covering NeoStation's normal header/footer. The overlay
/// is suspended before opening a playlist or the standard launch dialog and is
/// restored when the user comes back.
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
  Timer? _clockTimer;
  int _selectedIndex = 0;
  bool _navigating = false;
  bool _overlaySuspended = false;
  DateTime _now = DateTime.now();

  Color get _accent {
    final cleaned = widget.theme.accentHex.replaceAll('#', '');
    final six = cleaned.length >= 6 ? cleaned.substring(0, 6) : '565296';
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
      onPreviousTab: AppNavigation.previousTab,
      onNextTab: AppNavigation.nextTab,
    );

    _clockTimer = Timer.periodic(const Duration(seconds: 15), (timer) {
      if (!mounted) return;
      _now = DateTime.now();
      _overlayEntry?.markNeedsBuild();
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
    if (widget.selectedIndex != oldWidget.selectedIndex && !_navigating) {
      _selectedIndex = widget.selectedIndex;
    }
    if (widget.selectedIndex != oldWidget.selectedIndex ||
        widget.theme.id != oldWidget.theme.id) {
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

  /// The visible surface lives in the root overlay so it can cover AppScreen's
  /// global chrome. This child only keeps the lifecycle tied to SystemContent.
  @override
  Widget build(BuildContext context) => const SizedBox.expand();

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
    } catch (_) {
      // Overlay may already have been detached during route teardown.
    }
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

  List<SystemInfo> _systems(BuildContext sourceContext) {
    return buildSystemsList(
      context: sourceContext,
      configProvider: sourceContext.read<SqliteConfigProvider>(),
      dbProvider: sourceContext.read<SqliteDatabaseProvider>(),
      fileProvider: sourceContext.read<FileProvider>(),
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
          onLaunchFailed: (dialogContext, result) async {
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
          builder: (routeContext) => FullThemeGamesScreen(
            theme: widget.theme,
            system: system,
            fileProvider: files,
          ),
        ),
      );

      if (mounted) {
        context.read<SqliteDatabaseProvider>().refresh();
      }
    } catch (error, stackTrace) {
      _log.e(
        '[FullTheme] System navigation failed',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      _navigating = false;
      if (mounted) {
        _resumeOverlay();
        GamepadNavigationManager.reactivate();
      }
    }
  }

  SystemModel? _resolveSystem(SystemInfo info, SqliteConfigProvider config) {
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
      builder: (context, config, database, child) {
        final systems = buildSystemsList(
          context: context,
          configProvider: config,
          dbProvider: database,
          fileProvider: context.read<FileProvider>(),
        );

        if (systems.isEmpty) {
          return ColoredBox(
            color: const Color(0xFF111017),
            child: Center(child: CircularProgressIndicator(color: _accent)),
          );
        }

        if (_selectedIndex >= systems.length) {
          _selectedIndex = systems.length - 1;
        }
        if (_selectedIndex < 0) _selectedIndex = 0;

        final selected = systems[_selectedIndex];
        final folder = selected.primaryFolderName ?? selected.folderName ?? 'all';

        return Stack(
          fit: StackFit.expand,
          children: [
            if (widget.theme.isArcadePlanet)
              ArcadePlanetSystemScene(
                theme: widget.theme,
                systemFolder: folder,
                accent: _accent,
              )
            else
              _background(widget.theme.systemBackdrop(folder)),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.10),
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.62),
                  ],
                ),
              ),
            ),
            SafeArea(
              child: Padding(
                padding: EdgeInsets.fromLTRB(30.r, 22.r, 30.r, 18.r),
                child: Column(
                  children: [
                    _topBar(),
                    const Spacer(),
                    if (!widget.theme.isArcadePlanet)
                      _selectedIdentity(selected)
                    else
                      SizedBox(height: 110.r),
                    SizedBox(height: 14.r),
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
      child: path == null
          ? _gradientBackground()
          : Image.file(
              File(path),
              key: ValueKey(path),
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => _gradientBackground(),
            ),
    );
  }

  Widget _gradientBackground() {
    return DecoratedBox(
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
  }

  Widget _topBar() {
    final hour = _now.hour.toString().padLeft(2, '0');
    final minute = _now.minute.toString().padLeft(2, '0');
    return Row(
      children: [
        Flexible(
          child: Text(
            widget.theme.name.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.72),
              fontFamily: 'NeoStationFullThemeBold',
              fontSize: 16.r,
              letterSpacing: 2.4,
            ),
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
    final themeLogo = selected.isGame
        ? selected.customWheelImage
        : widget.theme.rasterSystemLogo(folder);
    final rasterLogo =
        _existing(selected.customLogoPath) ?? _existing(themeLogo);

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 260),
      child: SizedBox(
        key: ValueKey(selected.folderName ?? selected.title),
        height: 150.r,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Expanded(
              child: rasterLogo == null
                  ? Center(
                      child: Text(
                        (selected.title ?? selected.shortName ?? 'NEOSTATION')
                            .toUpperCase(),
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white,
                          fontFamily: 'NeoStationFullThemeBold',
                          fontSize: 42.r,
                          letterSpacing: 1.4,
                          shadows: const [
                            Shadow(
                              color: Colors.black87,
                              blurRadius: 12,
                              offset: Offset(0, 2),
                            ),
                          ],
                        ),
                      ),
                    )
                  : Image.file(
                      File(rasterLogo),
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stackTrace) =>
                          const SizedBox.shrink(),
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
    final visible = <int>[];
    for (var offset = -3; offset <= 3; offset++) {
      final index = _selectedIndex + offset;
      if (index >= 0 && index < systems.length) visible.add(index);
    }

    return SizedBox(
      height: 108.r,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: visible.map((index) {
          final system = systems[index];
          final isSelected = index == _selectedIndex;
          final distance = (index - _selectedIndex).abs();

          return GestureDetector(
            onTap: () {
              if (_navigating || index == _selectedIndex) return;
              SfxService().playNavSound();
              _selectedIndex = index;
              widget.onCardTapped?.call(index);
              _overlayEntry?.markNeedsBuild();
            },
            onDoubleTap: isSelected ? _openSelected : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 190),
              curve: Curves.easeOutCubic,
              width: isSelected ? 176.r : 116.r,
              height: isSelected ? 100.r : 72.r,
              margin: EdgeInsets.symmetric(horizontal: 8.r),
              padding: EdgeInsets.all(isSelected ? 12.r : 9.r),
              decoration: BoxDecoration(
                color: isSelected
                    ? _accent.withValues(alpha: 0.78)
                    : Colors.black.withValues(alpha: 0.42 - distance * 0.05),
                borderRadius: BorderRadius.circular(isSelected ? 16.r : 12.r),
                border: Border.all(
                  color: isSelected ? Colors.white70 : Colors.white12,
                  width: isSelected ? 2 : 1,
                ),
                boxShadow: isSelected
                    ? [
                        BoxShadow(
                          color: _accent.withValues(alpha: 0.45),
                          blurRadius: 24.r,
                          spreadRadius: 2.r,
                        ),
                      ]
                    : null,
              ),
              child: _systemTile(system, isSelected),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _systemTile(SystemInfo system, bool isSelected) {
    final folder = system.primaryFolderName ?? system.folderName ?? 'all';
    final themeLogo = system.isGame
        ? system.customWheelImage
        : widget.theme.carouselSystemLogo(folder);
    final raster = _existing(system.customLogoPath) ?? _existing(themeLogo);

    if (raster != null) {
      return Image.file(File(raster), fit: BoxFit.contain);
    }

    return Image.asset(
      'assets/images/logos/$folder.webp',
      fit: BoxFit.contain,
      errorBuilder: (context, error, stackTrace) => Center(
        child: Text(
          system.shortName ?? system.title ?? folder.toUpperCase(),
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: isSelected ? Colors.white : Colors.white70,
            fontFamily: 'NeoStationFullThemeBold',
            fontSize: isSelected ? 17.r : 13.r,
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
          Flexible(
            child: Text(
              '${widget.theme.author} · ${widget.theme.license ?? ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Colors.white38, fontSize: 10.r),
            ),
          ),
      ],
    );
  }

  Widget _hint(String key, String label) {
    return Row(
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
}
