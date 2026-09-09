#!/usr/bin/env python3
"""Repair the one-shot RPCS3 migration before applying it.

The previous migration used two overly broad replacement ranges. This script
narrows them without modifying any Dolphin source.
"""
from pathlib import Path

finalize = Path('build-utils/finalize_rpcs3_internal_v1.py')
text = finalize.read_text()

old = """    '  static Future<String?> _resolveLinkedDataRoot() async {',
    '  static Future<bool> _canReadDataRoot(String dataRoot) async {',
"""
new = """    '  static Future<String?> _resolveLinkedDataRoot() async {',
    '  static Future<void> _replaceCache(List<Rpcs3LibraryGame> games) async {',
"""
if old not in text:
    raise SystemExit('RPCS3 library resolver migration anchor not found')
text = text.replace(old, new, 1)

old = """        '  List<Widget> _iosEmulatorCards(ThemeData theme) {',
        'RPCS3 directory actions',
"""
new = """        '',
        'RPCS3 directory actions',
"""
if old not in text:
    raise SystemExit('RPCS3 directory-action migration anchor not found')
text = text.replace(old, new, 1)

old = """        '  Widget _buildIOSArmsx2Section(ThemeData theme) {',
        'RPCS3 directory card',
"""
new = """        '',
        'RPCS3 directory card',
"""
if old not in text:
    raise SystemExit('RPCS3 directory-card migration anchor not found')
text = text.replace(old, new, 1)
finalize.write_text(text)

# The project uses the static file_picker API (the pinned beta removed
# FilePicker.platform). Keep RPCS3 consistent with every other iOS importer.
service = Path('lib/services/rpcs3_internal_service.dart')
service_text = service.read_text()
service_text = service_text.replace('FilePicker.platform.pickFiles(', 'FilePicker.pickFiles(')
service_text = service_text.replace('FilePicker.platform.getDirectoryPath(', 'FilePicker.getDirectoryPath(')
if 'FilePicker.platform' in service_text:
    raise SystemExit('Unsupported FilePicker.platform API remains in RPCS3 service')
service.write_text(service_text)

print('RPCS3 migration ranges and file picker API repaired.')
