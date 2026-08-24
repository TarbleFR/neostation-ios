part of '../my_games_list.dart';

/// Secondary-display, video preview, background and music-ducking logic for
/// the system games list.
///
/// Pushes selection metadata/artwork to the secondary hardware display,
/// drives the primary/secondary video previews, updates the ambient
/// background, and ducks background music while a video plays. All state
/// lives on the host [State]; this extension only moves the methods out of
/// the monolith — behaviour is unchanged. `setState` calls route through the
/// host [rebuild] bridge and the host static `_log` is qualified as
/// `_SystemGamesListState._log` (both required from an extension).
extension _SecondaryDisplay on _SystemGamesListState {
  /// Hard reset of the video preview system.
  void _resetVideoState() {
    _invalidateVideoPreview(updateDucking: false);
  }

  /// Graceful termination of video resources with state synchronization.
  void _stopVideoAndCleanup() {
    _invalidateVideoPreview(updateDucking: true);
  }

  void _invalidateVideoPreview({required bool updateDucking}) {
    _videoGeneration++;
    _videoTimer?.cancel();
    _videoTimer = null;
    final controller = _videoController;
    _videoController = null;

    if (mounted) {
      rebuild(() {
        _showVideo = false;
        _isVideoLoading = false;
      });
    }

    if (controller != null) {
      _videoTransition = _videoTransition
          .catchError((Object _) {})
          .then(
            (_) => _disposeVideoController(controller, reason: 'invalidate'),
          );
    }
    if (updateDucking) _updateMusicDucking();
  }

  Future<void> _disposeVideoController(
    VideoPlayerController controller, {
    required String reason,
  }) async {
    try {
      if (controller.value.isInitialized) {
        await controller.setVolume(0.0);
        await controller.pause();
      }
    } catch (error) {
      _SystemGamesListState._log.w('Video stop failed ($reason): $error');
    }
    try {
      await controller.dispose();
    } catch (error) {
      _SystemGamesListState._log.w('Video dispose failed ($reason): $error');
    }
  }

  Future<void> _fadeVideoVolume(
    VideoPlayerController controller, {
    required int generation,
    required double target,
  }) async {
    if (target <= 0) {
      await controller.setVolume(0.0);
      return;
    }
    // Readiness and cancellation are handled above. This short ramp only
    // removes the initial audio edge/click after the first decoded frame.
    const steps = 4;
    for (var step = 1; step <= steps; step++) {
      if (!mounted ||
          generation != _videoGeneration ||
          _videoController != controller)
        return;
      await controller.setVolume(target * step / steps);
      if (step < steps) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    }
  }

  /// Orchestrates background tasks triggered by game selection changes.
  void _performBackgroundOperationsForSelectedGame({bool force = false}) {
    if (_selectedGame == null || !mounted) return;

    // Suppress expensive operations (video, isolates) during rapid scrolling.
    if (_isNavigatingFast && !force) {
      _updateBackground(_selectedGame!);
      _updateSecondaryDisplay(_selectedGame!);
      return;
    }

    _detectGameSavesForSelectedGame();
    _loadLocalizedDescription();
    _startVideoTimer();
    _updateBackground(_selectedGame!);
    _updateSecondaryDisplay(_selectedGame!);
    _updateMusicDucking();
  }

  /// Synchronizes selection metadata and assets with secondary hardware displays.
  ///
  /// [forceMediaRefresh] forces a push even when every media path is unchanged
  /// and bumps [SecondaryDisplayStateData.mediaRevision]. Use it after a
  /// re-scrape (forceOverwrite) rewrites the art in place: the paths stay the
  /// same, so the dedup below would otherwise skip the update and the secondary
  /// engine would keep showing the stale cached bitmap.
  Future<void> _updateSecondaryDisplay(
    GameModel game, {
    bool forceMediaRefresh = false,
  }) async {
    if (_secondaryDisplayState == null || _isNavigatingBack) return;

    final systemFolderName =
        (widget.system.folderName == 'all' ||
                widget.system.folderName == SystemFolderNames.favorites) &&
            game.systemFolderName != null
        ? game.systemFolderName!
        : widget.system.primaryFolderName;

    // Media resolution hierarchy.
    final screenshotPath = game.getScreenshotPath(
      systemFolderName,
      _fileProvider,
    );

    final fanartPath = game.getImagePath(
      systemFolderName,
      'fanarts',
      _fileProvider,
    );

    final wheelPath = game.getImagePath(
      systemFolderName,
      'wheels',
      _fileProvider,
    );

    final videoPath = _getVideoPath(game);
    final videoExists = await _fileProvider.fileExists(videoPath);

    final configProvider = mounted
        ? context.read<SqliteConfigProvider>()
        : null;
    final isVideoMuted = !configProvider!.config.videoSound;
    final isScraperLoggedIn = await ScreenScraperService.hasSavedCredentials();

    final isMusicSystem = widget.system.folderName == 'music';

    // State optimization: Skip updates if metadata remains identical. A forced
    // media refresh (post re-scrape) always pushes — the paths are unchanged
    // but their bytes are not, so the secondary engine must be told to re-decode.
    final currentState = _secondaryDisplayState?.value;
    final bool shouldUpdate =
        forceMediaRefresh ||
        currentState == null ||
        currentState.systemName != widget.system.realName ||
        currentState.gameId !=
            (isMusicSystem
                ? MusicPlayerService().activeTrack?.romPath
                : game.romPath) ||
        currentState.gameFanart !=
            (isMusicSystem
                ? null
                : (File(fanartPath).existsSync() ? fanartPath : null)) ||
        currentState.gameScreenshot !=
            (isMusicSystem
                ? null
                : (File(screenshotPath).existsSync()
                      ? screenshotPath
                      : null)) ||
        currentState.gameVideo !=
            (isMusicSystem ? null : (videoExists ? videoPath : null)) ||
        currentState.gameWheel !=
            (isMusicSystem
                ? null
                : (File(wheelPath).existsSync() ? wheelPath : null)) ||
        currentState.isVideoMuted != isVideoMuted ||
        currentState.isGameLaunching != _isGameLaunching;

    if (shouldUpdate && !_isNavigatingBack) {
      final bool hasFanart = !isMusicSystem && File(fanartPath).existsSync();
      final bool hasScreenshot =
          !isMusicSystem && File(screenshotPath).existsSync();
      final bool hasWheel = !isMusicSystem && File(wheelPath).existsSync();

      // ignore: unawaited_futures
      _secondaryDisplayState?.updateState(
        systemName: widget.system.realName,
        gameFanart: hasFanart ? fanartPath : null,
        gameScreenshot: hasScreenshot ? screenshotPath : null,
        clearFanart: !hasFanart,
        clearScreenshot: !hasScreenshot,
        gameWheel: hasWheel ? wheelPath : null,
        clearWheel: !hasWheel,
        gameVideo: null, // Reset video state during active scrolling.
        clearVideo: true,
        gameImageBytes: null,
        clearImageBytes: isMusicSystem
            ? (MusicPlayerService().activeTrack == null)
            : true,
        isGameSelected: true,
        isVideoMuted: isVideoMuted,
        backgroundColor: mounted
            ? Theme.of(context).scaffoldBackgroundColor.toARGB32()
            : null,
        isGameLaunching: _isGameLaunching,
        gameId: isMusicSystem
            ? MusicPlayerService().activeTrack?.romPath
            : game.romPath,
        isScraperLoggedIn: isScraperLoggedIn,
        // Bump the revision on a forced refresh so the secondary engine evicts
        // its now-stale cached bitmaps and re-decodes the same paths from disk.
        mediaRevision: forceMediaRefresh
            ? (currentState?.mediaRevision ?? 0) + 1
            : null,
        // Panel is shown only by the launch push / live poll; browsing and
        // returning from a game hide it (it fades out on the secondary screen).
        showAchievementPanel: false,
      );
    }

    _updateMusicDucking();

    // Special handling for cover art extraction in Music mode.
    if (isMusicSystem) {
      final musicService = MusicPlayerService();
      final activeTrack = musicService.activeTrack;

      if (activeTrack != null) {
        final String? activeRomPath = activeTrack.romPath;

        if (activeRomPath != null) {
          final currentBytes = _secondaryDisplayState?.value?.gameImageBytes;
          final activeBytes = musicService.activePicture;

          if (activeBytes != null &&
              !listEquals(activeBytes, currentBytes) &&
              !_isNavigatingBack) {
            // ignore: unawaited_futures
            _secondaryDisplayState?.updateState(
              gameImageBytes: activeBytes,
              gameId: activeRomPath,
            );
          } else if (activeBytes == null) {
            _musicExtractionTimer?.cancel();
            _musicExtractionTimer = Timer(
              const Duration(milliseconds: 250),
              () {
                musicService.extractPicture(activeRomPath).then((
                  Uint8List? bytes,
                ) {
                  if (bytes != null && mounted) {
                    final latestBytes =
                        _secondaryDisplayState?.value?.gameImageBytes;
                    if (!listEquals(bytes, latestBytes) && !_isNavigatingBack) {
                      _secondaryDisplayState?.updateState(
                        gameImageBytes: bytes,
                        gameId: activeRomPath,
                      );
                    }
                  }
                });
              },
            );
          }
        }
      } else {
        _secondaryDisplayState?.updateState(
          gameImageBytes: null,
          clearImageBytes: true,
        );
      }
    }
  }

  /// Pushes specific video path updates to the secondary screen.
  Future<void> _updateSecondaryDisplayVideo(GameModel game) async {
    if (_secondaryDisplayState == null ||
        _isNavigatingBack ||
        _selectedGame != game) {
      return;
    }

    final videoPath = _getVideoPath(game);
    final videoExists = await _fileProvider.fileExists(videoPath);

    if (videoExists && !_isNavigatingBack && _selectedGame == game) {
      // ignore: unawaited_futures
      _secondaryDisplayState?.updateState(gameVideo: videoPath);
      _updateMusicDucking();
    }
  }

  /// Dynamically adjusts background music volume to prevent audio conflicts with video previews.
  void _updateMusicDucking() {
    if (!mounted) return;

    final config = context.read<SqliteConfigProvider>().config;

    // Suppress ducking within the Music Player system itself.
    if (widget.system.folderName == 'music') return;

    if (!config.videoSound) {
      MusicPlayerService().setDucked(false);
      return;
    }

    // Condition 2: Video is actually playing on primary
    bool primaryIsPlaying = _showVideo && !_isGameLaunching;

    // Condition 3: Secondary screen is active and actually playing a video
    final secondaryState = _secondaryDisplayState?.value;
    bool secondaryIsPlaying =
        (secondaryState?.isSecondaryActive ?? false) &&
        (secondaryState?.gameVideo != null);

    final shouldDuck = primaryIsPlaying || secondaryIsPlaying;
    MusicPlayerService().setDucked(shouldDuck);
  }

  void _updateBackground(GameModel game) {
    if (!mounted ||
        widget.system.folderName == 'all' ||
        widget.system.folderName == SystemFolderNames.favorites) {
      return;
    }

    final systemFolderName = widget.system.primaryFolderName;

    // Resolve game background: Prioritize high-resolution fanart, fallback to screenshot, then system default.
    String imagePath = game.getImagePath(
      systemFolderName,
      'fanarts',
      _fileProvider,
    );
    bool exists = File(imagePath).existsSync();

    if (!exists) {
      imagePath = game.getScreenshotPath(systemFolderName, _fileProvider);
      exists = File(imagePath).existsSync();
    }

    final ImageProvider imageProvider;
    if (exists) {
      imageProvider = FileImage(File(imagePath));
    } else {
      // Hardware-specific fallback if no game-specific art is resolved.
      final sysId =
          (widget.system.folderName == 'all' ||
                  widget.system.folderName == SystemFolderNames.favorites) &&
              game.systemFolderName != null
          ? game.systemFolderName!
          : widget.system.id;
      final path =
          'assets/images/logos/$sysId.webp'; // Correcting to logo fallback for grid consistency.
      imageProvider = AssetImage(path);
      imagePath = path;
    }

    context.read<SystemBackgroundProvider>().updateImage(
      imageProvider,
      imagePath: imagePath,
    );
  }

  /// Initiates the media preview sequence for the primary and secondary displays.
  void _startVideoTimer() {
    _videoTimer?.cancel();
    _videoTimer = null;
    if (!mounted || _isGameLaunching) return;

    final generation = _videoGeneration;
    final scheduledGame = _selectedGame;
    if (scheduledGame == null) return;

    // Keep the artwork/details stable for two seconds before AVPlayer is even
    // created. Rapid navigation therefore only resets this cancellable timer;
    // stale selections never initialize an audio/video pipeline.
    if (!_isVideoLoading) {
      rebuild(() => _isVideoLoading = true);
    }
    _videoTimer = Timer(_SystemGamesListState._videoStartDelay, () {
      _videoTimer = null;
      if (!mounted ||
          _isGameLaunching ||
          generation != _videoGeneration ||
          _selectedGame != scheduledGame) {
        if (mounted && generation == _videoGeneration) {
          rebuild(() => _isVideoLoading = false);
        }
        return;
      }

      unawaited(
        _startVideoPreviewForSelection(scheduledGame, generation: generation),
      );
    });
  }

  Future<void> _startVideoPreviewForSelection(
    GameModel scheduledGame, {
    required int generation,
  }) async {
    if (!mounted ||
        generation != _videoGeneration ||
        _selectedGame != scheduledGame) {
      return;
    }

    await _updateSecondaryDisplayVideo(scheduledGame);
    if (!mounted ||
        generation != _videoGeneration ||
        _selectedGame != scheduledGame) {
      return;
    }

    final showGameInfo = context
        .read<SqliteConfigProvider>()
        .config
        .showGameInfo;
    if (showGameInfo) {
      await _initializeVideo(scheduledGame, generation: generation);
    }
  }

  /// Initializes one preview generation. Controller destruction/creation is
  /// serialized so two AVPlayers can never own audio output at the same time.
  Future<void> _initializeVideo(
    GameModel game, {
    required int generation,
  }) async {
    if (!mounted || generation != _videoGeneration || _selectedGame != game) {
      return;
    }
    final config = context.read<SqliteConfigProvider>().config;
    if (!config.showGameInfo || _isGameLaunching) return;

    rebuild(() => _isVideoLoading = true);
    final videoPath = _getVideoPath(game);
    final exists = _fileProvider.isInitialized
        ? await _fileProvider.fileExists(videoPath)
        : File(videoPath).existsSync();
    if (!mounted || generation != _videoGeneration || _selectedGame != game) {
      return;
    }
    if (!exists) {
      rebuild(() {
        _showVideo = false;
        _isVideoLoading = false;
      });
      return;
    }

    final transition = _videoTransition.catchError((Object _) {}).then((
      _,
    ) async {
      if (!mounted || generation != _videoGeneration || _selectedGame != game) {
        return;
      }
      final old = _videoController;
      _videoController = null;
      if (old != null) {
        await _disposeVideoController(old, reason: 'replacement');
      }
      if (!mounted || generation != _videoGeneration || _selectedGame != game) {
        return;
      }

      final controller = VideoPlayerController.file(File(videoPath));
      try {
        await controller.initialize();
        if (!mounted ||
            generation != _videoGeneration ||
            _selectedGame != game) {
          await _disposeVideoController(controller, reason: 'stale-initialize');
          return;
        }

        await controller.setVolume(0.0);
        await controller.setLooping(true);
        await controller.play();
        if (!mounted ||
            generation != _videoGeneration ||
            _selectedGame != game) {
          await _disposeVideoController(controller, reason: 'stale-play');
          return;
        }

        _videoController = controller;
        rebuild(() {
          _showVideo = true;
          _isVideoLoading = false;
        });
        await _fadeVideoVolume(
          controller,
          generation: generation,
          target: config.videoSound ? 1.0 : 0.0,
        );
        _updateMusicDucking();
      } catch (error) {
        await _disposeVideoController(controller, reason: 'initialize-error');
        if (mounted && generation == _videoGeneration) {
          rebuild(() {
            _showVideo = false;
            _isVideoLoading = false;
          });
        }
        _SystemGamesListState._log.e(
          'Error initializing video generation $generation: $error',
        );
      }
    });
    _videoTransition = transition;
    await transition;
    if (mounted && generation == _videoGeneration && !_showVideo) {
      rebuild(() => _isVideoLoading = false);
    }
  }

  /// Resolves the absolute filesystem path for the targeted game video.
  String _getVideoPath(GameModel game) {
    final systemFolderName =
        (widget.system.folderName == 'all' ||
                widget.system.folderName == SystemFolderNames.favorites) &&
            game.systemFolderName != null
        ? game.systemFolderName!
        : widget.system.primaryFolderName;

    return game.getVideoPath(systemFolderName, _fileProvider);
  }
}
