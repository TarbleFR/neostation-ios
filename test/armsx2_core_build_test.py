#!/usr/bin/env python3
"""Generate the production CMake target with controlled dependency locations.

Checks dependency-header propagation and source-specific ARC flags, without
compiling an emulator or claiming iOS/device validation.
"""
from pathlib import Path
import json
import shlex
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='armsx2-cmake-') as directory:
    fixture=Path(directory)
    upstream=fixture/'upstream'
    source=upstream/'platforms/ios/app/src/main/cpp'
    adapter=fixture/'adapter'
    build=fixture/'build'
    zstd=fixture/'relocated-zstd/include'
    zstd.mkdir(parents=True)
    for path in [source/'ios_main.mm',source/'IOS/GamepadHaptics.mm',
                 source/'IOS/HostImpls.mm',source/'IOS/PlaySoundAsync.mm',
                 source/'IOS/ARMSX2GameView.h',source/'ARMSX2Bridge.mm',
                 adapter/'core/ARMSX2Core.mm',adapter/'core/exports.txt',
                 upstream/'bin/resources-overlay/armsx2_overrides.yaml',
                 source.parent/'assets/resources/patches.zip']:
        path.parent.mkdir(parents=True,exist_ok=True)
        path.write_text('')
    target=ROOT/'packages/armsx2_internal_bridge/core/target.cmake'
    cmake=f'''
cmake_minimum_required(VERSION 3.20)
project(ARMSX2BuildContract LANGUAGES CXX)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
set(NEO_ARMSX2_ADAPTER_DIR "{adapter}")
set(NEO_ARMSX2_SOURCE_REVISION test-revision)
set(ARMSX2_ROOT "{upstream}")
set(ARMSX2_HAVE_LIBRASHADER TRUE)
foreach(name PCSX2 PCSX2_FLAGS librashader)
  add_library(${{name}} INTERFACE)
endforeach()
add_library(SDL3::SDL3 INTERFACE IMPORTED)
add_library(Zstd::Zstd INTERFACE IMPORTED)
set_property(TARGET Zstd::Zstd PROPERTY INTERFACE_INCLUDE_DIRECTORIES "{zstd}")
include("{target}")
# This fixture generates compiler arguments; none of the dummy sources is built.
set_source_files_properties(ios_main.mm IOS/GamepadHaptics.mm IOS/HostImpls.mm
  IOS/PlaySoundAsync.mm ARMSX2Bridge.mm "{adapter}/core/ARMSX2Core.mm"
  PROPERTIES LANGUAGE CXX)
'''
    (source/'CMakeLists.txt').write_text(cmake)
    subprocess.run(['cmake','-S',str(source),'-B',str(build),'-G','Unix Makefiles'],
                   check=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
    commands=json.loads((build/'compile_commands.json').read_text())
    def flags(name):
        entries=[entry for entry in commands if Path(entry['file']).name==name]
        assert len(entries)==1,(name,entries)
        return shlex.split(entries[0]['command'])
    bridge=flags('ARMSX2Bridge.mm')
    assert str(zstd) in bridge or '-I'+str(zstd) in bridge
    assert bridge.index('-fobjc-arc')>bridge.index('-fno-objc-arc'),bridge
    for name in ('ARMSX2Core.mm','ios_main.mm','HostImpls.mm'):
        assert '-fobjc-arc' not in flags(name),name
    assert '-fexceptions' in flags('ARMSX2Core.mm')
print('PASS: production CMake propagates relocated Zstandard headers; ARC applies only to the 2.6 bridge')
