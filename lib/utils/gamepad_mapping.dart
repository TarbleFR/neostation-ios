import 'dart:io';

/// Supported physical connection types for gamepad devices.
enum GamepadConnectionType {
  bluetooth('Bluetooth'),
  wireless('Wireless'),
  usb('USB'),
  unknown('Unknown');

  const GamepadConnectionType(this.displayName);

  /// User-friendly name for the connection type.
  final String displayName;
}

/// Defines a translation map between hardware-specific keys and logical inputs.
class GamepadMapping {
  /// The connection type this mapping is optimized for.
  final GamepadConnectionType connectionType;

  /// The target operating system platform.
  final String platform;

  /// Maps logical D-pad directions (up, down, etc.) to hardware values.
  final Map<String, double> dpadMapping;

  /// Maps logical button labels (A, B, etc.) to hardware key identifiers.
  final Map<String, String> buttonMapping;

  /// Maps logical analog axes (LS_X, LS_Y, etc.) to hardware axis identifiers.
  final Map<String, String> analogMapping;

  const GamepadMapping({
    required this.connectionType,
    required this.platform,
    required this.dpadMapping,
    required this.buttonMapping,
    required this.analogMapping,
  });
}

/// Service responsible for detecting and providing the appropriate [GamepadMapping] for a device.
class GamepadMappingDetector {
  static final GamepadMappingDetector _instance =
      GamepadMappingDetector._internal();

  factory GamepadMappingDetector() => _instance;

  GamepadMappingDetector._internal();

  /// Cache of detected mappings per gamepad ID to avoid redundant detection logic.
  final Map<String, GamepadMapping> _mappingCache = {};

  /// Statistical tracker for button events, useful for debugging or profile fine-tuning.
  final Map<String, Map<String, int>> _buttonEventCounts = {};

  /// Retrieves the optimal [GamepadMapping] for the given gamepad.
  ///
  /// Uses [systemInfo] (e.g., VID/PID) to refine the detection process.
  GamepadMapping getMappingForGamepad(
    String gamepadId,
    String gamepadName, [
    Map<String, dynamic>? systemInfo,
  ]) {
    if (_mappingCache.containsKey(gamepadId)) {
      return _mappingCache[gamepadId]!;
    }

    final mapping = _detectMapping(gamepadId, gamepadName, systemInfo);
    _mappingCache[gamepadId] = mapping;

    return mapping;
  }

  /// Internal logic to branch detection based on the current platform.
  GamepadMapping _detectMapping(
    String gamepadId,
    String gamepadName, [
    Map<String, dynamic>? systemInfo,
  ]) {
    if (Platform.isWindows) {
      return _detectWindowsMapping(gamepadId, gamepadName, systemInfo);
    } else if (Platform.isLinux) {
      return _detectLinuxMapping(gamepadId, gamepadName, systemInfo);
    } else if (Platform.isAndroid) {
      return _detectAndroidMapping(gamepadId, gamepadName, systemInfo);
    } else {
      return _getDefaultMapping();
    }
  }

  /// Specialized detection for Windows, considering Bluetooth and Wireless/XInput protocols.
  GamepadMapping _detectWindowsMapping(
    String gamepadId,
    String gamepadName, [
    Map<String, dynamic>? systemInfo,
  ]) {
    if (systemInfo != null) {
      String? connectionType = systemInfo['connectionType'];
      if (connectionType == 'bluetooth') {
        return _getWindowsBluetoothMapping();
      } else if (connectionType == 'usb' || connectionType == 'wireless') {
        return _getWindowsWirelessMapping();
      }

      int? buttonCount = systemInfo['buttonCount'];
      if (buttonCount != null) {
        // Bluetooth modes often report higher button counts for special functions.
        if (buttonCount > 10) {
          return _getWindowsBluetoothMapping();
        } else {
          return _getWindowsWirelessMapping();
        }
      }
    }

    return _getWindowsWirelessMapping();
  }

  /// Specialized detection for Linux, handling driver-specific naming conventions.
  GamepadMapping _detectLinuxMapping(
    String gamepadId,
    String gamepadName, [
    Map<String, dynamic>? systemInfo,
  ]) {
    if (systemInfo != null) {
      String? connectionType = systemInfo['connectionType'];
      if (connectionType == 'bluetooth') {
        return _getLinuxBluetoothMapping();
      } else if (connectionType == 'usb' || connectionType == 'wireless') {
        return _getLinuxWirelessMapping();
      }
    }

    // Heuristics based on device name if systemInfo is incomplete.
    if (gamepadId.contains('js1') ||
        gamepadName.toLowerCase().contains('xbox')) {
      return _getLinuxBluetoothMapping();
    } else if (gamepadName.toLowerCase().contains('8bitdo')) {
      return _getLinuxWirelessMapping();
    }

    return _getLinuxWirelessMapping();
  }

  /// Specialized detection for Android.
  GamepadMapping _detectAndroidMapping(
    String gamepadId,
    String gamepadName, [
    Map<String, dynamic>? systemInfo,
  ]) {
    return _getAndroidMapping();
  }

  /// Configuration for Windows controllers connected via Bluetooth.
  GamepadMapping _getWindowsBluetoothMapping() {
    return const GamepadMapping(
      connectionType: GamepadConnectionType.bluetooth,
      platform: 'windows',
      dpadMapping: {
        'up': 0.0,
        'down': 18000.0,
        'left': 27000.0,
        'right': 9000.0,
      },
      buttonMapping: {
        'A': 'button-0',
        'B': 'button-1',
        'X': 'button-3',
        'Y': 'button-4',
        'LB': 'button-6',
        'RB': 'button-7',
        'LT': 'button-8',
        'RT': 'button-9',
        'SELECT': 'button-10',
        'START': 'button-11',
        'LS_PRESS': 'button-13',
        'RS_PRESS': 'button-14',
      },
      analogMapping: {
        'LS_X': 'dwxpos',
        'LS_Y': 'dwypos',
        'RS_X': 'dwrpos',
        'RS_Y': 'dwzpos',
      },
    );
  }

  /// Configuration for Windows controllers using Wireless/XInput protocols.
  GamepadMapping _getWindowsWirelessMapping() {
    return const GamepadMapping(
      connectionType: GamepadConnectionType.wireless,
      platform: 'windows',
      dpadMapping: {
        'up': 0.0,
        'down': 18000.0,
        'left': 27000.0,
        'right': 9000.0,
      },
      buttonMapping: {
        'A': 'button-0',
        'B': 'button-1',
        'X': 'button-2',
        'Y': 'button-3',
        'LB': 'button-4',
        'RB': 'button-5',
        'SELECT': 'button-6',
        'START': 'button-7',
        'LS_PRESS': 'button-8',
        'RT': 'button-9', // RT reported as digital in some wireless modes.
      },
      analogMapping: {
        'LS_X': 'dwxpos',
        'LS_Y': 'dwypos',
        'RS_X': 'dwrpos',
        'RS_Y': 'dwzpos',
        'LT': 'dwzpos', // LT shared with RT or reported as separate axis.
      },
    );
  }

  /// Configuration for standard Linux controllers connected via Wireless/USB.
  GamepadMapping _getLinuxWirelessMapping() {
    return const GamepadMapping(
      connectionType: GamepadConnectionType.wireless,
      platform: 'linux',
      dpadMapping: {
        'up': -32767.0, // axis 7
        'down': 32767.0, // axis 7
        'left': -32767.0, // axis 6
        'right': 32767.0, // axis 6
      },
      buttonMapping: {
        'A': '0',
        'B': '1',
        'X': '2',
        'Y': '3',
        'LB': '4',
        'RB': '5',
        'SELECT': '6',
        'START': '7',
        'LS_PRESS': '9',
        'RS_PRESS': '10',
      },
      analogMapping: {
        'LS_X': '0',
        'LS_Y': '1',
        'RS_X': '3',
        'RS_Y': '4',
        'LT': '2',
        'RT': '5',
      },
    );
  }

  /// Configuration for Linux controllers connected via Bluetooth.
  GamepadMapping _getLinuxBluetoothMapping() {
    return const GamepadMapping(
      connectionType: GamepadConnectionType.bluetooth,
      platform: 'linux',
      dpadMapping: {
        'up': -32767.0, // axis 7
        'down': 32767.0, // axis 7
        'left': -32767.0, // axis 6
        'right': 32767.0, // axis 6
      },
      buttonMapping: {
        'A': '0',
        'B': '1',
        'X': '3',
        'Y': '4',
        'LB': '6',
        'RB': '7',
        'SELECT': '10',
        'START': '11',
        'LS_PRESS': '13',
        'RS_PRESS': '14',
      },
      analogMapping: {
        'LS_X': '0',
        'LS_Y': '1',
        'RS_X': '2',
        'RS_Y': '3',
        'LT': '5',
        'RT': '4',
      },
    );
  }

  /// Configuration for standard Android gamepad implementations.
  GamepadMapping _getAndroidMapping() {
    return const GamepadMapping(
      connectionType: GamepadConnectionType.usb,
      platform: 'android',
      dpadMapping: {
        'up': 1.0, // axis_hat_y
        'down': -1.0, // axis_hat_y
        'left': -1.0, // axis_hat_x
        'right': 1.0, // axis_hat_x
      },
      buttonMapping: {
        'A': 'keycode_button_a',
        'B': 'keycode_button_b',
        'X': 'keycode_button_x',
        'Y': 'keycode_button_y',
        'LB': 'keycode_button_l1',
        'RB': 'keycode_button_r1',
        'SELECT': 'keycode_button_select',
        'START': 'keycode_button_start',
      },
      analogMapping: {
        'LS_X': 'axis_x',
        'LS_Y': 'axis_y',
        'RS_X': 'axis_z',
        'RS_Y': 'axis_rz',
        'LT': 'keycode_button_l2',
        'RT': 'keycode_button_r2',
      },
    );
  }

  /// Fallback empty mapping for unrecognized platforms or devices.
  GamepadMapping _getDefaultMapping() {
    return const GamepadMapping(
      connectionType: GamepadConnectionType.unknown,
      platform: 'unknown',
      dpadMapping: {},
      buttonMapping: {},
      analogMapping: {},
    );
  }

  /// Checks if a button event matches the logical button for the current mapping.
  bool isButtonMatch(
    GamepadMapping mapping,
    String logicalButton,
    String eventKey,
    double eventValue,
  ) {
    final mappedKey = mapping.buttonMapping[logicalButton];
    if (mappedKey == null) return false;

    return eventKey == mappedKey && eventValue > 0.5;
  }

  /// Checks if a D-pad event matches the logical direction for the current mapping.
  bool isDpadMatch(
    GamepadMapping mapping,
    String logicalDirection,
    String eventKey,
    double eventValue,
  ) {
    if (Platform.isWindows && eventKey == 'pov') {
      final mappedValue = mapping.dpadMapping[logicalDirection];
      return mappedValue != null && eventValue == mappedValue;
    }

    if (Platform.isAndroid) {
      if (logicalDirection == 'up' || logicalDirection == 'down') {
        if (eventKey == 'axis_hat_y') {
          final mappedValue = mapping.dpadMapping[logicalDirection];
          return mappedValue != null && eventValue == mappedValue;
        }
      } else if (logicalDirection == 'left' || logicalDirection == 'right') {
        if (eventKey == 'axis_hat_x') {
          final mappedValue = mapping.dpadMapping[logicalDirection];
          return mappedValue != null && eventValue == mappedValue;
        }
      }
    }

    if (Platform.isLinux) {
      if (logicalDirection == 'up' || logicalDirection == 'down') {
        if (eventKey == 'axis_7' || eventKey == '7') {
          final mappedValue = mapping.dpadMapping[logicalDirection];
          return mappedValue != null && eventValue == mappedValue;
        }
      } else if (logicalDirection == 'left' || logicalDirection == 'right') {
        if (eventKey == 'axis_6' || eventKey == '6') {
          final mappedValue = mapping.dpadMapping[logicalDirection];
          return mappedValue != null && eventValue == mappedValue;
        }
      }
    }

    return false;
  }

  /// Clears internal mapping and statistical caches.
  void clearCache() {
    _mappingCache.clear();
    _buttonEventCounts.clear();
  }

  /// Generates a debug string containing current mapping state and statistics.
  String getDebugInfo(String gamepadId) {
    final mapping = _mappingCache[gamepadId];
    if (mapping == null) return 'No mapping found for gamepad $gamepadId';

    final buffer = StringBuffer();
    buffer.writeln('Gamepad Mapping Debug Info for ID: $gamepadId');
    buffer.writeln('Connection Type: ${mapping.connectionType.displayName}');
    buffer.writeln('Platform: ${mapping.platform}');
    buffer.writeln(
      'Button Events Counted: ${_buttonEventCounts[gamepadId] ?? {}}',
    );

    return buffer.toString();
  }
}
