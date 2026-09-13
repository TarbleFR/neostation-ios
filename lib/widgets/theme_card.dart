import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/l10n/full_theme_locale.dart';
import 'package:neostation/services/full_theme_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/themes/app_themes.dart';

class ThemeCard extends StatefulWidget {
  const ThemeCard({
    super.key,
    required this.themeName,
    required this.displayName,
    this.onTap,
    this.onLongPress,
    this.onDelete,
    this.isSelected = false,
    this.isFocused = false,
  });

  final String themeName;
  final String displayName;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onDelete;
  final bool isSelected;
  final bool isFocused;

  @override
  State<ThemeCard> createState() => _ThemeCardState();
}

class _ThemeCardState extends State<ThemeCard> {
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(skipTraversal: true);
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preview = widget.themeName == 'system'
        ? AppThemes.getThemeDataByName(
            WidgetsBinding.instance.platformDispatcher.platformBrightness ==
                    Brightness.dark
                ? 'dark'
                : 'light',
          )
        : AppThemes.getThemeDataByName(widget.themeName);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AspectRatio(
          aspectRatio: 4 / 3,
          child: Container(
            margin: EdgeInsets.symmetric(vertical: 4.h),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8.r),
              border: Border.all(
                color: widget.isFocused
                    ? theme.colorScheme.primary
                    : Colors.transparent,
                width: 2.r,
              ),
              boxShadow: widget.isFocused
                  ? [
                      BoxShadow(
                        color: theme.colorScheme.primary.withValues(alpha: 0.3),
                        blurRadius: 8.r,
                        spreadRadius: 1.r,
                      ),
                    ]
                  : null,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6.r),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _AppMockupPainter(
                        surface: preview.colorScheme.surface,
                        primary: preview.colorScheme.primary,
                        secondary: preview.colorScheme.secondary,
                      ),
                    ),
                  ),
                  if (widget.isSelected)
                    Center(
                      child: Container(
                        width: 36.r,
                        height: 36.r,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.greenAccent,
                        ),
                        child: Icon(
                          Symbols.check_rounded,
                          color: Colors.black,
                          size: 24.r,
                        ),
                      ),
                    ),
                  Positioned.fill(
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        canRequestFocus: false,
                        focusNode: _focusNode,
                        focusColor: Colors.transparent,
                        hoverColor: Colors.transparent,
                        highlightColor: Colors.transparent,
                        splashColor: Colors.transparent,
                        onTap: () {
                          SfxService().playEnterSound();
                          widget.onTap?.call();
                        },
                        onLongPress: widget.onLongPress,
                      ),
                    ),
                  ),
                  if (widget.onDelete != null)
                    Positioned(
                      top: 4.r,
                      right: 4.r,
                      child: Material(
                        color: Colors.black.withValues(alpha: 0.55),
                        shape: const CircleBorder(),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          canRequestFocus: false,
                          onTap: () {
                            SfxService().playEnterSound();
                            widget.onDelete!.call();
                          },
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
          widget.displayName,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: widget.isFocused || widget.isSelected
                ? theme.colorScheme.onSurface
                : theme.colorScheme.onSurface.withValues(alpha: 0.7),
            fontWeight: widget.isSelected ? FontWeight.bold : FontWeight.normal,
            fontSize: 12.r,
          ),
        ),
      ],
    );
  }
}

class _AppMockupPainter extends CustomPainter {
  const _AppMockupPainter({
    required this.surface,
    required this.primary,
    required this.secondary,
  });

  final Color surface;
  final Color primary;
  final Color secondary;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = surface;
    canvas.drawRect(Offset.zero & size, paint);

    final topH = size.height * 0.15;
    paint.color = primary.withValues(alpha: 0.08);
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, topH), paint);

    final bottomH = size.height * 0.22;
    paint.color = secondary.withValues(alpha: 0.12);
    canvas.drawRect(
      Rect.fromLTWH(0, size.height - bottomH, size.width, bottomH),
      paint,
    );

    final cardH = size.height * 0.55;
    final centerW = size.width * 0.44;
    final centerX = (size.width - centerW) / 2;
    final centerY = topH + (size.height - topH - bottomH - cardH) / 2;
    paint.color = primary.withValues(alpha: 0.72);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(centerX, centerY, centerW, cardH),
        Radius.circular(size.width * 0.014),
      ),
      paint,
    );

    paint.color = secondary.withValues(alpha: 0.34);
    final sideW = size.width * 0.18;
    final sideH = cardH * 0.78;
    final sideY = centerY + (cardH - sideH) / 2;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(size.width * 0.04, sideY, sideW, sideH),
        Radius.circular(size.width * 0.012),
      ),
      paint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(size.width * 0.78, sideY, sideW, sideH),
        Radius.circular(size.width * 0.012),
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(_AppMockupPainter oldDelegate) =>
      oldDelegate.surface != surface ||
      oldDelegate.primary != primary ||
      oldDelegate.secondary != secondary;
}

/// Existing custom-theme tile, expanded to expose two distinct imports:
/// NeoStation color themes (`.json`) and full EmulationStation themes (`.zip`).
/// A full theme is installed as the single active full experience rather than
/// being added to the list/grid/carousel view-mode choices.
class ImportThemeCard extends StatelessWidget {
  const ImportThemeCard({
    super.key,
    required this.label,
    this.onTap,
    this.isFocused = false,
  });

  final String label;
  final VoidCallback? onTap;
  final bool isFocused;

  Future<void> _showImportChoice(BuildContext context) async {
    SfxService().playEnterSound();
    await FullThemeService.instance.initialize();
    if (!context.mounted) return;

    final active = FullThemeService.instance.activeTheme.value;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(FullThemeLocale.title(dialogContext)),
        content: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 480.r),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                FullThemeLocale.description(dialogContext),
                style: Theme.of(dialogContext).textTheme.bodyMedium,
              ),
              SizedBox(height: 16.r),
              ListTile(
                leading: const Icon(Symbols.palette_rounded),
                title: Text(FullThemeLocale.colorTheme(dialogContext)),
                subtitle: const Text('NeoStation / daisyUI JSON'),
                onTap: () {
                  Navigator.of(dialogContext).pop();
                  onTap?.call();
                },
              ),
              ListTile(
                leading: const Icon(Symbols.dashboard_customize_rounded),
                title: Text(
                  active == null
                      ? FullThemeLocale.import(dialogContext)
                      : FullThemeLocale.replace(dialogContext),
                ),
                subtitle: Text(
                  active?.name ?? 'EmulationStation theme package',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () {
                  Navigator.of(dialogContext).pop();
                  _pickFullTheme(context);
                },
              ),
              if (active != null)
                ListTile(
                  leading: const Icon(Symbols.delete_rounded),
                  title: Text(FullThemeLocale.remove(dialogContext)),
                  subtitle: Text(active.name),
                  onTap: () async {
                    Navigator.of(dialogContext).pop();
                    await FullThemeService.instance.removeActiveTheme();
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(FullThemeLocale.remove(context))),
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickFullTheme(BuildContext context) async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['zip'],
        allowMultiple: false,
      );
      final path = result?.files.single.path;
      if (path == null || path.isEmpty || !context.mounted) return;

      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const PopScope(
          canPop: false,
          child: Center(child: CircularProgressIndicator()),
        ),
      );

      try {
        final imported = await FullThemeService.instance.importZip(File(path));
        if (!context.mounted) return;
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(FullThemeLocale.success(context, imported.name))),
        );
      } catch (_) {
        if (!context.mounted) return;
        Navigator.of(context, rootNavigator: true).pop();
        rethrow;
      }
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(FullThemeLocale.error(context))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;

    return ValueListenableBuilder(
      valueListenable: FullThemeService.instance.activeTheme,
      builder: (context, activeTheme, _) {
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
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      canRequestFocus: false,
                      onTap: () => _showImportChoice(context),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Center(
                            child: Icon(
                              activeTheme == null
                                  ? Symbols.add_rounded
                                  : Symbols.dashboard_customize_rounded,
                              color: isFocused
                                  ? accent
                                  : theme.colorScheme.onSurface.withValues(alpha: 0.6),
                              size: 32.r,
                            ),
                          ),
                          if (activeTheme != null)
                            Positioned(
                              left: 8.r,
                              right: 8.r,
                              bottom: 7.r,
                              child: Container(
                                padding: EdgeInsets.symmetric(
                                  horizontal: 7.r,
                                  vertical: 4.r,
                                ),
                                decoration: BoxDecoration(
                                  color: accent.withValues(alpha: 0.85),
                                  borderRadius: BorderRadius.circular(6.r),
                                ),
                                child: Text(
                                  activeTheme.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: theme.colorScheme.onPrimary,
                                    fontSize: 8.r,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(height: 4.r),
            Text(
              activeTheme == null ? label : FullThemeLocale.title(context),
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
          ],
        );
      },
    );
  }
}
