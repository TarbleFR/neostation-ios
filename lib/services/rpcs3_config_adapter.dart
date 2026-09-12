/// Minimal adapter for the small YAML subset used by RPCS3's configuration DB.
///
/// Database documents are maps (at most three levels deep) with scalar or list
/// leaves.  Editing lines in place preserves upstream values and lists while
/// avoiding a second YAML serialization dependency in the launch path.
abstract final class Rpcs3ConfigAdapter {
  static String sanitiseForIOS(String source) {
    final output = <String>[];
    for (final line in source.split('\n')) {
      final separator = line.indexOf(':');
      if (separator < 0) {
        output.add(line);
        continue;
      }
      final key = line.substring(0, separator).trim().replaceFirst('- ', '');
      final value = line.substring(separator + 1).trim();
      if (key == 'Renderer' && value == 'OpenGL') continue;
      if (key == 'Frame limit' && (value == 'Off' || value == 'Infinite')) {
        continue;
      }
      output.add(line);
    }
    return '${output.join('\n').trim()}\n';
  }

  static String mergeScalarOverrides(
    String source,
    Map<List<String>, String> overrides,
  ) {
    var result = sanitiseForIOS(source);
    for (final entry in overrides.entries) {
      if (entry.key.isEmpty) continue;
      result = _setScalar(result, entry.key, entry.value);
    }
    return result;
  }

  static bool hasUsefulSetting(String source) {
    for (final line in source.split('\n')) {
      final separator = line.indexOf(':');
      if (separator >= 0 && line.substring(separator + 1).trim().isNotEmpty) {
        return true;
      }
      if (line.trimLeft().startsWith('- ')) return true;
    }
    return false;
  }

  static String _setScalar(String source, List<String> path, String value) {
    final trimmed = source.trimRight();
    final lines = trimmed.isEmpty ? <String>[] : trimmed.split('\n');
    var rangeStart = 0;
    var rangeEnd = lines.length;

    for (var depth = 0; depth < path.length; depth++) {
      final indent = depth * 2;
      final prefix = '${' ' * indent}${path[depth]}:';
      var found = -1;
      for (var index = rangeStart; index < rangeEnd; index++) {
        if (lines[index].startsWith(prefix)) {
          final remainder = lines[index].substring(prefix.length);
          if (remainder.isNotEmpty && !remainder.startsWith(' ')) continue;
          found = index;
          break;
        }
      }

      final isLeaf = depth == path.length - 1;
      if (found >= 0) {
        if (isLeaf) {
          lines[found] = '$prefix $value';
          return '${lines.join('\n')}\n';
        }
        rangeStart = found + 1;
        rangeEnd = _subtreeEnd(lines, rangeStart, indent);
        continue;
      }

      final inserted = <String>[];
      for (var remaining = depth; remaining < path.length; remaining++) {
        final childIndent = remaining * 2;
        final childPrefix = '${' ' * childIndent}${path[remaining]}:';
        inserted.add(
          remaining == path.length - 1
              ? '$childPrefix $value'
              : childPrefix,
        );
      }
      lines.insertAll(rangeEnd, inserted);
      return '${lines.join('\n')}\n';
    }
    return '${lines.join('\n')}\n';
  }

  static int _subtreeEnd(List<String> lines, int start, int parentIndent) {
    for (var index = start; index < lines.length; index++) {
      final line = lines[index];
      if (line.trim().isEmpty) continue;
      final indent = line.length - line.trimLeft().length;
      if (indent <= parentIndent) return index;
    }
    return lines.length;
  }
}
