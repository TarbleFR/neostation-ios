import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/rpcs3_config_adapter.dart';
import 'package:neostation/services/rpcs3_game_profile_database.dart';
import 'package:rpcs3_internal_bridge/rpcs3_internal_bridge.dart';

@immutable
class Rpcs3GameProfile {
  const Rpcs3GameProfile({required this.serial, required this.settings});

  final String serial;
  final Map<String, String> settings;

  String toRpcs3Yaml([String base = '']) =>
      Rpcs3ConfigAdapter.mergeScalarOverrides(base, _yamlOverrides(settings));

  static Map<List<String>, String> _yamlOverrides(
    Map<String, String> settings,
  ) {
    final result = <List<String>, String>{};
    for (final entry in settings.entries) {
      final yamlPath = switch (entry.key) {
        'cpu.ppu_decoder' => const <String>['Core', 'PPU Decoder'],
        'cpu.spu_decoder' => const <String>['Core', 'SPU Decoder'],
        'cpu.ppu_profiler' => const <String>['Core', 'PPU Profiler'],
        'cpu.spu_block_size' => const <String>['Core', 'SPU Block Size'],
        'cpu.spu_xfloat_accuracy' => const <String>[
          'Core',
          'SPU XFloat Accuracy',
        ],
        'cpu.preferred_spu_threads' => const <String>[
          'Core',
          'Preferred SPU Threads',
        ],
        'advanced.llvm_precompilation' => const <String>[
          'Core',
          'LLVM Precompilation',
        ],
        'emulator.max_llvm_threads' => const <String>[
          'Core',
          'Max LLVM Compile Threads',
        ],
        'gpu.shader_mode' => const <String>['Video', 'Shader Mode'],
        'gpu.shader_precision' => const <String>['Video', 'Shader Precision'],
        'gpu.write_color_buffers' => const <String>[
          'Video',
          'Write Color Buffers',
        ],
        'gpu.resolution_scale' => const <String>['Video', 'Resolution Scale'],
        'gpu.frame_limit' => const <String>['Video', 'Frame limit'],
        'gpu.multithreaded_rsx' => const <String>[
          'Video',
          'Multithreaded RSX',
        ],
        'gpu.async_texture_uploads' => const <String>[
          'Video',
          'Vulkan',
          'Asynchronous Texture Streaming',
        ],
        'experimental.mobile_spu_scheduling' => const <String>[
          'iOS Experimental',
          'Mobile SPU Compile Scheduling',
        ],
        'experimental.fps_optimization_batch' => const <String>[
          'iOS Experimental',
          'FPS Optimization Batch',
        ],
        'experimental.fifo_cache_size' => const <String>[
          'iOS Experimental',
          'RSX FIFO Read Cache',
        ],
        'experimental.getllar_backoff' => const <String>[
          'iOS Experimental',
          'GETLLAR Mobile Backoff',
        ],
        _ => throw StateError(
          'Unsupported managed RPCS3 setting: ${entry.key}',
        ),
      };
      result[yamlPath] = entry.value;
    }
    return result;
  }
}

@immutable
class Rpcs3ResolvedProfile {
  const Rpcs3ResolvedProfile({
    required this.serial,
    required this.config,
    required this.family,
    required this.hasDatabaseRecommendation,
    required this.hasIndividualOverride,
  });

  final String serial;
  final String config;
  final Rpcs3ProfileFamily family;
  final bool hasDatabaseRecommendation;
  final bool hasIndividualOverride;

  bool get isManaged => config.trim().isNotEmpty;
}

/// Resolves `global -> family/GameDB -> title override`. Explicit user edits
/// are a separate native layer and are replayed last by the RPCS3 iOS core.
abstract final class Rpcs3GameProfileService {
  static final LoggerService _log = LoggerService.instance;
  static final RegExp _serialPattern = RegExp(r'^[A-Z0-9]{9,16}$');

  // This list remains intentionally small: it contains iOS evidence or a
  // platform-independent guest-timing fix, never speculative desktop tweaks.
  static const Map<String, Map<String, String>> _serialOverrides = {
    // Dynasty Warriors 6: the iOS ARM64 PPU LLVM path terminated during boot.
    'BLES00215': {
      'cpu.ppu_decoder': 'Interpreter (static)',
      'advanced.llvm_precompilation': 'false',
      'emulator.max_llvm_threads': '0',
      'experimental.mobile_spu_scheduling': 'Automatic',
      'cpu.spu_block_size': 'Safe',
    },
    'BLUS30110': {
      'cpu.ppu_decoder': 'Interpreter (static)',
      'advanced.llvm_precompilation': 'false',
      'emulator.max_llvm_threads': '0',
      'experimental.mobile_spu_scheduling': 'Automatic',
      'cpu.spu_block_size': 'Safe',
    },

    // God of War III: retain RPCS3's WCB/Ultra/Mega recommendations and add
    // the guarded ARM64 batch already instrumented by Build 256.
    'BCUS98111': _godOfWarIII,
    'BCES00510': _godOfWarIII,
    'BCAS25003': _godOfWarIII,

    // ARMSX3 issue #77 is guest pacing rather than an Android driver hack.
    // PS3 Native honours the title's alternate-vblank flip cadence.
    'BLUS31213': {'gpu.frame_limit': 'PS3 Native'},
    'BLES01935': {'gpu.frame_limit': 'PS3 Native'},
  };

  static const Map<String, String> _godOfWarIII = {
    'cpu.ppu_decoder': 'Recompiler (LLVM)',
    'cpu.spu_decoder': 'Recompiler (LLVM)',
    'cpu.ppu_profiler': 'false',
    // Persist raw SPU metadata on the first run and rebuild those safe guest
    // blocks before gameplay on later runs. Host ARM64 machine code is not
    // persisted because it still embeds process-specific addresses.
    'advanced.llvm_precompilation': 'true',
    'cpu.spu_block_size': 'Mega',
    'cpu.spu_xfloat_accuracy': 'Approximate',
    'cpu.preferred_spu_threads': '0',
    'gpu.resolution_scale': '75',
    'gpu.shader_mode': 'Async Recompiler (multi-threaded)',
    'gpu.multithreaded_rsx': 'true',
    'gpu.async_texture_uploads': 'true',
    'experimental.fps_optimization_batch': 'Enabled',
    'experimental.fifo_cache_size': '4 KiB',
    'experimental.getllar_backoff': 'Enabled',
  };

  static final Set<String> _detectedSerials = <String>{};

  static String? normalizeSerial(String? value) {
    final serial = value?.trim().toUpperCase() ?? '';
    return _serialPattern.hasMatch(serial) ? serial : null;
  }

  /// Synchronous individual override lookup retained for settings UI/tests.
  static Rpcs3GameProfile? profileForSerial(String? rawSerial) {
    final serial = normalizeSerial(rawSerial);
    if (serial == null) return null;
    return Rpcs3GameProfile(
      serial: serial,
      settings: <String, String>{...?_serialOverrides[serial]},
    );
  }

  static Future<Rpcs3ResolvedProfile?> resolveProfile(
    String? rawSerial, {
    bool allowNetwork = false,
  }) async {
    final serial = normalizeSerial(rawSerial);
    if (serial == null) return null;
    final database = await Rpcs3GameProfileDatabase.entryFor(
      serial,
      allowNetwork: allowNetwork,
    );
    final individual = profileForSerial(serial)!;
    final config = individual.toRpcs3Yaml(database?.config ?? '');
    return Rpcs3ResolvedProfile(
      serial: serial,
      config: Rpcs3ConfigAdapter.hasUsefulSetting(config) ? config : '',
      family: database?.family ?? Rpcs3ProfileFamily.balanced,
      hasDatabaseRecommendation: database != null,
      hasIndividualOverride: individual.settings.isNotEmpty,
    );
  }

  static void noteDetectedSerials(Iterable<String> serials) {
    _detectedSerials
      ..clear()
      ..addAll(serials.map(normalizeSerial).whereType<String>());
  }

  @visibleForTesting
  static Future<String> databasePayloadForSerials(
    Iterable<String> serials,
  ) async {
    final profiles = await Future.wait(
      serials.map((serial) => resolveProfile(serial)),
    );
    return _databasePayload(profiles.whereType<Rpcs3ResolvedProfile>());
  }

  static String _databasePayload(Iterable<Rpcs3ResolvedProfile> profiles) {
    final games = <String, dynamic>{};
    for (final profile in profiles) {
      if (!profile.isManaged) continue;
      games[profile.serial] = <String, String>{'config': profile.config};
    }
    return jsonEncode(<String, dynamic>{'return_code': 0, 'games': games});
  }

  static Future<Map<String, dynamic>> applyForLaunch(String rawSerial) async {
    final profile = await resolveProfile(rawSerial);
    if (profile == null) {
      return const <String, dynamic>{
        'success': false,
        'message': 'RPCS3 rejected the invalid PlayStation serial.',
      };
    }
    if (!profile.isManaged) {
      _log.i('RPCS3 ${profile.serial}: using NeoStation global iOS profile.');
      return <String, dynamic>{
        'success': true,
        'message': 'RPCS3 global iOS profile inherited for ${profile.serial}.',
      };
    }

    _detectedSerials.add(profile.serial);
    final resolved = await Future.wait(_detectedSerials.map(resolveProfile));
    final report = await Rpcs3InternalBridge.updateConfigDatabase(
      _databasePayload(resolved.whereType<Rpcs3ResolvedProfile>()),
    );
    if (report['success'] == true) {
      _log.i(
        'RPCS3 profile ready: ${profile.serial}; family=${profile.family.name}; '
        'database=${profile.hasDatabaseRecommendation}; '
        'individual=${profile.hasIndividualOverride}; user overrides remain last.',
      );
    }
    return report;
  }

  /// Publish offline profiles immediately, then refresh the official source in
  /// the background. Launch never waits on the network.
  static Future<void> publishDetectedProfilesIfReady() async {
    if (_detectedSerials.isEmpty) return;
    await _publishDetected();
    unawaited(_refreshAndRepublish());
  }

  static Future<void> _publishDetected() async {
    try {
      final profiles = await Future.wait(_detectedSerials.map(resolveProfile));
      final managed = profiles
          .whereType<Rpcs3ResolvedProfile>()
          .where((profile) => profile.isManaged)
          .toList(growable: false);
      if (managed.isEmpty) return;
      final report = await Rpcs3InternalBridge.updateConfigDatabase(
        _databasePayload(managed),
      );
      if (report['success'] != true) {
        _log.i(
          'RPCS3 GameDB publication deferred until launch: '
          '${report['message'] ?? 'Core not ready'}',
        );
      }
    } catch (error) {
      _log.i('RPCS3 GameDB publication deferred until launch: $error');
    }
  }

  static Future<void> _refreshAndRepublish() async {
    if (await Rpcs3GameProfileDatabase.refreshIfStale()) {
      await _publishDetected();
    }
  }
}
