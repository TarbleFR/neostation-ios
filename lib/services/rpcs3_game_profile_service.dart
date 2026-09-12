import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:rpcs3_internal_bridge/rpcs3_internal_bridge.dart';

/// A RPCS3 configuration overlay selected only by the real PS3 serial.
///
/// Values are stored as RPCS3 YAML instead of a complete custom config. During
/// boot the Core layers this document over the current global configuration,
/// so every key not listed here continues to come from `config.yml`.
@immutable
class Rpcs3GameProfile {
  const Rpcs3GameProfile({required this.serial, required this.settings});

  final String serial;
  final Map<String, String> settings;

  String toRpcs3Yaml() {
    final core = <String, String>{};
    final video = <String, String>{};
    final videoVulkan = <String, String>{};
    final ios = <String, String>{};

    for (final entry in settings.entries) {
      switch (entry.key) {
        case 'cpu.ppu_decoder':
          core['PPU Decoder'] = entry.value;
          break;
        case 'cpu.spu_decoder':
          core['SPU Decoder'] = entry.value;
          break;
        case 'cpu.ppu_profiler':
          core['PPU Profiler'] = entry.value;
          break;
        case 'cpu.spu_block_size':
          core['SPU Block Size'] = entry.value;
          break;
        case 'cpu.spu_xfloat_accuracy':
          core['SPU XFloat Accuracy'] = entry.value;
          break;
        case 'cpu.preferred_spu_threads':
          core['Preferred SPU Threads'] = entry.value;
          break;
        case 'advanced.llvm_precompilation':
          core['LLVM Precompilation'] = entry.value;
          break;
        case 'emulator.max_llvm_threads':
          core['Max LLVM Compile Threads'] = entry.value;
          break;
        case 'experimental.mobile_spu_scheduling':
          ios['Mobile SPU Compile Scheduling'] = entry.value;
          break;
        case 'experimental.fps_optimization_batch':
          ios['FPS Optimization Batch'] = entry.value;
          break;
        case 'gpu.resolution_scale':
          video['Resolution Scale'] = entry.value;
          break;
        case 'gpu.multithreaded_rsx':
          video['Multithreaded RSX'] = entry.value;
          break;
        case 'gpu.async_texture_uploads':
          videoVulkan['Asynchronous Texture Streaming'] = entry.value;
          break;
        default:
          throw StateError('Unsupported managed RPCS3 setting: ${entry.key}');
      }
    }

    final buffer = StringBuffer();
    void writeNode(String name, Map<String, String> values) {
      if (values.isEmpty) return;
      buffer.writeln('$name:');
      for (final entry in values.entries) {
        buffer.writeln('  ${entry.key}: ${entry.value}');
      }
    }

    writeNode('Core', core);
    if (video.isNotEmpty || videoVulkan.isNotEmpty) {
      buffer.writeln('Video:');
      for (final entry in video.entries) {
        buffer.writeln('  ${entry.key}: ${entry.value}');
      }
      if (videoVulkan.isNotEmpty) {
        buffer.writeln('  Vulkan:');
        for (final entry in videoVulkan.entries) {
          buffer.writeln('    ${entry.key}: ${entry.value}');
        }
      }
    }
    writeNode('iOS Experimental', ios);
    return buffer.toString();
  }
}

/// Serial-keyed RPCS3 compatibility profiles owned by NeoStation.
///
/// This registry deliberately never accepts a displayed title. RPCS3's own
/// serial rules are mirrored here: 9-16 ASCII alphanumeric characters, folded
/// to uppercase (BLES/BLUS/BCES/BCUS/NPUB/NPEB and other valid families).
abstract final class Rpcs3GameProfileService {
  static final LoggerService _log = LoggerService.instance;
  static final RegExp _serialPattern = RegExp(r'^[A-Z0-9]{9,16}$');

  // An earlier iOS ARM64 diagnostic for Dynasty Warriors 6 terminated its PPU
  // thread in LLVM; retain that compatibility fallback after clean re-import.
  // Keep it strictly scoped to the two known regional serials.
  static const Map<String, Map<String, String>>
  _serialOverrides = <String, Map<String, String>>{
    'BLES00215': <String, String>{
      'cpu.ppu_decoder': 'Interpreter (static)',
      'advanced.llvm_precompilation': 'false',
      'emulator.max_llvm_threads': '0',
      'experimental.mobile_spu_scheduling': 'Automatic',
      'cpu.spu_block_size': 'Safe',
    },
    'BLUS30110': <String, String>{
      'cpu.ppu_decoder': 'Interpreter (static)',
      'advanced.llvm_precompilation': 'false',
      'emulator.max_llvm_threads': '0',
      'experimental.mobile_spu_scheduling': 'Automatic',
      'cpu.spu_block_size': 'Safe',
    },

    // GOW III performance candidate: keep LLVM explicit so old diagnostic
    // custom configurations cannot select an interpreter or PPU profiler.
    // Automatic SPU scheduling replaces the old fixed concurrency of two;
    // physical-device A/B testing is still required to establish an FPS gain.
    // The 75% scale reduces 3D pixel load while preserving native-resolution
    // UI, and the iOS batch enables only the audited DMA/hash fast paths.
    'BCUS98111': <String, String>{
      'cpu.ppu_decoder': 'Recompiler (LLVM)',
      'cpu.spu_decoder': 'Recompiler (LLVM)',
      'cpu.ppu_profiler': 'false',
      'cpu.spu_block_size': 'Mega',
      'cpu.spu_xfloat_accuracy': 'Approximate',
      'cpu.preferred_spu_threads': '0',
      'gpu.resolution_scale': '75',
      'gpu.multithreaded_rsx': 'true',
      'gpu.async_texture_uploads': 'true',
      'experimental.fps_optimization_batch': 'Enabled',
    },
    'BCES00510': <String, String>{
      'cpu.ppu_decoder': 'Recompiler (LLVM)',
      'cpu.spu_decoder': 'Recompiler (LLVM)',
      'cpu.ppu_profiler': 'false',
      'cpu.spu_block_size': 'Mega',
      'cpu.spu_xfloat_accuracy': 'Approximate',
      'cpu.preferred_spu_threads': '0',
      'gpu.resolution_scale': '75',
      'gpu.multithreaded_rsx': 'true',
      'gpu.async_texture_uploads': 'true',
      'experimental.fps_optimization_batch': 'Enabled',
    },
    'BCAS25003': <String, String>{
      'cpu.ppu_decoder': 'Recompiler (LLVM)',
      'cpu.spu_decoder': 'Recompiler (LLVM)',
      'cpu.ppu_profiler': 'false',
      'cpu.spu_block_size': 'Mega',
      'cpu.spu_xfloat_accuracy': 'Approximate',
      'cpu.preferred_spu_threads': '0',
      'gpu.resolution_scale': '75',
      'gpu.multithreaded_rsx': 'true',
      'gpu.async_texture_uploads': 'true',
      'experimental.fps_optimization_batch': 'Enabled',
    },
  };

  static final Map<String, Rpcs3GameProfile> _detectedProfiles =
      <String, Rpcs3GameProfile>{};

  static String? normalizeSerial(String? value) {
    final serial = value?.trim().toUpperCase() ?? '';
    return _serialPattern.hasMatch(serial) ? serial : null;
  }

  static Rpcs3GameProfile? profileForSerial(String? rawSerial) {
    final serial = normalizeSerial(rawSerial);
    if (serial == null) return null;
    return Rpcs3GameProfile(
      serial: serial,
      settings: <String, String>{...?_serialOverrides[serial]},
    );
  }

  /// Creates/loads profiles as soon as RPCS3 library metadata is detected.
  static void noteDetectedSerials(Iterable<String> serials) {
    _detectedProfiles.clear();
    for (final value in serials) {
      final profile = profileForSerial(value);
      if (profile != null && profile.settings.isNotEmpty) {
        _detectedProfiles[profile.serial] = profile;
      }
    }
  }

  @visibleForTesting
  static String databasePayloadForSerials(Iterable<String> serials) {
    final profiles = <String, Rpcs3GameProfile>{};
    for (final value in serials) {
      final profile = profileForSerial(value);
      if (profile != null) profiles[profile.serial] = profile;
    }
    return _databasePayload(profiles.values);
  }

  static String _databasePayload(Iterable<Rpcs3GameProfile> profiles) {
    final games = <String, dynamic>{};
    for (final profile in profiles) {
      // An empty RPCS3 YAML document means "inherit the global config". It is
      // not a database record: the native validator deliberately rejects
      // empty documents and would atomically reject every valid sibling too.
      if (profile.settings.isEmpty) continue;
      games[profile.serial] = <String, String>{'config': profile.toRpcs3Yaml()};
    }
    return jsonEncode(<String, dynamic>{'return_code': 0, 'games': games});
  }

  /// Publishes every detected profile plus [rawSerial] before boot.
  ///
  /// The RPCS3 Core validates and atomically caches this serial database. The
  /// Build 250 Core applies the selected partial YAML after global/custom
  /// loading, so the managed compatibility keys win while unrelated values
  /// remain inherited.
  static Future<Map<String, dynamic>> applyForLaunch(String rawSerial) async {
    final profile = profileForSerial(rawSerial);
    if (profile == null) {
      return const <String, dynamic>{
        'success': false,
        'message': 'RPCS3 rejected the invalid PlayStation serial.',
      };
    }

    if (profile.settings.isEmpty) {
      _log.i(
        'RPCS3 ${profile.serial}: no managed override; using global config.',
      );
      return <String, dynamic>{
        'success': true,
        'message': 'RPCS3 global configuration inherited for ${profile.serial}.',
      };
    }

    _detectedProfiles[profile.serial] = profile;
    final report = await Rpcs3InternalBridge.updateConfigDatabase(
      _databasePayload(_detectedProfiles.values),
    );
    if (report['success'] == true) {
      _log.i(
        'RPCS3 serial profile ready: ${profile.serial} '
        '(${profile.settings.length} managed setting(s), global remainder inherited)',
      );
    }
    return report;
  }

  /// Best-effort publication used after an import/library scan. A cold-start
  /// scan can happen before RPCS3Core is loaded; launch always retries.
  static Future<void> publishDetectedProfilesIfReady() async {
    if (_detectedProfiles.isEmpty) return;
    try {
      final report = await Rpcs3InternalBridge.updateConfigDatabase(
        _databasePayload(_detectedProfiles.values),
      );
      if (report['success'] != true) {
        _log.i(
          'RPCS3 detected serial profiles will be published at launch: '
          '${report['message'] ?? 'Core not ready'}',
        );
      }
    } catch (error) {
      _log.i('RPCS3 serial profile publication deferred until launch: $error');
    }
  }
}
