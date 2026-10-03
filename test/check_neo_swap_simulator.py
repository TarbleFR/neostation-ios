#!/usr/bin/env python3
"""Run the production broker + Flutter plugin control plane on iOS Simulator."""
import json, os, pathlib, plistlib, shutil, subprocess, time
ROOT=pathlib.Path(__file__).resolve().parents[1]
OUT=ROOT/'build/neoswap';OUT.mkdir(parents=True,exist_ok=True)
def run(*args, **kwargs):
    return subprocess.check_output(args,text=True,**kwargs).strip()
sdk=run('xcrun','--sdk','iphonesimulator','--show-sdk-path')
app=OUT/'NeoSwapProbe.app';app.mkdir(exist_ok=True)
plist={'CFBundleIdentifier':'org.neostation.neoswap.probe','CFBundleExecutable':'NeoSwapProbe',
       'CFBundleName':'NeoSwapProbe','CFBundlePackageType':'APPL','CFBundleVersion':'1',
       'CFBundleShortVersionString':'1.0','MinimumOSVersion':'18.0','UIDeviceFamily':[1,2],
       'LSRequiresIPhoneOS':True,'UILaunchScreen':{}}
(app/'Info.plist').write_bytes(plistlib.dumps(plist))
sources=ROOT/'packages/neo_swap/ios/Classes'
subprocess.run(['xcrun','--sdk','iphonesimulator','clang++','-x','objective-c++','-std=c++20',
 '-fobjc-arc','-fblocks','-arch','arm64','-mios-simulator-version-min=18.0','-isysroot',sdk,
 '-I'+str(ROOT/'test/neoswap'),'-I'+str(sources),str(sources/'NeoSwap.cpp'),
 str(sources/'NeoSwapPlugin.mm'),str(ROOT/'test/neoswap/control_probe.mm'),
 '-framework','Foundation','-framework','UIKit','-o',str(app/'NeoSwapProbe')],check=True)
subprocess.run(['codesign','--force','--sign','-',str(app)],check=True)
runtimes=json.loads(run('xcrun','simctl','list','runtimes','-j'))['runtimes']
runtime=next((r['identifier'] for r in runtimes if r.get('isAvailable') and r['version'].startswith('18.')),None)
assert runtime,'An available iOS 18 runtime is required; this test may not silently skip'
uid=run('xcrun','simctl','create','NeoSwap-'+str(os.getpid()),'com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro',runtime)
try:
    subprocess.run(['xcrun','simctl','boot',uid],check=True)
    subprocess.run(['xcrun','simctl','bootstatus',uid,'-b'],check=True,timeout=180)
    subprocess.run(['xcrun','simctl','install',uid,str(app)],check=True)
    container=pathlib.Path(run('xcrun','simctl','get_app_container',uid,plist['CFBundleIdentifier'],'data'))
    subprocess.run(['xcrun','simctl','launch',uid,plist['CFBundleIdentifier']],check=True)
    result=container/'Documents/result.json';deadline=time.monotonic()+90
    while not result.exists() and time.monotonic()<deadline: time.sleep(1)
    assert result.exists(),'Native control probe did not produce a result (crash or timeout)'
    report=json.loads(result.read_text());shutil.copy2(result,OUT/'simulator-control.json')
    log=container/'Documents/Diagnostics/NeoSwap-v1.jsonl'
    if log.exists(): shutil.copy2(log,OUT/'simulator-neoswap.jsonl')
    shutil.copy2(container/'Documents/memory-samples.jsonl',OUT/'simulator-memory-samples.jsonl')
    assert report['success'] and report['checks']>=30,report
    assert report['memoryLogsPassed'] is True and report['realRPCS3GameplayValidated'] is False,report
    (OUT/'source.txt').write_text(os.environ.get('GITHUB_SHA',run('git','rev-parse','HEAD',cwd=ROOT))+'\n')
    print('PASS',json.dumps(report))
finally:
    subprocess.run(['xcrun','simctl','shutdown',uid],check=False)
    subprocess.run(['xcrun','simctl','delete',uid],check=False)
