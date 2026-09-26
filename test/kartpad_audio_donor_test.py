#!/usr/bin/env python3
"""Execute the packaged donor's real Init guard before/after host cleanup."""
import argparse
from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile
from unicorn import Uc, UC_ARCH_ARM64, UC_MODE_ARM
from unicorn import arm64_const as arm

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'build-utils/kartpad'))
from patch_donor_language_bridge import parse_macho, load_symbols, vm_to_file

parser = argparse.ArgumentParser()
parser.add_argument('--runtime', type=Path, required=True)
args = parser.parse_args()
data = args.runtime.read_bytes()
segments, table = parse_macho(data)
symbols, _ = load_symbols(data, table)
start = symbols['__ZN12AudioBackend23EnsureInitializedLockedEjj']
header = (ROOT / 'native/kartpad/core/DonorAudioSession.h').read_text()
literal = header.split('kDonorAudioLayoutWitness[] = {', 1)[1].split('};', 1)[0]
witness = bytes(int(x, 16) for x in re.findall(r'0x([0-9a-f]{2})', literal))
offset = vm_to_file(segments, start)
assert data[offset:offset + len(witness)] == witness, 'donor audio layout drift'

with tempfile.TemporaryDirectory() as tmp:
    exe = str(Path(tmp) / 'audio-test')
    subprocess.run(['c++', '-std=c++20', '-Wall', '-Wextra', '-Werror',
                    '-I' + str(ROOT / 'native/kartpad/core'),
                    str(ROOT / 'test/kartpad_audio_session_test.cpp'), '-o', exe], check=True)
    cleaned = subprocess.check_output([exe, '--dump'])
    subprocess.run([exe], check=True)

for slide in (0, 0x4000, 0x400000000):
    for is_clean in (False, True):
        uc = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
        pc = start + slide
        uc.mem_map(pc & ~4095, 8192)
        uc.mem_write(pc, witness)
        uc.mem_map(0x200000, 8192)
        uc.mem_map(0x300000, 8192)
        state = bytearray(cleaned)
        if not is_clean:
            struct.pack_into('<Q', state, 0x40, 0xdeadbeef)  # SDL_Quit freed it
            struct.pack_into('<II', state, 0x54, 32000, 2)
            state[0x5c] = 1
        uc.mem_write(0x200000, bytes(state))
        uc.reg_write(arm.UC_ARM64_REG_X0, 0x200000)
        uc.reg_write(arm.UC_ARM64_REG_W1, 32000)
        uc.reg_write(arm.UC_ARM64_REG_W2, 2)
        uc.reg_write(arm.UC_ARM64_REG_SP, 0x301000)
        # Stop at either branch destination, before any SDL calls.
        dest = pc + (0x44 if is_clean else 0x1a0)
        uc.emu_start(pc, dest, count=30)
        assert uc.reg_read(arm.UC_ARM64_REG_PC) == dest
print('PASS: actual ARM64 Init reuses a stale stream before cleanup; reinitializes after cleanup (3 ASLR slides)')
