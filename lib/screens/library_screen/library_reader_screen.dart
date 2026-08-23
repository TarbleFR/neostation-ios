import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_locale.dart';
import '../../services/gamepad/gamepad_navigation_manager.dart';
import '../../themes/chrome_surface.dart';
import '../../utils/gamepad_nav.dart';
import '../../widgets/neo_glass.dart';

/// Full-screen Library reader using the same navigation contract as the game
/// manual reader: it owns a modal gamepad layer, so B always closes it.
///
/// Reading position, zoom and pan can be stored as a local bookmark. Page-based
/// books are fitted to the available landscape viewport at 100% and may be
/// pinched down below 100% when the reader wants to see more of the page.
class LibraryReaderScreen extends StatefulWidget {
  const LibraryReaderScreen({
    super.key,
    required this.title,
    this.subtitle = '',
    this.coverUrl,
    this.text,
    this.pages = const [],
    this.imageHeaders,
    this.bookmarkId,
  });

  final String title;
  final String subtitle;
  final String? coverUrl;
  final String? text;
  final List<String> pages;
  final Map<String, String>? imageHeaders;

  /// Stable identity used to persist a bookmark.
  /// When omitted, the reader derives one from the visible title/subtitle and content type.
  final String? bookmarkId;

  bool get hasPages => pages.isNotEmpty;

  @override
  State<LibraryReaderScreen> createState() => _LibraryReaderScreenState();
}

class _LibraryReaderScreenState extends State<LibraryReaderScreen> {
  late final GamepadNavigation _gamepadNav;
  final TransformationController _transformationController =
      TransformationController();
  final ScrollController _scrollController = ScrollController();
  late final String _layerId;

  bool _hasBookmark = false;
  double? _pendingBookmarkProgress;
  int _pageIndex = 0;
  bool _pageByPage = true;
  bool _currentPageIsLong = false;

  String get _bookmarkKey {
    final identity = widget.bookmarkId?.trim().isNotEmpty == true
        ? widget.bookmarkId!.trim()
        : '${widget.hasPages ? 'pages' : 'text'}|${widget.title}|${widget.subtitle}';
    final digest = sha1.convert(utf8.encode(identity));
    return 'library_reader_bookmark_$digest';
  }

  bool get _isFrench =>
      mounted && Localizations.localeOf(context).languageCode == 'fr';

  @override
  void initState() {
    super.initState();
    _layerId = 'library_reader_${identityHashCode(this)}';
    _gamepadNav = GamepadNavigation(
      onBack: _close,
      onFavorite: () => _saveBookmark(),
      onNavigateLeft: () {
        if (widget.hasPages && _pageByPage) _previousPage();
      },
      onNavigateRight: () {
        if (widget.hasPages && _pageByPage) _nextPage();
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _gamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        _layerId,
        modal: true,
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
      );
      _restoreBookmark();
    });
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer(_layerId);
    _gamepadNav.dispose();
    _transformationController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _close() {
    if (mounted) Navigator.of(context).pop();
  }

  void _fitToScreen() {
    _transformationController.value = Matrix4.identity();
  }

  double get _currentScale =>
      _transformationController.value.getMaxScaleOnAxis();

  void _setPageIndex(int value) {
    if (!widget.hasPages) return;
    final next = value.clamp(0, widget.pages.length - 1).toInt();
    if (next == _pageIndex) return;
    setState(() {
      _pageIndex = next;
      _currentPageIsLong = false;
    });
    _fitToScreen();
  }

  void _previousPage() => _setPageIndex(_pageIndex - 1);

  void _nextPage() => _setPageIndex(_pageIndex + 1);

  void _handlePageTap(TapUpDetails details, double width) {
    if (!_pageByPage ||
        _currentPageIsLong ||
        _currentScale > 1.05 ||
        width <= 0) {
      return;
    }
    final x = details.localPosition.dx;
    if (x <= width * 0.42) {
      _previousPage();
    } else if (x >= width * 0.58) {
      _nextPage();
    }
  }

  void _togglePageMode() {
    if (!widget.hasPages) return;
    var nextIndex = _pageIndex;
    if (!_pageByPage && _scrollController.hasClients && widget.pages.length > 1) {
      final max = _scrollController.position.maxScrollExtent;
      if (max > 0) {
        final progress = (_scrollController.offset / max).clamp(0.0, 1.0);
        nextIndex = (progress * (widget.pages.length - 1)).round();
      }
    }
    setState(() {
      _pageByPage = !_pageByPage;
      _pageIndex = nextIndex.clamp(0, widget.pages.length - 1).toInt();
      if (!_pageByPage && widget.pages.length > 1) {
        _pendingBookmarkProgress = _pageIndex / (widget.pages.length - 1);
      }
    });
    _fitToScreen();
    if (!_pageByPage) _scheduleBookmarkRestore();
  }

  Future<void> _saveBookmark() async {
    final maxScrollExtent = _scrollController.hasClients
        ? _scrollController.position.maxScrollExtent
        : 0.0;
    final progress = widget.hasPages && _pageByPage
        ? (widget.pages.length <= 1
              ? 0.0
              : _pageIndex / (widget.pages.length - 1))
        : (_scrollController.hasClients && maxScrollExtent > 0
              ? (_scrollController.offset / maxScrollExtent).clamp(0.0, 1.0)
              : 0.0);

    final payload = <String, dynamic>{
      'progress': progress,
      'pageIndex': _pageIndex,
      'pageByPage': _pageByPage,
      'matrix': _transformationController.value.storage.toList(),
      'savedAt': DateTime.now().toIso8601String(),
    };

    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_bookmarkKey, jsonEncode(payload));
    if (!mounted) return;
    setState(() => _hasBookmark = true);
    _showReaderMessage(
      _isFrench ? 'Marque-page enregistré.' : 'Bookmark saved.',
    );
  }

  Future<void> _restoreBookmark() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_bookmarkKey);
    if (!mounted || raw == null || raw.trim().isEmpty) return;

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;

      final matrixValue = decoded['matrix'];
      if (matrixValue is List && matrixValue.length == 16) {
        final matrix = matrixValue
            .map((value) => (value as num).toDouble())
            .toList(growable: false);
        _transformationController.value = Matrix4.fromList(matrix);
      }

      final progressValue = decoded['progress'];
      if (progressValue is num) {
        _pendingBookmarkProgress = progressValue.toDouble().clamp(0.0, 1.0);
      }
      final pageModeValue = decoded['pageByPage'];
      if (pageModeValue is bool && widget.hasPages) {
        _pageByPage = pageModeValue;
      }
      final pageIndexValue = decoded['pageIndex'];
      if (pageIndexValue is num && widget.hasPages) {
        _pageIndex = pageIndexValue
            .toInt()
            .clamp(0, widget.pages.length - 1)
            .toInt();
      } else if (widget.hasPages &&
          _pageByPage &&
          _pendingBookmarkProgress != null &&
          widget.pages.length > 1) {
        _pageIndex = (_pendingBookmarkProgress! * (widget.pages.length - 1))
            .round()
            .clamp(0, widget.pages.length - 1)
            .toInt();
      }

      setState(() => _hasBookmark = true);
      _scheduleBookmarkRestore();
    } catch (_) {
      // Ignore malformed legacy bookmark data rather than blocking the reader.
    }
  }

  void _scheduleBookmarkRestore() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _applyBookmarkProgress());
    Future<void>.delayed(
      const Duration(milliseconds: 320),
      _applyBookmarkProgress,
    );
    Future<void>.delayed(
      const Duration(milliseconds: 950),
      _applyBookmarkProgress,
    );
  }

  void _applyBookmarkProgress() {
    if (!mounted || _pendingBookmarkProgress == null) return;
    if (widget.hasPages && _pageByPage) {
      if (widget.pages.length > 1) {
        final index = (_pendingBookmarkProgress! * (widget.pages.length - 1))
            .round()
            .clamp(0, widget.pages.length - 1)
            .toInt();
        if (index != _pageIndex) setState(() => _pageIndex = index);
      }
      _pendingBookmarkProgress = null;
      return;
    }
    if (!_scrollController.hasClients) return;
    final maxScrollExtent = _scrollController.position.maxScrollExtent;
    if (maxScrollExtent <= 0) return;
    final target = maxScrollExtent * _pendingBookmarkProgress!;
    _scrollController.jumpTo(
      target.clamp(0.0, maxScrollExtent).toDouble(),
    );
    _pendingBookmarkProgress = null;
  }

  void _showReaderMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: widget.hasPages
                  ? _buildPageReader(theme)
                  : _buildTextReader(theme),
            ),
            Positioned(
              left: 12.r,
              right: 12.r,
              top: 8.r,
              child: _buildChrome(theme),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChrome(ThemeData theme) {
    final showZoomHint = MediaQuery.sizeOf(context).width >= 720.r;
    return NeoGlass(
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
          if (widget.coverUrl != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(5.r),
              child: SizedBox(
                width: 28.r,
                height: 38.r,
                child: Image.network(
                  widget.coverUrl!,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
            ),
            SizedBox(width: 8.r),
          ] else ...[
            Icon(
              Symbols.menu_book_rounded,
              size: 18.r,
              color: theme.colorScheme.primary,
            ),
            SizedBox(width: 7.r),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.r,
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                if (widget.subtitle.isNotEmpty)
                  Text(
                    widget.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 8.5.r,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.62),
                    ),
                  ),
              ],
            ),
          ),
          if (showZoomHint) ...[
            Text(
              AppLocale.pinchToZoom.getString(context),
              style: TextStyle(
                fontSize: 8.r,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
            SizedBox(width: 6.r),
          ],
          if (widget.hasPages) ...[
            if (_pageByPage)
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 5.r),
                child: Text(
                  '${_pageIndex + 1} / ${widget.pages.length}',
                  style: TextStyle(
                    fontSize: 9.r,
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                  ),
                ),
              ),
            IconButton(
              tooltip: _pageByPage
                  ? (_isFrench ? 'Défilement continu' : 'Continuous scroll')
                  : (_isFrench ? 'Page par page' : 'Page by page'),
              onPressed: _togglePageMode,
              icon: Icon(
                _pageByPage
                    ? Symbols.view_stream_rounded
                    : Symbols.view_carousel_rounded,
                size: 18.r,
              ),
            ),
          ],
          IconButton(
            tooltip: _isFrench
                ? (_hasBookmark
                      ? 'Mettre à jour le marque-page'
                      : 'Ajouter un marque-page')
                : (_hasBookmark ? 'Update bookmark' : 'Add bookmark'),
            onPressed: _saveBookmark,
            icon: Icon(
              _hasBookmark ? Icons.bookmark_rounded : Icons.bookmark_add_rounded,
              size: 19.r,
              color: _hasBookmark
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurface,
            ),
          ),
          IconButton(
            tooltip: _isFrench ? 'Adapter à l’écran' : 'Fit to screen',
            onPressed: _fitToScreen,
            icon: Icon(Symbols.fit_screen_rounded, size: 18.r),
          ),
        ],
      ),
    );
  }

  Widget _buildTextReader(ThemeData theme) {
    return LayoutBuilder(
      builder: (context, constraints) => InteractiveViewer(
        transformationController: _transformationController,
        minScale: 0.5,
        maxScale: 5.0,
        boundaryMargin: EdgeInsets.all(320.r),
        alignment: Alignment.topCenter,
        panEnabled: true,
        scaleEnabled: true,
        child: SingleChildScrollView(
          controller: _scrollController,
          physics: const BouncingScrollPhysics(),
          padding: EdgeInsets.fromLTRB(28.r, 72.r, 28.r, 42.r),
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: constraints.maxWidth - 56.r),
            child: SelectableText(
              widget.text ?? '',
              style: theme.textTheme.bodyLarge?.copyWith(
                height: 1.62,
                fontSize: 16.r.clamp(14.0, 21.0).toDouble(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPageReader(ThemeData theme) {
    return _pageByPage
        ? _buildPagedPageReader(theme)
        : _buildContinuousPageReader(theme);
  }

  Widget _buildPagedPageReader(ThemeData theme) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final currentPage = widget.pages[_pageIndex];
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (details) =>
                    _handlePageTap(details, constraints.maxWidth),
                child: _AdaptivePagedImage(
                  key: ValueKey<String>(currentPage),
                  url: currentPage,
                  headers: widget.imageHeaders,
                  transformationController: _transformationController,
                  theme: theme,
                  onLongPageChanged: (isLong) {
                    if (!mounted || _currentPageIsLong == isLong) return;
                    setState(() => _currentPageIsLong = isLong);
                  },
                ),
              ),
            ),
            if (_pageIndex > 0)
              Positioned(
                left: 5.r,
                top: constraints.maxHeight * 0.48,
                child: IconButton(
                  tooltip: _isFrench ? 'Page précédente' : 'Previous page',
                  onPressed: _previousPage,
                  icon: Icon(
                    Symbols.chevron_left_rounded,
                    size: 28.r,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
                  ),
                ),
              ),
            if (_pageIndex + 1 < widget.pages.length)
              Positioned(
                right: 5.r,
                top: constraints.maxHeight * 0.48,
                child: IconButton(
                  tooltip: _isFrench ? 'Page suivante' : 'Next page',
                  onPressed: _nextPage,
                  icon: Icon(
                    Symbols.chevron_right_rounded,
                    size: 28.r,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
                  ),
                ),
              ),
            Positioned(
              bottom: 7.r,
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: Center(
                  child: Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: 9.r,
                      vertical: 4.r,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface.withValues(alpha: 0.72),
                      borderRadius: BorderRadius.circular(9.r),
                    ),
                    child: Text(
                      _currentPageIsLong
                          ? '${_pageIndex + 1} / ${widget.pages.length} • ${_isFrench ? 'défilement vertical' : 'vertical scroll'}'
                          : '${_pageIndex + 1} / ${widget.pages.length}',
                      style: TextStyle(
                        fontSize: 9.r,
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildContinuousPageReader(ThemeData theme) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableHeight = constraints.maxHeight - 96.r;
        final pageHeight = availableHeight > 180.r
            ? availableHeight
            : constraints.maxHeight;
        final availableWidth = constraints.maxWidth - 28.r;
        final pageWidth = availableWidth > 180.r
            ? availableWidth
            : constraints.maxWidth;

        return InteractiveViewer(
          transformationController: _transformationController,
          minScale: 0.35,
          maxScale: 5.0,
          boundaryMargin: EdgeInsets.all(360.r),
          alignment: Alignment.topCenter,
          panEnabled: true,
          scaleEnabled: true,
          child: SingleChildScrollView(
            controller: _scrollController,
            physics: const BouncingScrollPhysics(),
            padding: EdgeInsets.fromLTRB(14.r, 68.r, 14.r, 28.r),
            child: Column(
              children: [
                for (var index = 0; index < widget.pages.length; index++) ...[
                  SizedBox(
                    width: pageWidth,
                    height: pageHeight,
                    child: Image.network(
                      widget.pages[index],
                      headers: widget.imageHeaders,
                      fit: BoxFit.contain,
                      loadingBuilder: (context, child, progress) {
                        if (progress == null) return child;
                        return const Center(child: CircularProgressIndicator());
                      },
                      errorBuilder: (_, __, ___) => Center(
                        child: Icon(
                          Symbols.broken_image_rounded,
                          size: 42.r,
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.45),
                        ),
                      ),
                    ),
                  ),
                  if (index + 1 < widget.pages.length) SizedBox(height: 12.r),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

}

class _AdaptivePagedImage extends StatefulWidget {
  const _AdaptivePagedImage({
    super.key,
    required this.url,
    required this.headers,
    required this.transformationController,
    required this.theme,
    required this.onLongPageChanged,
  });

  final String url;
  final Map<String, String>? headers;
  final TransformationController transformationController;
  final ThemeData theme;
  final ValueChanged<bool> onLongPageChanged;

  @override
  State<_AdaptivePagedImage> createState() => _AdaptivePagedImageState();
}

class _AdaptivePagedImageState extends State<_AdaptivePagedImage> {
  ImageStream? _imageStream;
  ImageStreamListener? _imageListener;
  bool _resolved = false;
  bool _isLongPage = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _resolveDimensions());
  }

  @override
  void didUpdateWidget(covariant _AdaptivePagedImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url || oldWidget.headers != widget.headers) {
      _detachImageListener();
      _resolved = false;
      _isLongPage = false;
      WidgetsBinding.instance.addPostFrameCallback((_) => _resolveDimensions());
    }
  }

  @override
  void dispose() {
    _detachImageListener();
    super.dispose();
  }

  void _detachImageListener() {
    if (_imageStream != null && _imageListener != null) {
      _imageStream!.removeListener(_imageListener!);
    }
    _imageStream = null;
    _imageListener = null;
  }

  void _resolveDimensions() {
    if (!mounted) return;
    final provider = NetworkImage(widget.url, headers: widget.headers);
    final stream = provider.resolve(createLocalImageConfiguration(context));
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        final width = info.image.width.toDouble();
        final height = info.image.height.toDouble();
        final isLong = width > 0 && height / width >= 2.35;
        if (!mounted) return;
        setState(() {
          _resolved = true;
          _isLongPage = isLong;
        });
        widget.onLongPageChanged(isLong);
      },
      onError: (_, __) {
        if (!mounted) return;
        setState(() {
          _resolved = true;
          _isLongPage = false;
        });
        widget.onLongPageChanged(false);
      },
    );
    _imageStream = stream;
    _imageListener = listener;
    stream.addListener(listener);
  }

  Widget _networkImage({required BoxFit fit}) {
    return Image.network(
      widget.url,
      headers: widget.headers,
      fit: fit,
      alignment: _isLongPage ? Alignment.topCenter : Alignment.center,
      loadingBuilder: (context, child, progress) {
        if (progress == null) return child;
        return const Center(child: CircularProgressIndicator());
      },
      errorBuilder: (_, __, ___) => Center(
        child: Icon(
          Symbols.broken_image_rounded,
          size: 42.r,
          color: widget.theme.colorScheme.onSurface.withValues(alpha: 0.45),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (_resolved && _isLongPage) {
          var readableWidth = constraints.maxWidth * 0.74;
          final maximumWidth = constraints.maxWidth - 76.r;
          if (maximumWidth > 260.r && readableWidth > maximumWidth) {
            readableWidth = maximumWidth;
          }
          if (readableWidth < constraints.maxWidth * 0.58) {
            readableWidth = constraints.maxWidth * 0.58;
          }

          return InteractiveViewer(
            transformationController: widget.transformationController,
            constrained: false,
            clipBehavior: Clip.none,
            minScale: 0.35,
            maxScale: 5.0,
            boundaryMargin: EdgeInsets.symmetric(
              horizontal: constraints.maxWidth * 0.42,
              vertical: constraints.maxHeight * 1.2,
            ),
            alignment: Alignment.topCenter,
            panEnabled: true,
            scaleEnabled: true,
            child: Padding(
              padding: EdgeInsets.only(top: 68.r, bottom: 28.r),
              child: SizedBox(
                width: readableWidth,
                child: _networkImage(fit: BoxFit.fitWidth),
              ),
            ),
          );
        }

        return InteractiveViewer(
          transformationController: widget.transformationController,
          minScale: 0.35,
          maxScale: 5.0,
          boundaryMargin: EdgeInsets.all(360.r),
          alignment: Alignment.center,
          panEnabled: true,
          scaleEnabled: true,
          child: SizedBox(
            width: constraints.maxWidth,
            height: constraints.maxHeight,
            child: Padding(
              padding: EdgeInsets.fromLTRB(18.r, 66.r, 18.r, 24.r),
              child: _networkImage(fit: BoxFit.contain),
            ),
          ),
        );
      },
    );
  }
}

