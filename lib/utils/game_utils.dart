/// Utility functions for game-related metadata processing and formatting.
class GameUtils {
  /// Sanitizes the game title for display.
  ///
  /// Currently returns the original name. Placeholder for future logic to remove
  /// tags like "(USA)", "[!]", or file extensions.
  static String formatGameName(String gameName) {
    if (gameName.isEmpty) return gameName;
    return gameName;
  }

  /// Converts a duration in seconds into a human-readable string.
  ///
  /// Formatting logic:
  /// - Less than 1 minute: Displays seconds only (e.g., "45s" or "45 seconds").
  /// - Less than 1 hour: Displays minutes only (e.g., "12m" or "12 minutes").
  /// - 1 hour or more: Displays hours only (e.g., "2h" or "2 hours").
  ///
  /// Set [fullWords] to true for localized labels.
  static String formatPlayTime(
    int seconds, {
    bool fullWords = false,
    String? hourLabel,
    String? hoursLabel,
    String? minuteLabel,
    String? minutesLabel,
    String? secondLabel,
    String? secondsLabel,
  }) {
    if (seconds <= 0) {
      return fullWords ? '0 ${secondsLabel ?? 'seconds'}' : '0s';
    }

    final duration = Duration(seconds: seconds);
    final hours = duration.inHours;
    final minutes = duration.inMinutes;

    if (hours > 0) {
      if (fullWords) {
        return '$hours ${hours == 1 ? (hourLabel ?? 'hour') : (hoursLabel ?? 'hours')}';
      }
      return '${hours}h';
    } else if (minutes > 0) {
      if (fullWords) {
        return '$minutes ${minutes == 1 ? (minuteLabel ?? 'minute') : (minutesLabel ?? 'minutes')}';
      }
      return '${minutes}m';
    } else {
      if (fullWords) {
        return '$seconds ${seconds == 1 ? (secondLabel ?? 'second') : (secondsLabel ?? 'seconds')}';
      }
      return '${seconds}s';
    }
  }

  /// Sanitizes game descriptions by unescaping common HTML entities and converting line breaks.
  static String cleanupDescription(String description) {
    if (description.isEmpty) return description;

    return description
        .replaceAll('&quot;', '"')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&apos;', "'")
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&#39;', "'")
        .replaceAll(RegExp(r'<br\s*/?>'), '\n');
  }
}
