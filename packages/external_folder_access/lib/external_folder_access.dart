import 'dart:io';

import 'package:flutter/services.dart';

/// Thin Dart wrapper around the native iOS folder-bookmark plugin.
///
/// All methods are no-ops (return null) on platforms other than iOS, so
/// call sites don't need to guard on `Platform.isIOS` themselves — on
/// desktop/Android, NeoStation already has real filesystem/SAF access and
/// has no use for this.
class ExternalFolderAccess {
  ExternalFolderAccess._();

  static const MethodChannel _channel = MethodChannel(
    'neostation/external_folder_access',
  );

  /// Bookmark slot used when a caller doesn't name one. Several folders can
  /// be linked independently by passing a different [key] (e.g. `'armsx2'`),
  /// each stored under its own security-scoped bookmark natively. This
  /// default maps to the plugin's original single-bookmark storage key, so
  /// a folder linked before multi-bookmark support still resolves.
  static const String defaultBookmarkKey = 'retroarch';

  /// Presents the system folder picker — which can browse into any app's
  /// exposed "On My iPhone" location, e.g. RetroArch's — and persists a
  /// security-scoped bookmark for the picked folder so it stays accessible
  /// across app relaunches.
  ///
  /// Returns the picked folder's absolute path, or `null` if the user
  /// cancelled, this isn't iOS, or the pick otherwise failed.
  static Future<String?> pickAndBookmarkFolder({
    String key = defaultBookmarkKey,
  }) async {
    if (!Platform.isIOS) return null;
    try {
      return await _channel.invokeMethod<String>('pickAndBookmarkFolder', {
        'key': key,
      });
    } on PlatformException {
      return null;
    }
  }

  /// Picks a folder, stores its bookmark, then immediately re-resolves that
  /// bookmark so the returned path is security-scoped for the current app
  /// session.
  ///
  /// The document picker only grants access while its native callback is
  /// running. Callers that scan the returned path must use this method rather
  /// than [pickAndBookmarkFolder], otherwise the first scan can see an empty
  /// directory until NeoStation is restarted and the bookmark is resolved at
  /// startup.
  static Future<String?> pickAndActivateFolder({
    String key = defaultBookmarkKey,
  }) async {
    final picked = await pickAndBookmarkFolder(key: key);
    if (picked == null) return null;

    final resolved = await resolveBookmarkedFolder(key: key);
    if (resolved == null) {
      throw StateError('The selected folder could not be activated.');
    }
    return resolved;
  }

  /// Resolves the folder previously bookmarked under [key] (if any) and
  /// starts security-scoped access to it for this app session.
  ///
  /// Returns the folder's absolute path, or `null` if no folder has been
  /// linked under that key yet (or this isn't iOS).
  static Future<String?> resolveBookmarkedFolder({
    String key = defaultBookmarkKey,
  }) async {
    if (!Platform.isIOS) return null;
    try {
      return await _channel.invokeMethod<String>('resolveBookmarkedFolder', {
        'key': key,
      });
    } on PlatformException {
      return null;
    }
  }

  /// Forgets the folder linked under [key]. The next call to
  /// [resolveBookmarkedFolder] with the same key returns `null` until a new
  /// folder is picked via [pickAndBookmarkFolder]. Other keys are
  /// untouched.
  static Future<void> clearBookmark({String key = defaultBookmarkKey}) async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod<void>('clearBookmark', {'key': key});
    } on PlatformException {
      // Nothing meaningful to recover here — worst case the bookmark
      // lingers and a future resolve attempt fails, which is handled.
    }
  }

  /// Presents iOS's genuine "Open In" menu for [filePath] — a different API
  /// from the general Share Sheet (see the `share_plus` package, used
  /// elsewhere in NeoStation). "Open In" hands the file to an app that
  /// declared itself able to *own*/import that document type, which is the
  /// traditional "here's a file, please open it" flow, as opposed to
  /// "here's some content, do something with it" (sharing). Returns `true`
  /// if the menu was presented, `false`/`null` otherwise (including on
  /// non-iOS platforms, where this is a no-op).
  static Future<bool?> openInMenu(String filePath) async {
    if (!Platform.isIOS) return null;
    try {
      return await _channel.invokeMethod<bool>('openInMenu', {
        'path': filePath,
      });
    } on PlatformException {
      return null;
    }
  }

  /// Opens an arbitrary URL string on iOS without round-tripping through
  /// Dart's [Uri] class. This matters for custom URL schemes whose handler
  /// (incorrectly, but in practice) treats the host as case-sensitive, e.g.
  /// MeloNX expects `melonx://gameInfo?...`. Dart normalizes URI hosts to
  /// lowercase (`gameinfo`), so passing the raw string through the native
  /// side preserves the exact spelling expected by the target app.
  static Future<bool?> openRawUrl(String url) async {
    if (!Platform.isIOS) return null;
    try {
      return await _channel.invokeMethod<bool>('openRawUrl', {'url': url});
    } on PlatformException {
      return false;
    }
  }

  /// Computes a file SHA-256 natively on a background queue. This avoids
  /// blocking Flutter while Manic EMU identifiers are prepared for large ROMs.
  static Future<String?> sha256File(String filePath) async {
    if (!Platform.isIOS) return null;
    try {
      return await _channel.invokeMethod<String>('sha256File', {
        'path': filePath,
      });
    } on PlatformException {
      return null;
    }
  }

  /// Configures NeoStation's native iOS audio session for UI/game-front-end
  /// sounds: the hardware Ring/Silent switch mutes playback and audio may mix
  /// with other apps. This is called after SoLoud initializes because its
  /// backend can otherwise choose an audio-session category that ignores the
  /// Silent switch.
  static Future<bool?> configureAudioSessionForSilentMode() async {
    if (!Platform.isIOS) return null;
    try {
      return await _channel.invokeMethod<bool>(
        'configureAudioSessionForSilentMode',
      );
    } on PlatformException {
      return false;
    }
  }

  /// Opens one StikDebug `enable-jit` request immediately while NeoStation is
  /// foregrounded. It schedules no UIApplication work after NeoStation is
  /// backgrounded.
  static Future<bool?> openJitRequest({
    required String targetBaseBundleId,
    String scriptName = 'universal.js',
    String? scriptDataBase64Url,
    String debugFileName = 'jit_request_debug.txt',
  }) async {
    if (!Platform.isIOS) return null;
    try {
      return await _channel.invokeMethod<bool>('openJitRequest', {
        'targetBaseBundleId': targetBaseBundleId,
        'scriptName': scriptName,
        if (scriptDataBase64Url != null) 'scriptData': scriptDataBase64Url,
        'debugFileName': debugFileName,
      });
    } on PlatformException {
      return false;
    }
  }

  /// Registers a callback for URLs opened while the app is running — e.g.
  /// RetroArch calling back via neostation://retroarch?games=<base64url>
  /// after a library export request. Replaces the app_links package for
  /// this single use case, since the native side already forwards
  /// `application(_:open:options:)` through this same channel (see
  /// ExternalFolderAccessPlugin.swift).
  ///
  /// Only one listener is supported at a time; calling this again replaces
  /// the previous one. No-op on non-iOS platforms.
  static void setIncomingUrlListener(void Function(Uri uri) onUrl) {
    if (!Platform.isIOS) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onIncomingUrl' && call.arguments is String) {
        final uri = Uri.tryParse(call.arguments as String);
        if (uri != null) onUrl(uri);
      }
      return null;
    });
  }
}
