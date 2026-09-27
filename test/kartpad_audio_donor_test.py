#!/usr/bin/env python3
"""Execute the packaged donor's real Init guard before/after host cleanup."""
import argparse
from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile
from unicorn import Uc, UC_ARCH_ARM64, UC_MODE_ARM, UC_HOOK_CODE
from unicorn import arm64_const as arm

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'build-utils/kartpad'))
from patch_donor_language_bridge import parse_macho, load_symbols, vm_to_file
from patch_donor_session_bridge import (
    AUDIO_QUEUE, AUDIO_QUEUE_SIZE, AUDIO_QUEUE_SHIFT,
    AUDIO_QUEUE_ORIGINAL, AUDIO_QUEUE_CORRECTED, AUDIO_QUEUE_SHA,
)
import hashlib

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

# Execute the real donor's queue arithmetic across ASLR slides. The SDL call
# is replaced with an observed 4,000-byte queue, while every budgeting
# instruction runs unchanged. No UIKit/host mixer simulation is implied.
queue_offset = vm_to_file(segments, AUDIO_QUEUE)
queue = bytearray(data[queue_offset:queue_offset + AUDIO_QUEUE_SIZE])
assert symbols['__ZN12AudioBackend22QueueHasCapacityLockedEi'] == AUDIO_QUEUE
shift = AUDIO_QUEUE_SHIFT - AUDIO_QUEUE
assert struct.unpack_from('<I', queue, shift)[0] == AUDIO_QUEUE_CORRECTED
struct.pack_into('<I', queue, shift, AUDIO_QUEUE_ORIGINAL)
assert hashlib.sha256(queue).hexdigest() == AUDIO_QUEUE_SHA

for slide in (0, 0x4000, 0x400000000):
    for corrected, expected_limit in ((False, 7680), (True, 15360)):
        code = bytearray(queue)
        if corrected:
            struct.pack_into('<I', code, shift, AUDIO_QUEUE_CORRECTED)
        uc = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
        pc = AUDIO_QUEUE + slide
        uc.mem_map(pc & ~4095, 8192)
        uc.mem_write(pc, bytes(code))
        uc.mem_map(0x200000, 4096)
        uc.mem_map(0x300000, 4096)
        state = bytearray(256)
        struct.pack_into('<Q', state, 64, 0xDEADBEEF)
        struct.pack_into('<ii', state, 76, 32000, 2)
        uc.mem_write(0x200000, bytes(state))
        uc.reg_write(arm.UC_ARM64_REG_X0, 0x200000)
        uc.reg_write(arm.UC_ARM64_REG_W1, 384)
        uc.reg_write(arm.UC_ARM64_REG_SP, 0x301000)

        def queued_bytes(emulator, address, _size, _user):
            if address == pc + 0x28:  # SDL_GetAudioStreamQueued
                emulator.reg_write(arm.UC_ARM64_REG_X0, 4000)
                emulator.reg_write(arm.UC_ARM64_REG_PC, pc + 0x2C)

        uc.hook_add(UC_HOOK_CODE, queued_bytes)
        uc.emu_start(pc, pc + 0xA8, count=100)
        assert uc.reg_read(arm.UC_ARM64_REG_PC) == pc + 0xA8
        assert uc.reg_read(arm.UC_ARM64_REG_X21) == expected_limit

print('PASS: exact ARM64 queue limit increases from 60 to 120 ms at 32 kHz stereo (3 ASLR slides)')
