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
    final ios = <String, String>{};

    for (final entry in settings.entries) {
      switch (entry.key) {
        case 'cpu.ppu_decoder':
          core['PPU Decoder'] = entry.value;
          break;
        case 'cpu.spu_block_size':
          core['SPU Block Size'] = entry.value;
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

  static const Map<String, String> _iosBaseSettings = <String, String>{
    'advanced.llvm_precompilation': 'false',
    'emulator.max_llvm_threads': '0',
    'experimental.mobile_spu_scheduling': 'Automatic',
    'cpu.spu_block_size': 'Safe',
  };

  // The iOS ARM64 diagnostic log for Dynasty Warriors 6 terminates its PPU
  // main thread inside the LLVM symbol resolver at 0x701f000000. Keep the
  // compatibility fallback strictly scoped to the known regional serials.
  static const Map<String, Map<String, String>>
  _serialOverrides = <String, Map<String, String>>{
    'BLES00215': <String, String>{'cpu.ppu_decoder': 'Interpreter (static)'},
    'BLUS30110': <String, String>{'cpu.ppu_decoder': 'Interpreter (static)'},
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
      settings: <String, String>{
        ..._iosBaseSettings,
        ...?_serialOverrides[serial],
      },
    );
  }

  /// Creates/loads profiles as soon as RPCS3 library metadata is detected.
  static void noteDetectedSerials(Iterable<String> serials) {
    _detectedProfiles.clear();
    for (final value in serials) {
      final profile = profileForSerial(value);
      if (profile != null) _detectedProfiles[profile.serial] = profile;
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
      games[profile.serial] = <String, String>{'config': profile.toRpcs3Yaml()};
    }
    return jsonEncode(<String, dynamic>{'return_code': 0, 'games': games});
  }

  /// Publishes every detected profile plus [rawSerial] before boot.
  ///
  /// The RPCS3 Core validates and atomically caches this serial database. The
  /// Build 248 Core applies the selected partial YAML after global/custom
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
