#!/usr/bin/env python3
from pathlib import Path
import sys

root = Path(sys.argv[1]) if len(sys.argv) > 1 else None
if not root:
    raise SystemExit('usage: rpcs3_neostation_session_patch_test.py <rpcs3-source-root>')
cpp = (root / 'rpcs3/ios/RPCS3IOS.cpp').read_text()
exports = (root / 'rpcs3/ios/RPCS3IOS.exports').read_text()
audio = (root / 'rpcs3/Emu/Audio/IOS/IOSAudioBackend.cpp').read_text()
ppu_module = (root / 'rpcs3/Emu/Cell/PPUModule.cpp').read_text()

required = [
    'neostation_rpcs3_ios_save_state',
    'neostation_rpcs3_ios_enumerate_savestates_live',
    'available_process_memory_headroom()',
    'has_safe_savestate_headroom',
    'Emu.SetContinuousMode(true)',
    'Emu.Kill(false, true)',
]
for token in required:
    assert token in cpp, token
for token in [
    'source of truth for disc images',
    'const game_boot_result registration = Emu.AddGame(game->path)',
    'Could not register the installed disc source before boot',
]:
    assert token in cpp, token
assert cpp.index('source of truth for disc images') < cpp.index(
    'if (!requested_savestate_id.empty())'
)
for symbol in ['_neostation_rpcs3_ios_save_state', '_neostation_rpcs3_ios_enumerate_savestates_live']:
    assert symbol in exports.splitlines(), symbol
assert 'std::memset(output + written, 0, requested - written);' in audio
assert 'std::memcpy(output + offset, backend->m_last_frame.data(), bytes_per_frame);' not in audio
assert 'const u32 scan_end = std::min<u32>(end, ::size32(ls_segment));' in ppu_module
assert 'scan_end >= 16 && it < scan_end - 16' in ppu_module
assert 'it < end - 16' not in ppu_module
print('RPCS3 NeoStation session/audio patch contract: OK')
