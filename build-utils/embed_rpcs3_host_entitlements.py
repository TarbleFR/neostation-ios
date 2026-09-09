#!/usr/bin/env python3
"""Carry RPCS3 capabilities inside Runner for the user's sideload signer.

CODE_SIGNING_ALLOWED=NO does not embed CODE_SIGN_ENTITLEMENTS. A plist beside
an IPA is invisible to signers that discover capabilities from its executable.
An ad-hoc signature carries those capabilities; installation still requires
the user's own provisioning/signing. No Apple certificate is used here.
"""
from __future__ import annotations

import plistlib
import struct
import subprocess
from pathlib import Path

from configure_rpcs3_ios_v2 import REQUIRED_RUNTIME_ENTITLEMENTS

ROOT = Path(__file__).resolve().parents[1]
PRODUCTS = ROOT / 'build/ios/DolphinDerivedData/Build/Products/Release-iphoneos'


def embedded_entitlements(data: bytes) -> dict:
    """Read the XML entitlement slot from the actual Mach-O code signature."""
    if data[:4] in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
        wide = data[:4] == b'\xca\xfe\xba\xbf'
        count = struct.unpack_from('>I', data, 4)[0]
        stride = 32 if wide else 20
        if not 0 < count <= 32 or 8 + count * stride > len(data):
            raise ValueError('Invalid Mach-O architecture table')
        for index in range(count):
            position = 8 + index * stride
            if struct.unpack_from('>I', data, position)[0] == 0x0100000C:
                offset, size = struct.unpack_from('>QQ' if wide else '>II', data, position + 8)
                if offset + size > len(data):
                    raise ValueError('Truncated arm64 image')
                return embedded_entitlements(data[offset:offset + size])
        raise ValueError('No arm64 image')
    if len(data) < 32 or data[:4] != b'\xcf\xfa\xed\xfe':
        raise ValueError('Expected a 64-bit Mach-O executable')
    count, command_bytes = struct.unpack_from('<II', data, 16)
    end = 32 + command_bytes
    if end > len(data) or count > 65536:
        raise ValueError('Truncated Mach-O load commands')
    position = 32
    for _ in range(count):
        if position + 8 > end:
            raise ValueError('Truncated Mach-O load command')
        command, size = struct.unpack_from('<II', data, position)
        if size < 8 or position + size > end:
            raise ValueError('Invalid Mach-O load command size')
        if command == 0x1D:  # LC_CODE_SIGNATURE
            if size < 16:
                raise ValueError('Truncated signature command')
            offset, length = struct.unpack_from('<II', data, position + 8)
            if length < 12 or offset + length > len(data):
                raise ValueError('Truncated code signature')
            blob = data[offset:offset + length]
            magic, total, slots = struct.unpack_from('>III', blob)
            if magic != 0xFADE0CC0 or total > len(blob) or 12 + slots * 8 > total:
                raise ValueError('Invalid code-signature superblob')
            for index in range(slots):
                kind, start = struct.unpack_from('>II', blob, 12 + index * 8)
                if kind != 5:  # CSSLOT_ENTITLEMENTS
                    continue
                if start < 12 + slots * 8 or start + 8 > total:
                    raise ValueError('Invalid entitlement slot')
                tag, length = struct.unpack_from('>II', blob, start)
                if tag != 0xFADE7171 or length < 8 or start + length > total:
                    raise ValueError('Truncated entitlement data')
                payload = plistlib.loads(blob[start + 8:start + length])
                if not isinstance(payload, dict):
                    raise ValueError('Entitlements must be a dictionary')
                return payload
            return {}
        position += size
    return {}


def require_runtime_entitlements(payload: dict) -> None:
    missing = [key for key in REQUIRED_RUNTIME_ENTITLEMENTS if payload.get(key) is not True]
    if missing:
        raise ValueError('Runner executable is missing RPCS3 entitlements: ' + ', '.join(missing))


def embed(executable: Path, entitlements: Path) -> dict:
    expected = plistlib.loads(entitlements.read_bytes())
    require_runtime_entitlements(expected)
    subprocess.run([
        'codesign', '--force', '--sign', '-', '--timestamp=none',
        '--generate-entitlement-der', '--entitlements', str(entitlements),
        str(executable),
    ], check=True)
    subprocess.run(['codesign', '--verify', '--strict', str(executable)], check=True)
    actual = embedded_entitlements(executable.read_bytes())
    require_runtime_entitlements(actual)
    if any(actual.get(key) != value for key, value in expected.items()):
        raise ValueError('Ad-hoc signing lost existing host capabilities')
    return actual


def main() -> None:
    apps = list(PRODUCTS.glob('*.app'))
    if len(apps) != 1:
        raise SystemExit('Expected one built NeoStation app')
    app = apps[0]
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    executable = app / info['CFBundleExecutable']
    embed(executable, ROOT / 'ios/Runner/Runner.entitlements')
    print('RPCS3 entitlements verified INSIDE Runner; user sideload signing is still required.')


if __name__ == '__main__':
    main()
