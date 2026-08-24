import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/services/gamepad/gamepad_navigation_manager.dart';
import 'package:neostation/themes/chrome_surface.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/widgets/neo_glass.dart';
import 'package:pdfrx/pdfrx.dart';

/// Full-screen PDF reader for Library downloads.
class LibraryPdfReaderScreen extends StatefulWidget {
  const LibraryPdfReaderScreen({
    super.key,
    required this.filePath,
    required this.title,
  });

  final String filePath;
  final String title;

  @override
  State<LibraryPdfReaderScreen> createState() => _LibraryPdfReaderScreenState();
}

class _LibraryPdfReaderScreenState extends State<LibraryPdfReaderScreen> {
  late final GamepadNavigation _gamepadNav;
  late final String _layerId;

  @override
  void initState() {
    super.initState();
    _layerId = 'library_pdf_reader_${identityHashCode(this)}';
    _gamepadNav = GamepadNavigation(onBack: _close);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _gamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        _layerId,
        modal: true,
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
      );
    });
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer(_layerId);
    _gamepadNav.dispose();
    super.dispose();
  }

  void _close() {
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(child: PdfViewer.file(widget.filePath)),
            Positioned(
              left: 12.r,
              right: 12.r,
              top: 8.r,
              child: NeoGlass(
                role: GlassSurfaceRole.chrome,
                borderRadius: BorderRadius.circular(12.r),
                padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 7.r),
                child: Row(
                  children: [
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: _close,
                        borderRadius: BorderRadius.circular(8.r),
                        child: Padding(
                          padding: EdgeInsets.all(4.r),
                          child: Icon(
                            Symbols.arrow_back_rounded,
                            size: 18.r,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                    ),
                    SizedBox(width: 8.r),
                    Icon(
                      Symbols.picture_as_pdf_rounded,
                      size: 18.r,
                      color: theme.colorScheme.primary,
                    ),
                    SizedBox(width: 7.r),
                    Expanded(
                      child: Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Text(
                      'PDF',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
