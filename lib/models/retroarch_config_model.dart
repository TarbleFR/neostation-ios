/// Represents the configuration and directory structure for a RetroArch installation.
///
/// Stores paths for critical RetroArch directories such as system (BIOS),
/// save files, and save states.
class RetroArchConfig {
  /// Unique identifier for the configuration entry in the local database.
  final int? id;

  /// Absolute filesystem path to the `retroarch.cfg` configuration file.
  final String configPath;

  /// Directory used for system-specific files such as BIOS and firmware.
  final String? systemDirectory;

  /// Directory where game save data (SRAM, Battery) is stored.
  final String? savefileDirectory;

  /// Directory where save state snapshots are stored.
  final String? savestateDirectory;

  const RetroArchConfig({
    this.id,
    required this.configPath,
    this.systemDirectory,
    this.savefileDirectory,
    this.savestateDirectory,
  });

  /// Creates a [RetroArchConfig] instance from a JSON-compatible map.
  factory RetroArchConfig.fromJson(Map<String, dynamic> json) {
    return RetroArchConfig(
      id: int.tryParse((json['id'] ?? '').toString()),
      configPath: (json['config_path'] ?? json['configPath'] ?? '').toString(),
      systemDirectory: (json['system_directory'] ?? json['systemDirectory'])
          ?.toString(),
      savefileDirectory:
          (json['savefile_directory'] ?? json['savefileDirectory'])?.toString(),
      savestateDirectory:
          (json['savestate_directory'] ?? json['savestateDirectory'])
              ?.toString(),
    );
  }

  /// Converts the configuration instance into a JSON-compatible map.
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'config_path': configPath,
      'system_directory': systemDirectory,
      'savefile_directory': savefileDirectory,
      'savestate_directory': savestateDirectory,
    };
  }

  /// Returns a copy of the configuration with the specified fields updated.
  RetroArchConfig copyWith({
    int? id,
    String? configPath,
    String? systemDirectory,
    String? savefileDirectory,
    String? savestateDirectory,
  }) {
    return RetroArchConfig(
      id: id ?? this.id,
      configPath: configPath ?? this.configPath,
      systemDirectory: systemDirectory ?? this.systemDirectory,
      savefileDirectory: savefileDirectory ?? this.savefileDirectory,
      savestateDirectory: savestateDirectory ?? this.savestateDirectory,
    );
  }

  @override
  String toString() {
    return 'RetroArchConfig(id: $id, path: $configPath, system: $systemDirectory, saves: $savefileDirectory, states: $savestateDirectory)';
  }
}
