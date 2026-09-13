import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../models/full_theme_definition.dart';
import '../../models/game_model.dart';
import '../../models/system_model.dart';

/// NeoStation's fixed, comfortable Arcade Planet game view.
///
/// Arcade Planet exposes many EmulationStation variants. NeoStation does not
/// expose those as user-facing layout choices: this renderer intentionally
/// chooses the Detailed/Video composition (media left, list right, system logo
/// at the top) and adapts it to the current iPhone/iPad ratio.
class ArcadePlanetGamesLayout extends StatelessWidget {
  const ArcadePlanetGamesLayout({
    super.key,
    required this.theme,
    required this.system,
    required this.games,
    required this.selectedIndex,
    required this.listController,
    required this.accent,
    required this.onSelect,
    required this.onLaunch,
    required this.screenshotPath,
    required this.boxPath,
    required this.wheelPath,
    required this.description,
    required this.metadata,
    required this.footer,
  });

  final FullThemeDefinition theme;
  final SystemModel system;
  final List<GameModel> games;
  final int selectedIndex;
  final ScrollController listController;
  final Color accent;
  final ValueChanged<int> onSelect;
  final VoidCallback onLaunch;
  final String? screenshotPath;
  final String? boxPath;
  final String? wheelPath;
  final String description;
  final List<String> metadata;
  final Widget footer;

  GameModel get selected => games[selectedIndex];

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final safeHeight = constraints.maxHeight <= 0
            ? 1.0
            : constraints.maxHeight;
        final aspectRatio = constraints.maxWidth / safeHeight;
        final background = theme.arcadePlanetBackgroundForAspect(
          aspectRatio,
          'bgdetailed.jpg',
        );
        final logo = theme.rasterSystemLogo(system.folderName);

        return Stack(
          fit: StackFit.expand,
          children: [
            if (background != null)
              Image.file(
                File(background),
                fit: BoxFit.cover,
                filterQuality: FilterQuality.medium,
                errorBuilder: (context, error, stackTrace) =>
                    const SizedBox.shrink(),
              )
            else
              _fallbackBackground(),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.08),
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.36),
                  ],
                ),
              ),
            ),
            SafeArea(
              child: Padding(
                padding: EdgeInsets.fromLTRB(22.r, 16.r, 22.r, 14.r),
                child: Column(
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          Expanded(
                            flex: 10,
                            child: _mediaColumn(),
                          ),
                          SizedBox(width: 20.r),
                          Expanded(
                            flex: 10,
                            child: _listColumn(logo),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: 8.r),
                    footer,
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _fallbackBackground() {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            const Color(0xFF111017),
            accent.withValues(alpha: 0.42),
            const Color(0xFF09080C),
          ],
        ),
      ),
    );
  }

  Widget _mediaColumn() {
    return Column(
      children: [
        Expanded(
          flex: 11,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Container(
                margin: EdgeInsets.fromLTRB(12.r, 18.r, 12.r, 8.r),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.66),
                  borderRadius: BorderRadius.circular(18.r),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.22),
                    width: 2.r,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.56),
                      blurRadius: 24.r,
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(15.r),
                  child: screenshotPath == null
                      ? _placeholder(Icons.videogame_asset_rounded)
                      : Image.file(
                          File(screenshotPath!),
                          fit: BoxFit.cover,
                          filterQuality: FilterQuality.medium,
                        ),
                ),
              ),
              if (boxPath != null)
                Positioned(
                  left: 0,
                  bottom: 0,
                  width: 122.r,
                  height: 170.r,
                  child: Container(
                    padding: EdgeInsets.all(7.r),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.52),
                      borderRadius: BorderRadius.circular(12.r),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: Image.file(File(boxPath!), fit: BoxFit.contain),
                  ),
                ),
            ],
          ),
        ),
        SizedBox(height: 10.r),
        SizedBox(
          height: 58.r,
          child: wheelPath == null
              ? Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    selected.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white,
                      fontFamily: 'NeoStationFullThemeBold',
                      fontSize: 26.r,
                      shadows: const [
                        Shadow(color: Colors.black87, blurRadius: 8),
                      ],
                    ),
                  ),
                )
              : Image.file(File(wheelPath!), fit: BoxFit.contain),
        ),
        SizedBox(height: 8.r),
        Expanded(
          flex: 5,
          child: Container(
            width: double.infinity,
            padding: EdgeInsets.fromLTRB(14.r, 10.r, 14.r, 8.r),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.34),
              borderRadius: BorderRadius.circular(10.r),
            ),
            child: Text(
              description,
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: const Color(0xFFE0E0E0),
                fontFamily: 'NeoStationFullTheme',
                height: 1.25,
                fontSize: 13.r,
                shadows: const [Shadow(color: Colors.black, blurRadius: 4)],
              ),
            ),
          ),
        ),
        SizedBox(height: 8.r),
        _metadataRow(),
      ],
    );
  }

  Widget _listColumn(String? logo) {
    return Column(
      children: [
        SizedBox(
          height: 76.r,
          child: logo == null
              ? Center(
                  child: Text(
                    system.realName.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white,
                      fontFamily: 'NeoStationFullThemeBold',
                      fontSize: 28.r,
                      letterSpacing: 1.2,
                    ),
                  ),
                )
              : Image.file(File(logo), fit: BoxFit.contain),
        ),
        SizedBox(height: 8.r),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.22),
              borderRadius: BorderRadius.circular(11.r),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(11.r),
              child: ListView.builder(
                controller: listController,
                padding: EdgeInsets.symmetric(vertical: 8.r),
                itemExtent: 45.r,
                itemCount: games.length,
                itemBuilder: (context, index) {
                  final game = games[index];
                  final isSelected = index == selectedIndex;
                  return InkWell(
                    onTap: () => onSelect(index),
                    onDoubleTap: isSelected ? onLaunch : null,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      margin: EdgeInsets.symmetric(
                        horizontal: 7.r,
                        vertical: 2.r,
                      ),
                      padding: EdgeInsets.symmetric(horizontal: 12.r),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? accent.withValues(alpha: 0.84)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(5.r),
                        boxShadow: isSelected
                            ? [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.42),
                                  blurRadius: 7.r,
                                ),
                              ]
                            : null,
                      ),
                      child: Row(
                        children: [
                          if (game.isFavorite == true)
                            Padding(
                              padding: EdgeInsets.only(right: 7.r),
                              child: Icon(
                                Icons.star_rounded,
                                color: Colors.amberAccent,
                                size: 15.r,
                              ),
                            ),
                          Expanded(
                            child: Text(
                              game.name.toUpperCase(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: isSelected
                                    ? Colors.white
                                    : const Color(0xFFAAA2AA),
                                fontFamily: isSelected
                                    ? 'NeoStationFullThemeBold'
                                    : 'NeoStationFullTheme',
                                fontSize: 14.r,
                                shadows: const [
                                  Shadow(color: Colors.black, blurRadius: 3),
                                ],
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
          ),
        ),
        SizedBox(height: 7.r),
        Text(
          '${selectedIndex + 1} / ${games.length}',
          style: TextStyle(
            color: Colors.white60,
            fontFamily: 'NeoStationFullTheme',
            fontSize: 12.r,
          ),
        ),
      ],
    );
  }

  Widget _metadataRow() {
    return SizedBox(
      width: double.infinity,
      child: Wrap(
        spacing: 8.r,
        runSpacing: 5.r,
        children: metadata
            .map(
              (value) => Container(
                padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 4.r),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.34),
                  borderRadius: BorderRadius.circular(14.r),
                  border: Border.all(color: Colors.white10),
                ),
                child: Text(
                  value,
                  style: TextStyle(
                    color: const Color(0xFFC8C8C8),
                    fontFamily: 'NeoStationFullTheme',
                    fontSize: 10.r,
                  ),
                ),
              ),
            )
            .toList(),
      ),
    );
  }

  Widget _placeholder(IconData icon) {
    return ColoredBox(
      color: const Color(0xFF111117),
      child: Center(
        child: Icon(icon, color: Colors.white24, size: 54.r),
      ),
    );
  }
}
