/// Connection type detected for the gamepad
enum GamepadConnectionType {
  usb('USB'),
  wireless('Wireless'),
  bluetooth('Bluetooth'),
  unknown('Unknown');

  const GamepadConnectionType(this.displayName);
  final String displayName;
}

/// Extended information about a gamepad device
class GamepadDeviceInfo {
  /// The connection type (USB, Wireless, Bluetooth, Unknown)
  final GamepadConnectionType connectionType;

  /// The driver being used (xinput, directinput, etc.)
  final String? driver;

  /// Vendor ID (VID) if available
  final String? vendorId;

  /// Product ID (PID) if available
  final String? productId;

  /// Device instance path (Windows specific)
  final String? devicePath;

  /// Hardware ID information
  final String? hardwareId;

  /// Number of buttons reported by the device
  final int? buttonCount;

  /// Number of axes reported by the device
  final int? axisCount;

  /// Additional platform-specific capabilities
  final Map<String, dynamic> capabilities;

  const GamepadDeviceInfo({
    this.connectionType = GamepadConnectionType.unknown,
    this.driver,
    this.vendorId,
    this.productId,
    this.devicePath,
    this.hardwareId,
    this.buttonCount,
    this.axisCount,
    this.capabilities = const {},
  });

  factory GamepadDeviceInfo.fromMap(Map<String, dynamic> map) {
    return GamepadDeviceInfo(
      connectionType: _parseConnectionType(map['connectionType']),
      driver: map['driver'],
      vendorId: map['vendorId'],
      productId: map['productId'],
      devicePath: map['devicePath'],
      hardwareId: map['hardwareId'],
      buttonCount: map['buttonCount'],
      axisCount: map['axisCount'],
      capabilities: Map<String, dynamic>.from(map['capabilities'] ?? {}),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'connectionType': connectionType.name,
      'driver': driver,
      'vendorId': vendorId,
      'productId': productId,
      'devicePath': devicePath,
      'hardwareId': hardwareId,
      'buttonCount': buttonCount,
      'axisCount': axisCount,
      'capabilities': capabilities,
    };
  }

  static GamepadConnectionType _parseConnectionType(String? type) {
    if (type == null) return GamepadConnectionType.unknown;

    switch (type.toLowerCase()) {
      case 'usb':
        return GamepadConnectionType.usb;
      case 'wireless':
        return GamepadConnectionType.wireless;
      case 'bluetooth':
        return GamepadConnectionType.bluetooth;
      default:
        return GamepadConnectionType.unknown;
    }
  }

  @override
  String toString() {
    return 'GamepadDeviceInfo(connectionType: $connectionType, driver: $driver, '
        'vendorId: $vendorId, productId: $productId, buttonCount: $buttonCount, '
        'axisCount: $axisCount)';
  }
}
