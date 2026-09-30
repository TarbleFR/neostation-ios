"""Input inspection never loads game code and rejects empty/wrong-platform IPAs."""
from pathlib import Path
import importlib.util
import json
import plistlib
import struct
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('pack_inspector', ROOT / 'build-utils/kartpad/inspect_personal_pack.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
pins = json.loads((ROOT / 'build-utils/kartpad/migration-target.json').read_text())


def fixture(abi=3, platform=2, symbol_type=0x0F, fingerprint=None):
    data = bytearray(1024)
    struct.pack_into('<8I', data, 0, 0xFEEDFACF, 0x0100000C, 0, 6, 3, 120, 0, 0)
    struct.pack_into('<2I16s4Q4I', data, 32, 0x19, 72, b'__DATA', 0x100000000, 1024, 0, 1024, 3, 3, 0, 0)
    struct.pack_into('<6I', data, 104, 0x32, 24, platform, 0, 0, 0)
    strings = b'\0_kartpad_game_pack_info\0'
    struct.pack_into('<6I', data, 128, 2, 24, 512, 1, 528, len(strings))
    struct.pack_into('<I', data, 256, abi)
    struct.pack_into('<IBBHQ', data, 512, 1, symbol_type, 1, 0, 0x100000100)
    data[528:528+len(strings)] = strings
    marker = b'kartpad-pack-fingerprint:' + (fingerprint or pins['pack_interface_fingerprint']).encode() + b'\0'
    data[600:600+len(marker)] = marker
    return bytes(data)


def rejected(call):
    try:
        call()
    except ValueError:
        return
    raise AssertionError('Invalid input was accepted')


assert module.inspect_macho(fixture(), pins)['pack_abi'] == 3
for kwargs in ({'abi': 2}, {'platform': 7}, {'platform': 1}, {'symbol_type': 1}, {'fingerprint': '0'*64}):
    rejected(lambda: module.inspect_macho(fixture(**kwargs), pins))
for damaged in (b'', fixture()[:40], fixture()[:520]):
    rejected(lambda: module.inspect_macho(damaged, pins))
with tempfile.TemporaryDirectory() as temporary:
    path = Path(temporary) / 'personal.ipa'
    for has_pack in (False, True):
        with zipfile.ZipFile(path, 'w') as archive:
            archive.writestr('Payload/KartPad.app/Info.plist', plistlib.dumps({'CFBundleShortVersionString': '0.7.3'}))
            if has_pack:
                archive.writestr('Payload/KartPad.app/Frameworks/libkartpad_game.dylib', fixture())
        before = path.read_bytes()
        if has_pack:
            result = module.inspect_ipa(path, pins)
            assert result['input_preflight_passed'] and not result['integration_validated']
        else:
            rejected(lambda: module.inspect_ipa(path, pins))
        assert path.read_bytes() == before
print('PASS: personal IPA read-only preflight, empty public IPA refusal, actual exported data ABI, exact fingerprint, platform and bounds')
