"""One-shot source normalization loaded by the v3 bootstrap Python step."""
from pathlib import Path

root = Path(__file__).resolve().parent
service = root / 'lib/services/dolphin_internal_v2_service.dart'
if service.is_file():
    text = service.read_text(encoding='utf-8')
    old = """      await File(path.join(root.path, 'CrashMarkers', 'active-session.json'))
          .delete()
          .catchError((_) {});
"""
    new = """      await _deleteIfExists(
        File(path.join(root.path, 'CrashMarkers', 'active-session.json')),
      );
"""
    text = text.replace(old, new)
    service.write_text(text, encoding='utf-8')
Path(__file__).unlink(missing_ok=True)
