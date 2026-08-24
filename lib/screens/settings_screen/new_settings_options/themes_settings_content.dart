import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/l10n/custom_background_locale.dart';
import 'package:neostation/l10n/home_music_locale.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/services/home_music_service.dart';
import 'package:provider/provider.dart';
import 'package:neostation/providers/theme_provider.dart';
import 'package:neostation/services/permission_service.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/widgets/theme_card.dart';
import 'package:neostation/widgets/custom_notification.dart';
import 'package:neostation/widgets/confirm_action_dialog.dart';
import 'package:neostation/widgets/tv_directory_picker.dart';
import 'package:neostation/widgets/shaders/shader_gif_widget.dart';
import 'package:neostation/utils/image_utils.dart';
import 'package:neostation/responsive.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import 'settings_title.dart';

/// A specialized content panel for selecting application color themes and a
/// global custom background independent from the color palette.
class ThemesSettingsContent extends StatefulWidget {
  final bool isContentFocused;
  final int selectedContentIndex;
  final ValueChanged<int>? onSelectionChanged;

  const ThemesSettingsContent({
    super.key,
    required this.isContentFocused,
    required this.selectedContentIndex,
    this.onSelectionChanged,
  });

  @override
  State<ThemesSettingsContent> createState() => ThemesSettingsContentState();
}

class ThemesSettingsContentState extends State<ThemesSettingsContent> {
  final _log = LoggerService.instance;
  final ScrollController _scrollController = ScrollController();

  /// Keys used for calculating viewport alignment during grid-based navigation.
  final List<GlobalKey> _itemKeys = [];

  @override
  void initState() {
    super.initState();
    _initializeKeys();
    final homeMusic = HomeMusicService();
    homeMusic.addListener(_onHomeMusicChanged);
    // Theme is never the Systems main menu. Set the visibility state before
    // initialization so entering this panel cannot restart menu music.
    homeMusic.setMainMenuActive(false).then((_) {
      if (mounted) setState(() {});
    });
  }

  void _onHomeMusicChanged() {
    if (mounted) setState(() {});
  }

  /// Native System Theme + Registered Theme Variants + Custom Background + Import.
  void _initializeKeys() {
    _itemKeys.clear();
    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);
    final count = themeProvider.getThemeList().length + 4;
    for (int i = 0; i < count; i++) {
      _itemKeys.add(GlobalKey());
    }
  }

  @override
  void dispose() {
    HomeMusicService().removeListener(_onHomeMusicChanged);
    _scrollController.dispose();
    super.dispose();
  }

  int getItemCount(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);
    return themeProvider.getThemeList().length + 4;
  }

  int get _gridColumns => Responsive.getThemesCrossAxisCount(context);

  void navigateUp() {
    final newIndex = GridNavUtils.navigateUp(
      currentIndex: widget.selectedContentIndex,
      crossAxisCount: _gridColumns,
      maxItems: getItemCount(context),
    );
    widget.onSelectionChanged?.call(newIndex);
    _ensureSelectedItemVisible(newIndex);
  }

  void navigateDown() {
    final newIndex = GridNavUtils.navigateDown(
      currentIndex: widget.selectedContentIndex,
      crossAxisCount: _gridColumns,
      maxItems: getItemCount(context),
    );
    widget.onSelectionChanged?.call(newIndex);
    _ensureSelectedItemVisible(newIndex);
  }

  bool navigateLeft() {
    final currentCol = widget.selectedContentIndex % _gridColumns;
    if (currentCol == 0) return true;

    final newIndex = GridNavUtils.navigateLeft(
      currentIndex: widget.selectedContentIndex,
      crossAxisCount: _gridColumns,
      maxItems: getItemCount(context),
    );
    widget.onSelectionChanged?.call(newIndex);
    _ensureSelectedItemVisible(newIndex);
    return false;
  }

  void navigateRight() {
    final newIndex = GridNavUtils.navigateRight(
      currentIndex: widget.selectedContentIndex,
      crossAxisCount: _gridColumns,
      maxItems: getItemCount(context),
    );
    widget.onSelectionChanged?.call(newIndex);
    _ensureSelectedItemVisible(newIndex);
  }

  void _ensureSelectedItemVisible(int index) {
    if (index >= 0 && index < _itemKeys.length) {
      final context = _itemKeys[index].currentContext;
      if (context != null) {
        Scrollable.ensureVisible(
          context,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          alignment: 0.5,
        );
      }
    }
  }

  void selectItem(int index) async {
    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);
    final themes = themeProvider.getThemeList();
    final customBackgroundIndex = themes.length + 1;
    final menuMusicIndex = themes.length + 2;

    if (index == 0) {
      await themeProvider.setTheme('system');
    } else if (index - 1 < themes.length) {
      await themeProvider.setTheme(themes[index - 1]['name']!);
    } else if (index == customBackgroundIndex) {
      await _pickCustomBackground();
      return;
    } else if (index == menuMusicIndex) {
      await _toggleHomeMusic();
      return;
    } else {
      await _importTheme();
      return;
    }
    if (mounted) setState(() {});
    widget.onSelectionChanged?.call(index);
  }

  Future<void> _toggleHomeMusic() async {
    final music = HomeMusicService();
    if (music.hasMusic) {
      await music.setEnabled(!music.enabled);
    } else {
      await music.chooseMusic();
    }
    if (mounted) setState(() {});
  }

  Future<void> _pickHomeMusic() async {
    await HomeMusicService().chooseMusic();
    if (mounted) setState(() {});
  }

  Future<void> _clearHomeMusic() async {
    await HomeMusicService().clearMusic();
    if (mounted) setState(() {});
  }

  Future<void> _pickCustomBackground() async {
    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);
    try {
      String? filePath;

      if (Platform.isAndroid && await PermissionService.isTelevision()) {
        if (mounted) {
          filePath = await TvDirectoryPicker.showFilePicker(
            context,
            extensions: ImageUtils.backgroundExtensions,
          );
        }
      } else {
        final result = await FilePicker.pickFiles(
          type: FileType.custom,
          allowedExtensions: ImageUtils.backgroundExtensions,
          dialogTitle: CustomBackgroundLocale.title(context),
        );
        filePath = result?.files.single.path;
      }

      if (filePath == null) return;
      await themeProvider.setCustomBackground(File(filePath));
      if (!mounted) return;
      setState(() {});
      AppNotification.showNotification(
        context,
        CustomBackgroundLocale.updated(context),
        type: NotificationType.success,
      );
    } catch (e) {
      _log.e('Custom background selection failed: $e');
      if (mounted) {
        AppNotification.showNotification(
          context,
          '$e',
          type: NotificationType.error,
        );
      }
    }
  }

  Future<void> _clearCustomBackground() async {
    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);
    await themeProvider.clearCustomBackground();
    if (!mounted) return;
    setState(() {});
    AppNotification.showNotification(
      context,
      CustomBackgroundLocale.removed(context),
      type: NotificationType.info,
    );
  }

  /// Opens a file picker, imports the selected daisyUI theme JSON, and applies it.
  Future<void> _importTheme() async {
    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);
    final pickerTitle = AppLocale.importTheme.getString(context);
    try {
      String? filePath;

      if (Platform.isAndroid && await PermissionService.isTelevision()) {
        if (mounted) {
          filePath = await TvDirectoryPicker.showFilePicker(
            context,
            extensions: ['json'],
          );
        }
      } else {
        final result = await FilePicker.pickFiles(
          type: FileType.custom,
          allowedExtensions: ['json'],
          dialogTitle: pickerTitle,
        );
        filePath = result?.files.single.path;
      }

      if (filePath == null) return;

      final result = await themeProvider.importTheme(File(filePath));
      if (mounted) setState(() {});
      if (mounted) {
        final name = result.theme.name;
        AppNotification.showNotification(
          context,
          (result.created
                  ? AppLocale.importThemeSuccess
                  : AppLocale.importThemeExists)
              .getString(context)
              .replaceAll('%s', name),
          type: result.created
              ? NotificationType.success
              : NotificationType.info,
        );
      }
    } on FormatException catch (e) {
      _log.e('Theme import failed (malformed): $e');
      if (mounted) {
        AppNotification.showNotification(
          context,
          AppLocale.importThemeError.getString(context),
          type: NotificationType.error,
        );
      }
    } catch (e) {
      _log.e('Theme import failed: $e');
      if (mounted) {
        AppNotification.showNotification(
          context,
          AppLocale.importThemeError.getString(context),
          type: NotificationType.error,
        );
      }
    }
  }

  /// Gamepad entry point: deletes the custom background or an imported theme.
  void deleteFocusedTheme(int index) {
    if (index <= 0) return;
    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);
    final themes = themeProvider.getThemeList();
    final customBackgroundIndex = themes.length + 1;
    final menuMusicIndex = themes.length + 2;

    if (index == customBackgroundIndex) {
      if (themeProvider.hasCustomBackground) _clearCustomBackground();
      return;
    }
    if (index == menuMusicIndex) {
      if (HomeMusicService().hasMusic) _clearHomeMusic();
      return;
    }

    final themeIndex = index - 1;
    if (themeIndex >= themes.length) return;
    final t = themes[themeIndex];
    if (!themeProvider.isCustomTheme(t['name']!)) return;
    _deleteTheme(t['name']!, t['displayName']!);
  }

  Future<void> _deleteTheme(String themeName, String displayName) async {
    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);
    final confirmed = await ConfirmActionDialog.show(
      context,
      title: AppLocale.deleteThemeTitle.getString(context),
      body: AppLocale.deleteThemeConfirm
          .getString(context)
          .replaceAll('%s', displayName),
      confirmLabel: AppLocale.delete.getString(context),
      icon: Symbols.delete_rounded,
    );
    if (!confirmed) return;

    await themeProvider.deleteTheme(themeName);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);

    final List<Map<String, String>> allThemes = [
      {
        'name': 'system',
        'displayName': AppLocale.systemTheme.getString(context),
      },
      ...themeProvider.getThemeList(),
    ];

    final customBackgroundIndex = allThemes.length;
    final menuMusicIndex = allThemes.length + 1;
    final importIndex = allThemes.length + 2;
    final itemCount = allThemes.length + 3;

    if (_itemKeys.length != itemCount) {
      _initializeKeys();
    }

    return SingleChildScrollView(
      controller: _scrollController,
      physics: const ClampingScrollPhysics(),
      padding: EdgeInsets.only(bottom: 24.r),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SettingsTitle(
            title: AppLocale.themes.getString(context),
            subtitle: AppLocale.themesSubtitle.getString(context),
          ),
          SizedBox(height: 12.r),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: itemCount,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: _gridColumns,
              crossAxisSpacing: 8.r,
              mainAxisSpacing: 8.r,
              childAspectRatio: 1.05,
            ),
            itemBuilder: (context, index) {
              final isFocused =
                  widget.isContentFocused &&
                  widget.selectedContentIndex == index;

              if (index == customBackgroundIndex) {
                return Container(
                  key: _itemKeys[index],
                  child: _CustomBackgroundCard(
                    path: themeProvider.customBackgroundPath,
                    label: CustomBackgroundLocale.title(context),
                    subtitle: themeProvider.hasCustomBackground
                        ? CustomBackgroundLocale.active(context)
                        : CustomBackgroundLocale.subtitle(context),
                    isFocused: isFocused,
                    onTap: () {
                      SfxService().playNavSound();
                      widget.onSelectionChanged?.call(index);
                      _pickCustomBackground();
                    },
                    onDelete: themeProvider.hasCustomBackground
                        ? _clearCustomBackground
                        : null,
                  ),
                );
              }

              if (index == menuMusicIndex) {
                final music = HomeMusicService();
                final fileName = music.selectedFileName;
                final musicSubtitle = music.hasMusic
                    ? '${music.enabled ? HomeMusicLocale.active(context) : HomeMusicLocale.disabled(context)} · ${fileName ?? ''}'
                    : HomeMusicLocale.subtitle(context);

                return Container(
                  key: _itemKeys[index],
                  child: _HomeMusicCard(
                    label: HomeMusicLocale.title(context),
                    subtitle: musicSubtitle,
                    hasMusic: music.hasMusic,
                    enabled: music.enabled,
                    isFocused: isFocused,
                    onTap: () {
                      SfxService().playNavSound();
                      widget.onSelectionChanged?.call(index);
                      _toggleHomeMusic();
                    },
                    onReplace: music.hasMusic
                        ? () {
                            SfxService().playNavSound();
                            _pickHomeMusic();
                          }
                        : null,
                    onDelete: music.hasMusic ? _clearHomeMusic : null,
                    replaceTooltip: HomeMusicLocale.replace(context),
                  ),
                );
              }

              if (index == importIndex) {
                return Container(
                  key: _itemKeys[index],
                  child: ImportThemeCard(
                    label: AppLocale.importTheme.getString(context),
                    isFocused: isFocused,
                    onTap: () {
                      SfxService().playNavSound();
                      widget.onSelectionChanged?.call(index);
                      selectItem(index);
                    },
                  ),
                );
              }

              final t = allThemes[index];
              final isSelected =
                  themeProvider.currentThemeName == t['name'] ||
                  (index == 0 && themeProvider.currentThemeName == 'system');
              final isCustom = themeProvider.isCustomTheme(t['name']!);

              return Container(
                key: _itemKeys[index],
                child: ThemeCard(
                  themeName: t['name']!,
                  displayName: t['displayName']!,
                  isSelected: isSelected,
                  isFocused: isFocused,
                  onTap: () {
                    SfxService().playNavSound();
                    widget.onSelectionChanged?.call(index);
                    selectItem(index);
                  },
                  onLongPress: isCustom
                      ? () => _deleteTheme(t['name']!, t['displayName']!)
                      : null,
                  onDelete: isCustom
                      ? () => _deleteTheme(t['name']!, t['displayName']!)
                      : null,
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _CustomBackgroundCard extends StatelessWidget {
  const _CustomBackgroundCard({
    required this.path,
    required this.label,
    required this.subtitle,
    required this.isFocused,
    required this.onTap,
    this.onDelete,
  });

  final String? path;
  final String label;
  final String subtitle;
  final bool isFocused;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final backgroundPath = path;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AspectRatio(
          aspectRatio: 4 / 3,
          child: Container(
            margin: EdgeInsets.symmetric(vertical: 4.h),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(8.r),
              border: Border.all(
                color: isFocused
                    ? accent
                    : theme.colorScheme.onSurface.withValues(alpha: 0.25),
                width: 2.r,
              ),
              boxShadow: isFocused
                  ? [
                      BoxShadow(
                        color: accent.withValues(alpha: 0.3),
                        blurRadius: 8.r,
                        spreadRadius: 1.r,
                      ),
                    ]
                  : null,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6.r),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (backgroundPath == null)
                    Center(
                      child: Icon(
                        Symbols.wallpaper_rounded,
                        color: isFocused
                            ? accent
                            : theme.colorScheme.onSurface.withValues(
                                alpha: 0.55,
                              ),
                        size: 34.r,
                      ),
                    )
                  else if (ImageUtils.isAnimatedBackground(backgroundPath))
                    ShaderGifWidget(
                      imagePath: backgroundPath,
                      key: ValueKey(
                        'custom_background_preview_$backgroundPath',
                      ),
                      fit: BoxFit.cover,
                    )
                  else
                    Image.file(
                      File(backgroundPath),
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Center(
                        child: Icon(
                          Symbols.broken_image_rounded,
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.4,
                          ),
                          size: 30.r,
                        ),
                      ),
                    ),
                  Positioned.fill(
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(canRequestFocus: false, onTap: onTap),
                    ),
                  ),
                  if (onDelete != null)
                    Positioned(
                      top: 4.r,
                      right: 4.r,
                      child: Material(
                        color: Colors.black.withValues(alpha: 0.55),
                        shape: const CircleBorder(),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          canRequestFocus: false,
                          onTap: onDelete,
                          child: Padding(
                            padding: EdgeInsets.all(3.r),
                            child: Icon(
                              Symbols.close_rounded,
                              color: Colors.white,
                              size: 16.r,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        SizedBox(height: 4.r),
        Text(
          label,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: isFocused
                ? theme.colorScheme.onSurface
                : theme.colorScheme.onSurface.withValues(alpha: 0.7),
            fontWeight: isFocused ? FontWeight.bold : FontWeight.normal,
            fontSize: 12.r,
          ),
        ),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.45),
            fontSize: 8.r,
          ),
        ),
      ],
    );
  }
}

class _HomeMusicCard extends StatelessWidget {
  const _HomeMusicCard({
    required this.label,
    required this.subtitle,
    required this.hasMusic,
    required this.enabled,
    required this.isFocused,
    required this.onTap,
    required this.replaceTooltip,
    this.onReplace,
    this.onDelete,
  });

  final String label;
  final String subtitle;
  final bool hasMusic;
  final bool enabled;
  final bool isFocused;
  final VoidCallback onTap;
  final VoidCallback? onReplace;
  final VoidCallback? onDelete;
  final String replaceTooltip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AspectRatio(
          aspectRatio: 4 / 3,
          child: Container(
            margin: EdgeInsets.symmetric(vertical: 4.h),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(8.r),
              border: Border.all(
                color: isFocused
                    ? accent
                    : theme.colorScheme.onSurface.withValues(alpha: 0.25),
                width: 2.r,
              ),
              boxShadow: isFocused
                  ? [
                      BoxShadow(
                        color: accent.withValues(alpha: 0.3),
                        blurRadius: 8.r,
                        spreadRadius: 1.r,
                      ),
                    ]
                  : null,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6.r),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          hasMusic
                              ? (enabled
                                    ? Icons.volume_up_rounded
                                    : Icons.volume_off_rounded)
                              : Icons.music_note_rounded,
                          color: isFocused
                              ? accent
                              : theme.colorScheme.onSurface.withValues(
                                  alpha: 0.55,
                                ),
                          size: 40.r,
                        ),
                        if (hasMusic) ...[
                          SizedBox(height: 6.r),
                          Icon(
                            enabled
                                ? Icons.play_arrow_rounded
                                : Icons.pause_rounded,
                            color: enabled
                                ? accent
                                : theme.colorScheme.onSurface.withValues(
                                    alpha: 0.45,
                                  ),
                            size: 18.r,
                          ),
                        ],
                      ],
                    ),
                  ),
                  Positioned.fill(
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(canRequestFocus: false, onTap: onTap),
                    ),
                  ),
                  if (onDelete != null)
                    Positioned(
                      top: 4.r,
                      right: 4.r,
                      child: Material(
                        color: Colors.black.withValues(alpha: 0.55),
                        shape: const CircleBorder(),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          canRequestFocus: false,
                          onTap: onDelete,
                          child: Padding(
                            padding: EdgeInsets.all(3.r),
                            child: Icon(
                              Icons.close_rounded,
                              color: Colors.white,
                              size: 16.r,
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (onReplace != null)
                    Positioned(
                      bottom: 4.r,
                      right: 4.r,
                      child: Tooltip(
                        message: replaceTooltip,
                        child: Material(
                          color: Colors.black.withValues(alpha: 0.55),
                          shape: const CircleBorder(),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            canRequestFocus: false,
                            onTap: onReplace,
                            child: Padding(
                              padding: EdgeInsets.all(4.r),
                              child: Icon(
                                Icons.folder_open_rounded,
                                color: Colors.white,
                                size: 17.r,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        SizedBox(height: 4.r),
        Text(
          label,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: isFocused
                ? theme.colorScheme.onSurface
                : theme.colorScheme.onSurface.withValues(alpha: 0.7),
            fontWeight: isFocused ? FontWeight.bold : FontWeight.normal,
            fontSize: 12.r,
          ),
        ),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.45),
            fontSize: 8.r,
          ),
        ),
      ],
    );
  }
}
