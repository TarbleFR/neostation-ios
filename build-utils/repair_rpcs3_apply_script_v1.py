#!/usr/bin/env python3
from pathlib import Path

path = Path('build-utils/apply_rpcs3_internal_v1.py')
text = path.read_text()
old = "    '  static Future<bool> _canReadDataRoot(String dataRoot) async {',\n"
new = "    '  static Future<void> _replaceCache(List<Rpcs3LibraryGame> games) async {',\n"
count = text.count(old)
if count != 1:
    raise SystemExit(f'RPCS3 resolver end marker: expected one match, found {count}')
path.write_text(text.replace(old, new, 1))
