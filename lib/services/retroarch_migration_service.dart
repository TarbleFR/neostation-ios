import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum RetroArchExecutionMode { external, embedded }

class RetroArchMigrationUnavailable implements Exception {
  const RetroArchMigrationUnavailable();
}

/// An upgrade never changes an existing user's emulator without a saved choice.
/// Files are handled separately; accepting a choice does not move or delete data.
class RetroArchMigrationService extends ChangeNotifier {
  RetroArchMigrationService({SharedPreferences? preferences})
    : _preferences = preferences;

  static final instance = RetroArchMigrationService();
  static const preferenceKey = 'neostation_retroarch_migration_v1';
  static const currentDecisionVersion = 1;

  SharedPreferences? _preferences;
  _MigrationChoice? _choice;
  bool _loaded = false;
  Future<void>? _loadOperation;

  bool get isInitialized => _choice != null;
  RetroArchExecutionMode get mode =>
      _choice?.mode ?? RetroArchExecutionMode.external;
  bool get usesEmbedded => mode == RetroArchExecutionMode.embedded;
  int get decisionVersion => _choice?.decisionVersion ?? 0;
  bool get needsMigration =>
      _choice?.existingInstallation == true &&
      mode == RetroArchExecutionMode.external &&
      decisionVersion < currentDecisionVersion;

  /// Loading alone defaults conservatively to external. Only first-run setup
  /// can identify a fresh installation and initialize its embedded default.
  Future<void> load() async {
    if (_loaded) return;
    final active = _loadOperation;
    if (active != null) return active;
    final operation = _load();
    _loadOperation = operation;
    try {
      await operation;
    } finally {
      _loadOperation = null;
    }
  }

  Future<void> _load() async {
    final preferences = _preferences ??= await SharedPreferences.getInstance();
    await preferences.reload();
    final raw = preferences.getString(preferenceKey);
    if (raw != null) {
      try {
        final value = jsonDecode(raw);
        if (value is! Map ||
            value['schema'] != 1 ||
            !const {'external', 'embedded'}.contains(value['mode']) ||
            value['existingInstallation'] is! bool ||
            value['decisionVersion'] is! int) {
          throw const FormatException('Invalid RetroArch migration choice');
        }
        _choice = _MigrationChoice(
          mode: value['mode'] == 'embedded'
              ? RetroArchExecutionMode.embedded
              : RetroArchExecutionMode.external,
          existingInstallation: value['existingInstallation'] as bool,
          decisionVersion: value['decisionVersion'] as int,
        );
      } on FormatException {
        // A damaged record is never interpreted as permission to switch.
        _choice = const _MigrationChoice(
          mode: RetroArchExecutionMode.external,
          existingInstallation: true,
          decisionVersion: 0,
        );
      }
    }
    _loaded = true;
  }

  Future<void> initialize({required bool existingInstallation}) async {
    await load();
    if (_choice != null) return;
    await _save(
      _MigrationChoice(
        mode: existingInstallation
            ? RetroArchExecutionMode.external
            : RetroArchExecutionMode.embedded,
        existingInstallation: existingInstallation,
        decisionVersion: existingInstallation ? 0 : currentDecisionVersion,
      ),
    );
  }

  Future<bool> shouldOfferMigration({required bool backendAvailable}) async {
    await load();
    return backendAvailable && needsMigration;
  }

  Future<void> chooseEmbedded({required bool backendAvailable}) async {
    if (!backendAvailable) throw const RetroArchMigrationUnavailable();
    await setMode(RetroArchExecutionMode.embedded, backendAvailable: true);
  }

  Future<void> keepExternal() => setMode(RetroArchExecutionMode.external);

  /// Used both by the upgrade offer and a later explicit Settings choice.
  Future<void> setMode(
    RetroArchExecutionMode mode, {
    bool backendAvailable = false,
  }) async {
    if (mode == RetroArchExecutionMode.embedded && !backendAvailable) {
      throw const RetroArchMigrationUnavailable();
    }
    await load();
    await _save(
      _MigrationChoice(
        mode: mode,
        existingInstallation: _choice?.existingInstallation ?? true,
        decisionVersion: currentDecisionVersion,
      ),
    );
  }

  Future<void> _save(_MigrationChoice choice) async {
    final preferences = _preferences ??= await SharedPreferences.getInstance();
    final saved = await preferences.setString(
      preferenceKey,
      jsonEncode({
        'schema': 1,
        'mode': choice.mode.name,
        'existingInstallation': choice.existingInstallation,
        'decisionVersion': choice.decisionVersion,
      }),
    );
    if (!saved) {
      // SharedPreferences updates its cache before the platform acknowledges
      // the write. Reload so a failed write cannot masquerade as consent on a
      // later service instance, and keep the current in-memory choice intact.
      await preferences.reload();
      throw StateError('RETROARCH_MIGRATION_PREFERENCE_WRITE_FAILED');
    }
    _choice = choice;
    _loaded = true;
    notifyListeners();
  }
}

class _MigrationChoice {
  const _MigrationChoice({
    required this.mode,
    required this.existingInstallation,
    required this.decisionVersion,
  });
  final RetroArchExecutionMode mode;
  final bool existingInstallation;
  final int decisionVersion;
}
