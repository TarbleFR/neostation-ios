"""Test-only donor embedding for the Flutter/XCTest simulator fixture."""
import os
import shutil
import struct
import subprocess
from pathlib import Path

root = Path(os.environ['GITHUB_WORKSPACE'])
app = Path(os.environ['TARGET_BUILD_DIR']) / os.environ['WRAPPER_NAME']
framework = app / 'Frameworks/KartPadRuntime.framework'
shutil.copytree(root / 'donor/KartPadRuntime.framework', framework, dirs_exist_ok=True)
shutil.copytree(root / 'donor/runtime-resources', app, dirs_exist_ok=True)
path = framework / 'KartPadRuntime'
data = bytearray(path.read_bytes())
cursor = 32
count = 0
for _ in range(struct.unpack_from('<I', data, 16)[0]):
    command, size = struct.unpack_from('<II', data, cursor)
    if command == 0x32:
        assert struct.unpack_from('<I', data, cursor + 8)[0] == 2
        struct.pack_into('<I', data, cursor + 8, 7)
        count += 1
    cursor += size
assert count == 1
path.write_bytes(data)
subprocess.run(['codesign', '--force', '--sign', '-', str(framework)], check=True)
