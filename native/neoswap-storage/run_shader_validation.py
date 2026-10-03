#!/usr/bin/env python3
"""Validate the actual storage consumer, service SDK linkage and GPU lifetimes."""
from __future__ import annotations
import argparse, hashlib, json, os, platform, shutil, subprocess, tempfile, plistlib, time, uuid
from pathlib import Path
import sys
ROOT=Path(__file__).resolve().parents[2]
HERE=ROOT/'native/neoswap-storage'
sys.path.insert(0,str(HERE))
from run_validation import execute
MOLTENVK_SHA='f95765a6229cb7b915990a2890ce12ebe36a730b021545d3d52ae69ce4c4024e'

def simulator_service(work, out, sources):
    sdk=subprocess.check_output(['xcrun','--sdk','iphonesimulator','--show-sdk-path'],text=True).strip()
    app=work/'ShaderServiceTest.app';app.mkdir();exe=app/'ShaderServiceTest'
    service=ROOT/'packages/neo_swap/ios/Classes/NeoSwapStorageService.mm'
    command=['xcrun','--sdk','iphonesimulator','clang++','-std=c++20','-O1','-Wall','-Wextra','-Werror',
             '-DNEOSWAP_STORAGE_TESTING',
             '-fobjc-arc','-fblocks','-x','objective-c++','-target','arm64-apple-ios18.0-simulator','-isysroot',sdk,
             '-I',str(HERE),'-I',str(service.parent)]
    execute(command+sources+[str(HERE/'SourceClient.cpp'),str(HERE/'Metrics.cpp'),str(service),str(HERE/'tests/service_runtime.mm'),
            '-framework','Foundation','-framework','UIKit','-lcompression','-lz','-o',str(exe)],out,'shader-simulator-build')
    bundle='com.neostation.storage.service.test'
    with (app/'Info.plist').open('wb') as f:
        plistlib.dump({'CFBundleIdentifier':bundle,'CFBundleExecutable':exe.name,'CFBundleName':'ShaderServiceTest',
                      'CFBundleVersion':'1','CFBundleShortVersionString':'1.0','CFBundlePackageType':'APPL',
                      'MinimumOSVersion':'18.0','LSRequiresIPhoneOS':True,'UILaunchScreen':{},'UIDeviceFamily':[1,2]},f)
    execute(['codesign','--force','--sign','-',str(app)],out,'shader-simulator-sign')
    runtimes=json.loads(subprocess.check_output(['xcrun','simctl','list','runtimes','-j']))['runtimes']
    candidates=[x for x in runtimes if x.get('isAvailable') and x['identifier'].startswith('com.apple.CoreSimulator.SimRuntime.iOS-18')]
    if not candidates:raise RuntimeError('An actual iOS18 simulator runtime is required')
    runtime=sorted(candidates,key=lambda x:x['version'])[-1]['identifier']
    identifier=subprocess.check_output(['xcrun','simctl','create','NeoSwapShader-'+uuid.uuid4().hex[:8],
            'com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro',runtime],text=True).strip()
    try:
        execute(['xcrun','simctl','boot',identifier],out,'shader-simulator-boot')
        execute(['xcrun','simctl','bootstatus',identifier,'-b'],out,'shader-simulator-bootstatus',timeout=180)
        execute(['xcrun','simctl','install',identifier,str(app)],out,'shader-simulator-install')
        execute(['xcrun','simctl','launch',identifier,bundle],out,'shader-simulator-launch')
        directory=Path(subprocess.check_output(['xcrun','simctl','get_app_container',identifier,bundle,'data'],text=True).strip())
        report=directory/'Documents/shader-service-runtime.json'
        deadline=time.monotonic()+90
        while not report.exists() and time.monotonic()<deadline:time.sleep(.25)
        if not report.exists():raise RuntimeError('iOS service did not produce a result')
        value=json.loads(report.read_text());(out/'shader-service-runtime.json').write_text(json.dumps(value,indent=2)+'\n')
        assert value['passed'],value
        return value
    finally:
        subprocess.run(['xcrun','simctl','shutdown',identifier],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        subprocess.run(['xcrun','simctl','delete',identifier],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--output',required=True,type=Path);a=parser.parse_args()
    out=a.output.resolve();out.mkdir(parents=True,exist_ok=True)
    system=platform.system();apple=system=='Darwin'
    if system not in ('Linux','Darwin'):raise SystemExit('POSIX validation requires Linux or macOS')
    compiler=shutil.which('clang++');assert compiler
    common=[compiler,'-std=c++20','-pthread','-Wall','-Wextra','-Werror','-I',str(HERE)]
    libs=['-lcompression','-lz'] if apple else ['-llz4','-lz']
    sources=[str(HERE/p) for p in ('Store.cpp','ShaderCache.cpp')]
    host_sources=sources+[str(HERE/'ManagedSwap.cpp'),str(HERE/'SourceArchive.cpp')]
    result={'schema':1,'sourceCommit':os.environ.get('GITHUB_SHA'),'platform':system,'passed':False,
            'productionClientExecuted':False,'productionHostServiceIOSLinked':False,
            'realVulkanModule':False,'physicalIPhoneValidated':False,'realRPCS3GameplayValidated':False,
            'nandColdReadLatencyProven':False,'kernelSwapPorted':False}
    with tempfile.TemporaryDirectory(prefix='shader-storage-validation-') as temp:
        work=Path(temp)
        binary=work/'shader-tests'
        execute(common+['-O1','-g','-fsanitize=address,undefined','-fno-omit-frame-pointer','-DNEOSWAP_STORAGE_TESTING']+
                sources+[str(HERE/'tests/shader_cache_test.cpp')]+libs+['-o',str(binary)],out,'shader-build-sanitized')
        text=execute([str(binary),str(work/'native-cache')],out,'shader-file-and-lifetime-tests')
        native=json.loads(text);assert native['passed'] and native['productionClientExecuted'];result['native']=native;result['productionClientExecuted']=True
        if apple:
            execute([sys.executable,str(ROOT/'build-utils/configure_neoswap_storage.py')],out,'shader-canonical-host-copies')
            sdk=subprocess.check_output(['xcrun','--sdk','iphoneos','--show-sdk-path'],text=True).strip()
            service=ROOT/'packages/neo_swap/ios/Classes/NeoSwapStorageService.mm'
            ios=['xcrun','--sdk','iphoneos','clang++','-std=c++20','-O2','-Wall','-Wextra','-Werror','-fobjc-arc','-fblocks',
                 '-x','objective-c++','-arch','arm64','-isysroot',sdk,'-miphoneos-version-min=18.0','-I',str(HERE)]
            library=out/'NeoSwapShaderHostProbe.dylib'
            execute(ios+host_sources+[str(HERE/'Metrics.cpp'),str(service),'-dynamiclib','-framework','Foundation','-framework','UIKit',
                    '-lcompression','-lz','-install_name','@rpath/NeoSwapShaderHostProbe.dylib','-o',str(library)],out,'shader-ios-service-link')
            text=execute(['xcrun','nm','-gU',str(library)],out,'shader-ios-service-symbols')
            for symbol in ('_NeoSwapStorage_GetAPI','_NeoSwapStorage_BeginSession','_NeoSwapStorage_EndSession','_NeoSwapStorage_Diagnostics','_NeoSwapStorage_GetSourceAPI','_NeoSwapStorage_SetSourceBinderResult'):
                assert symbol in text,symbol
            result['productionHostServiceIOSLinked']=True
            result['simulator']=simulator_service(work,out,host_sources)
            result['realIOSSimulatorServiceExecuted']=True
            archive=work/'MoltenVK.tar'
            execute(['curl','-fL','--retry','3','https://github.com/KhronosGroup/MoltenVK/releases/download/v1.4.2/MoltenVK-macos.tar','-o',str(archive)],out,'shader-moltenvk-download')
            assert hashlib.sha256(archive.read_bytes()).hexdigest()==MOLTENVK_SHA,'MoltenVK release identity'
            execute(['tar','-xf',str(archive),'-C',str(work)],out,'shader-moltenvk-extract')
            dylib=next(work.rglob('libMoltenVK.dylib'));include=next(work.rglob('vulkan.h')).parent.parent
            gpu=work/'shader-vulkan-tests'
            execute(common+['-O2','-DNEOSWAP_STORAGE_TESTING','-I',str(include)]+sources+
                    [str(HERE/'tests/vulkan_shader_storage.cpp')]+libs+
                    ['-L',str(dylib.parent),'-lMoltenVK','-Wl,-rpath,'+str(dylib.parent),'-o',str(gpu)],out,'shader-vulkan-build')
            text=execute([str(gpu),str(work/'gpu-cache')],out,'shader-vulkan-run')
            gpu_result=json.loads(next(line for line in reversed(text.splitlines()) if line.startswith('{')))
            assert gpu_result['passed'] and gpu_result['sourceBuilds']==gpu_result['sourceBuildsBeforeRestore']>=1 and gpu_result['realComputeDispatchCompleted']
            assert gpu_result['cpuBytesReleasedBeforePipeline'] and gpu_result['diskReadBytes']>0
            result['gpu']=gpu_result;result['realVulkanModule']=True;result['moltenVKArchiveSHA256']=MOLTENVK_SHA
    tracked=list(HERE.glob('*.h'))+list(HERE.glob('*.cpp'))+list(HERE.glob('*.py'))+list((HERE/'tests').glob('*.cpp'))+list((HERE/'tests').glob('*.mm'))
    tracked += [ROOT/'build-utils/configure_neoswap_storage.py',ROOT/'packages/neo_swap/ios/Classes/NeoSwapStorageService.h',ROOT/'packages/neo_swap/ios/Classes/NeoSwapStorageService.mm',ROOT/'packages/neo_swap/ios/Classes/StorageABI.h']
    tracked += [ROOT/'packages/neo_swap/ios/Classes/SourceABI.h']
    tracked += [ROOT/'packages/neo_swap/ios/Classes/NeoSwapSourceWork.h']
    result['inputSHA256']={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(set(tracked))}
    result['passed']=True
    (out/'shader-integration.json').write_text(json.dumps(result,indent=2)+'\n')
    print('PASS actual storage client and real file restoration; Apple results scoped to SDK link / macOS GPU, not gameplay.')
if __name__=='__main__':main()
