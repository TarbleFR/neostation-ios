#!/usr/bin/env python3
"""Execute the production storage client and SHA key plus its exported setter.

The module-creation callback is injected. This does not simulate GPU execution.
The mandatory full Core build compiles the actual Vulkan consumer afterwards.
"""
import hashlib
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile

source=Path(sys.argv[1]).resolve()
root=Path(__file__).resolve().parents[1]
compiler=shlex.split(os.environ.get('CXX','c++'))
if sdk:=os.environ.get('HOST_MACOS_SDK'): compiler+=['-isysroot',sdk]
env=dict(os.environ);env.pop('SDKROOT',None)
headers=('StorageABI.h','Client.h','ShaderKey.h')
for name in headers:
    assert (source/'rpcs3/ios/NeoSwapStorage'/name).read_bytes()==(root/'native/neoswap-storage'/name).read_bytes(),name
cpp=(source/'rpcs3/Emu/RSX/VK/VKProgramPipeline.cpp').read_text()
compile_body=cpp.split('VkShaderModule shader::compile()',1)[1].split('void shader::destroy()',1)[0]
assert 'neostation::storage_client::compile(' in compile_body
assert 'vkCreateShaderModule(*g_render_device' in compile_body
assert 'VK_ERROR_OUT_OF_HOST_MEMORY' not in compile_body # fatal is default, no OOM retry
assert 'source_failure' in compile_body and 'module_failure' in compile_body
assert 'store_' not in cpp and 'fsync(' not in cpp and 'wait_for(' not in cpp
spirv=(source/'rpcs3/Emu/RSX/Program/SPIRVCommon.cpp').read_text()
for contract in ('EShTargetVulkan_1_2','EShTargetSpv_1_5','options.disableOptimizer = true','options.optimizeSize = true'):
    assert contract in spirv,contract
expected=hashlib.sha256(b'NS-SPV1\0'+(2).to_bytes(4,'little')+b'\0\5\1\0'+b'test shader').hexdigest()
with tempfile.TemporaryDirectory(prefix='rpcs3-storage-client-') as temp:
    out=Path(temp);(out/'util').mkdir()
    (out/'util/types.hpp').write_text('#pragma once\n#include <cstddef>\n#include <cstdint>\n#include <string>\nusing u8=uint8_t;using s64=int64_t;using usz=size_t;\n')
    test=(root/'test/native/rpcs3_shader_storage_client_test.cpp').read_text().replace('EXPECTED_KEY_HEX',expected)
    (out/'test.cpp').write_text(test)
    exe=out/'test'
    subprocess.run([*compiler,'-std=c++20','-O1','-g','-pthread','-fsanitize=address,undefined','-I',str(out),'-I',str(source/'rpcs3'),
                    str(out/'test.cpp'),str(source/'rpcs3/Crypto/sha256.cpp'),'-o',str(exe)],check=True,env=env)
    subprocess.run([str(exe)],check=True,timeout=60,env=env)
    text=(source/'rpcs3/ios/RPCS3IOS.cpp').read_text()
    setter=re.search(r'extern "C" RPCS3_IOS_EXPORT int32_t rpcs3_ios_set_storage_cache_api\([^\n]+\) noexcept\n\{.*?\n\}',text,re.S)
    assert setter and '_rpcs3_ios_set_storage_cache_api' in (source/'rpcs3/ios/RPCS3IOS.exports').read_text().splitlines()
    (out/'setter.cpp').write_text('#define RPCS3_IOS_CORE_BUILD 1\n#include "ios/RPCS3IOS.h"\n#include "ios/NeoSwapStorage/Client.h"\n'+setter[0]+'\n')
    subprocess.run([*compiler,'-std=c++20','-O2','-fvisibility=hidden','-fvisibility-inlines-hidden','-I',str(source/'rpcs3'),'-c',str(out/'setter.cpp'),'-o',str(out/'setter.o')],check=True,env=env)
    symbols=subprocess.check_output(['nm',str(out/'setter.o')],text=True)
    assert not re.search(r'_GLOBAL__sub_I|__cxx_global_var_init|__cxa_guard|Store|ShaderCache',symbols),symbols
print('PASS: exact storage ABI/client, SHA-256 key, source fallback and passive setter; Vulkan consumer required in full Core build')
