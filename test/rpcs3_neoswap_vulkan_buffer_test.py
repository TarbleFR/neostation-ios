"""Compile and execute the production imported-buffer header with fault-injected Vulkan calls."""
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = Path(sys.argv[1]).resolve()
compiler = shlex.split(os.environ.get('CXX', 'c++'))
if sdk := os.environ.get('HOST_MACOS_SDK'):
    compiler += ['-isysroot', sdk]
with tempfile.TemporaryDirectory(prefix='neoswap-vulkan-') as temp:
    exe = Path(temp) / 'buffer-test'
    subprocess.run([*compiler, '-std=c++20', '-O1', '-g', '-Wall', '-Wextra', '-Werror',
                    '-Wno-missing-field-initializers', '-Wno-misleading-indentation',
                    '-fsanitize=address,undefined', '-fno-omit-frame-pointer', '-I', str(source),
                    str(ROOT / 'test/native/rpcs3_neoswap_vulkan_buffer_test.cpp'), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True, timeout=60)
