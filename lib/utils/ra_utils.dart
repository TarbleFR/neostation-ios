/// Utility functions for parsing RetroAchievements API responses.
class RAParsingUtils {
  /// Robustly converts a dynamic [value] to an [int].
  ///
  /// Handles nulls, booleans, doubles, and string representations.
  static int toInt(dynamic value) {
    if (value == null) return 0;
    if (value is int) return value;
    if (value is bool) return value ? 1 : 0;
    if (value is double) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }

  /// Robustly converts a dynamic [value] to a [bool].
  ///
  /// Interprets `0` or `"false"` as false, and non-zero or `"true"` as true.
  static bool toBool(dynamic value) {
    if (value == null) return false;
    if (value is bool) return value;
    if (value is int) return value != 0;
    if (value is String) return value == '1' || value.toLowerCase() == 'true';
    return false;
  }
}
