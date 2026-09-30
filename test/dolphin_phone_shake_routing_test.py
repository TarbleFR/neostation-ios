#!/usr/bin/env python3
"""Execute phone binding policy everywhere and the Objective-C++ donor shim on macOS."""
from pathlib import Path
import platform
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[1]
TOUCH=ROOT/'packages/dolphin_internal_bridge/ios/Classes/TouchController'
with tempfile.TemporaryDirectory() as folder:
    binary=Path(folder)/'motion-binding'
    subprocess.run(['c++','-std=c++17',str(ROOT/'test/dolphin_phone_shake_binding_test.cpp'),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
    if platform.system() == 'Darwin':
        binary=Path(folder)/'motion-routing'
        subprocess.run(['clang++','-std=c++17','-fobjc-arc','-framework','Foundation',
                        str(TOUCH/'DolphinPhoneShakeRouting.mm'),str(ROOT/'test/dolphin_phone_shake_routing_test.mm'),
                        '-o',str(binary)],check=True)
        subprocess.run([str(binary)],check=True)
    else:
        print('SKIP: production Objective-C++ routing execution requires macOS Foundation')
