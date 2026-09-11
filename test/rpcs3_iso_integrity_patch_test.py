#!/usr/bin/env python3
from pathlib import Path
import sys


root = Path(sys.argv[1]) if len(sys.argv) > 1 else None
if not root:
    raise SystemExit('usage: rpcs3_iso_integrity_patch_test.py <rpcs3-source-root>')

cpp = (root / 'rpcs3/ios/GameLibrary.cpp').read_text()
header = (root / 'rpcs3/ios/GameLibrary.h').read_text()
api = (root / 'rpcs3/ios/RPCS3IOS.cpp').read_text()

for token in [
    'NeoStation ISO extent integrity',
    'validate_iso_node_extents',
    'extent.start * ISO_SECTOR_SIZE',
    'extent.size > image_size - byte_offset',
    'destination.sync();',
    'destination.size() == source.size()',
    'The selected image is truncated or corrupt',
    'const std::string previous_directory = root + ".replace-" + title_id',
]:
    assert token in cpp, token

assert 'validate_installed_game_iso' in cpp
assert 'validate_installed_game_iso' in header
assert 'Installed disc image is incomplete or corrupt' in api
assert 'Re-import this title from a complete ISO' in api
print('RPCS3 ISO extent-integrity patch contract: OK')
