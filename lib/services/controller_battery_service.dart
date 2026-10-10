import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:neoplay_bridge/neoplay_bridge.dart';

import 'diagnostics_directory.dart';
import 'logger_service.dart';

/// The connected controllers' batteries (iOS), for NeoStation's header: one
/// native subscription shared by its listeners. Each change is also written
/// to Files › NeoStation › Diagnostics › controller_battery.log with the level
/// iOS reports, so a level that never moves can be told apart from a display
/// fault.
class ControllerBatteryService {
  ControllerBatteryService._();

  static final ControllerBatteryService instance = ControllerBatteryService._();
  static final _log = LoggerService.instance;
  static const int _logLines = 200;

  /// The connected controllers, ordered by player; empty when none.
  final ValueNotifier<List<NeoPlayControllerBattery>> controllers =
      ValueNotifier<List<NeoPlayControllerBattery>>(const <NeoPlayControllerBattery>[]);

  StreamSubscription<List<NeoPlayControllerBattery>>? _subscription;
  int _listeners = 0;
  Future<void> _writing = Future<void>.value();

  bool get _supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  void attach() {
    if (!_supported) return;
    _listeners++;
    _subscription ??= NeoPlayBridge.controllerBatteries.listen(
      _update,
      onError: (Object error) => _log.w('Controller batteries unavailable: $error'),
    );
  }

  void detach() {
    if (!_supported || _listeners == 0) return;
    _listeners--;
    if (_listeners > 0) return;
    unawaited(_subscription?.cancel());
    _subscription = null;
    controllers.value = const <NeoPlayControllerBattery>[];
  }

  void _update(List<NeoPlayControllerBattery> next) {
    controllers.value = next;
    final line = '${DateTime.now().toUtc().toIso8601String()} ${describe(next)}';
    _writing = _writing.then((_) => _append(line));
  }

  /// One log line: each controller with the level and state iOS reports.
  static String describe(List<NeoPlayControllerBattery> readings) {
    if (readings.isEmpty) return 'no controller';
    return readings
        .map((reading) => 'player ${reading.player} "${reading.name}" '
            '${reading.percent == null ? 'level not reported' : '${reading.percent}%'} ${reading.charge}')
        .join('; ');
  }

  Future<void> _append(String line) async {
    try {
      final file = await DiagnosticsDirectory.file('controller_battery.log');
      final lines = await file.exists() ? await file.readAsLines() : <String>[];
      lines.add(line);
      final kept = lines.length > _logLines ? lines.sublist(lines.length - _logLines) : lines;
      await file.writeAsString('${kept.join('\n')}\n', flush: true);
    } catch (error) {
      _log.w('Controller battery log not written: $error');
    }
  }
}
