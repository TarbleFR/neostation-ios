#!/usr/bin/env python3
"""Execute the exact Core cold-source client; no GPU or device simulation claim."""
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
for name in ('SourceABI.h','SourceClient.h','SourceClient.cpp'):
    assert (source/'rpcs3/ios/NeoSwapStorage'/name).read_bytes()==(root/'native/neoswap-storage'/name).read_bytes(),name
cpp=(source/'rpcs3/Emu/RSX/VK/VKProgramPipeline.cpp').read_text()
header=(source/'rpcs3/Emu/RSX/VK/VKProgramPipeline.h').read_text()
body=cpp.split('VkShaderModule shader::compile()',1)[1].split('void shader::destroy()',1)[0]
assert body.index('m_source_archive.offload')>body.index('CompileResult::module_failure')
assert 'spirv::compile_glsl_to_spv(binary, m_source, type, ::glsl::glsl_rules_vulkan)' in body
assert 'vkCreateShaderModule(*g_render_device, &info, nullptr, &m_handle)' in body
assert 'store_' not in cpp and 'fsync(' not in cpp and 'wait_for(' not in cpp
assert '#ifdef RPCS3_IOS\n\t\t\tstd::string get_source() const;\n#else\n\t\t\tconst std::string& get_source() const;' in header
assert 'm_source_archive.restore(restored, os_error)' in cpp and 'return restored;' in cpp
assert cpp.split('void shader::destroy()',1)[1].split('m_source.clear();',1)[0].count('m_source_archive.reset();')==1
assert 'auto source = get_source();' in cpp
cmake=(source/'rpcs3/Emu/CMakeLists.txt').read_text()
assert 'set_source_files_properties("../ios/NeoSwapStorage/SourceClient.cpp" PROPERTIES\n        COMPILE_OPTIONS -fexceptions\n        SKIP_PRECOMPILE_HEADERS ON\n    )' in cmake
assert cmake.count('        ../ios/NeoSwapStorage/SourceClient.cpp\n')==1
with tempfile.TemporaryDirectory(prefix='rpcs3-source-client-') as temp:
    out=Path(temp);exe=out/'test'
    # The Vulkan upscaler really includes this header with exceptions disabled.
    # Compile calls too, not just an empty include; definitions stay out-of-line.
    (out/'no-exceptions.cpp').write_text('#include "ios/NeoSwapStorage/SourceClient.h"\n'
        'void probe(neostation::source_client::ColdSource& c,std::string& s,int& e){'
        '(void)c.offload(s,0);(void)c.restore(s,e);c.reset();}\n')
    subprocess.run([*compiler,'-std=c++20','-Wall','-Wextra','-Werror','-fno-exceptions',
                    '-I',str(source/'rpcs3'),'-c',str(out/'no-exceptions.cpp'),'-o',str(out/'no-exceptions.o')],check=True,env=env)
    implementation=source/'rpcs3/ios/NeoSwapStorage/SourceClient.cpp'
    rejected=subprocess.run([*compiler,'-std=c++20','-fno-exceptions','-fsyntax-only',str(implementation)],
                            capture_output=True,text=True,env=env)
    assert rejected.returncode!=0 and 'requires exceptions in this dedicated unit' in rejected.stderr
    subprocess.run([*compiler,'-std=c++20','-O1','-g','-pthread','-Wall','-Wextra','-Werror',
                    '-fsanitize=address,undefined','-I',str(source/'rpcs3'),
                    str(root/'test/native/rpcs3_source_archive_client_test.cpp'),str(implementation),'-o',str(exe)],check=True,env=env)
    subprocess.run([str(exe)],check=True,timeout=60,env=env)
    text=(source/'rpcs3/ios/RPCS3IOS.cpp').read_text()
    setter=re.search(r'extern "C" RPCS3_IOS_EXPORT int32_t rpcs3_ios_set_source_archive_api\([^\n]+\) noexcept\n\{.*?\n\}',text,re.S)
    assert setter and '_rpcs3_ios_set_source_archive_api' in (source/'rpcs3/ios/RPCS3IOS.exports').read_text().splitlines()
    (out/'setter.cpp').write_text('#define RPCS3_IOS_CORE_BUILD 1\n#include "ios/RPCS3IOS.h"\n#include "ios/NeoSwapStorage/SourceClient.h"\n'+setter[0]+'\n')
    subprocess.run([*compiler,'-std=c++20','-O2','-fno-exceptions','-fvisibility=hidden','-fvisibility-inlines-hidden',
                    '-I',str(source/'rpcs3'),'-c',str(out/'setter.cpp'),'-o',str(out/'setter.o')],check=True,env=env)
    symbols=subprocess.check_output(['nm',str(out/'setter.o')],text=True)
    assert not re.search(r'_GLOBAL__sub_I|__cxx_global_var_init|__cxa_guard|Store|SourceArchive|ManagedSwap',symbols),symbols
print('PASS exact source client ABI 1 and passive setter; full Core build must compile the Vulkan consumer')
