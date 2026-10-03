#!/usr/bin/env python3
"""Verify 2.6 identity/resources and run the production preset resolver on macOS.

Foundation tests exercise real files, container moves and symlink rejection.
These checks do not validate game rendering or JIT on a device.
"""
from pathlib import Path
import json, platform, re, subprocess, tempfile
ROOT=Path(__file__).resolve().parents[1]
CLASSES=ROOT/'packages/armsx2_internal_bridge/ios/Classes'
CORE=ROOT/'packages/armsx2_internal_bridge/core'
localization=(CLASSES/'ARMSX2InGameLocalization.mm').read_text()
graphics=localization.split('static NSDictionary* ARMSX2GraphicsTranslations()',1)[1].split('NSString* ARMSX2CanonicalLocale',1)[0]
locales=('en','fr','de','es','it','pt','ru','id','ja','ko','zh','zh_Hant')
translation_keys=None
for locale in locales:
    block=re.search(r'@"'+locale+r'": @\{(.*?)\n      \}',graphics,re.S)[1]
    entries=dict(re.findall(r'@"((?:[^"\\]|\\.)*)": @"((?:[^"\\]|\\.)*)"',block))
    assert entries and all(entries.values()),locale
    keys=set(entries)
    if translation_keys is None: translation_keys=keys
    assert keys==translation_keys,locale
    for key,value in entries.items():
        assert re.findall(r'%[\d.$]*[@dufs]',key)==re.findall(r'%[\d.$]*[@dufs]',value),(locale,key)
assert len(translation_keys)==13
source=json.loads((ROOT/'build-utils/armsx2/source.json').read_text())
assert source['release']=='iOSv2.6.0' and source['revision']=='9d989ca933a85bb2f1d111fd3b9e5742ac7d2fbe'
assert source['abi_version']==6
assert '#define NEO_ARMSX2_ABI_VERSION 6u' in (CLASSES/'ARMSX2CoreABI.h').read_text()
print('PASS: exact official 2.6 pin; ABI 6; 13 graphics keys in all 12 locales')
if platform.system()!='Darwin':
    print('Foundation behavior checks require macOS and are mandatory in native CI.')
    raise SystemExit(0)
program=r'''
#import <Foundation/Foundation.h>
#import "ARMSX2ShaderLibrary.h"
#import "ARMSX2InGameLocalization.h"
#include <cassert>
static void write(NSString* root,NSString* file) {
 NSString* path=[root stringByAppendingPathComponent:file];
 assert([NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil]);
 assert([@"shaders = 1\nshader0 = stage.slang\n" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]);
}
int main() { @autoreleasepool {
 NSString* temp=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
 NSString* bundled=[temp stringByAppendingPathComponent:@"container-a/shaders"];
 NSString* user=[temp stringByAppendingPathComponent:@"data/shaders"];
 write(bundled,@"presets/crt.slangp"); write(user,@"pack/lcd.slangp");
 assert(NeoShaderResolve(@"bundle:presets/crt.slangp",bundled,user));
 NSArray* bundledScan=NeoShaderScan(bundled,@"bundle");
 if(bundledScan.count!=1) NSLog(@"Preset scan failed: root=%@ canonical=%@ entries=%@",bundled,bundled.stringByResolvingSymlinksInPath,bundledScan);
 assert(bundledScan.count==1);
 assert([bundledScan[0][@"id"] isEqual:@"bundle:presets/crt.slangp"]);
 assert(NeoShaderScan(user,@"data").count==1);
 assert(NeoShaderResolve(@"bundle:presets/crt.slangp",bundled,user));
 assert(NeoShaderResolve(@"data:pack/lcd.slangp",bundled,user));
 for(NSString* bad in @[@"../pack/lcd.slangp",@"data:../outside.slangp",@"data:/pack/lcd.slangp",@"other:pack/lcd.slangp",@"data:missing.slangp",@"data:pack/lcd.slang"]) assert(!NeoShaderResolve(bad,bundled,user));
 NSString* moved=[temp stringByAppendingPathComponent:@"container-b/shaders"];
 assert([NSFileManager.defaultManager createDirectoryAtPath:moved.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil]);
 assert([NSFileManager.defaultManager moveItemAtPath:bundled toPath:moved error:nil]);
 assert(!NeoShaderResolve(@"bundle:presets/crt.slangp",bundled,user));
 assert(NeoShaderResolve(@"bundle:presets/crt.slangp",moved,user));
 NSString* outside=[temp stringByAppendingPathComponent:@"outside"];
 write(outside,@"escape.slangp");
 assert([NSFileManager.defaultManager createSymbolicLinkAtPath:[user stringByAppendingPathComponent:@"linked"] withDestinationPath:outside error:nil]);
 assert(!NeoShaderResolve(@"data:linked/escape.slangp",moved,user));
 assert(NeoShaderScan(user,@"data").count==1);
 NSArray* scan=NeoShaderScan(user,@"data");
 assert([scan[0][@"id"] isEqual:@"data:pack/lcd.slangp"]);
 assert([ARMSX2CanonicalLocale(@"zh-TW") isEqual:@"zh_Hant"]);
 assert([ARMSX2LocalizedText(@"Performance Overlays",@"",@"fr") isEqual:@"Overlays de performances"]);
 assert([ARMSX2LocalizedText(@"Detailed",@"",@"zh-Hant") isEqual:@"詳細"]);
 [NSFileManager.defaultManager removeItemAtPath:temp error:nil];
 puts("PASS: production scans; stable identities after container move; invalid paths; symlink escape; locale selection");
} }
'''
with tempfile.TemporaryDirectory(prefix='armsx2-graphics-') as directory:
    src=Path(directory)/'test.mm';binary=Path(directory)/'test';src.write_text(program)
    subprocess.run(['xcrun','clang++','-std=c++20','-fblocks','-fobjc-arc','-I',str(CORE),'-I',str(CLASSES),str(src),str(CLASSES/'ARMSX2InGameLocalization.mm'),'-framework','Foundation','-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True,timeout=20)

with tempfile.TemporaryDirectory(prefix='armsx2-graphics-settings-') as directory:
    binary=Path(directory)/'test'
    subprocess.run(['xcrun','clang++','-std=c++20','-fblocks','-fobjc-arc','-I',str(CORE),str(ROOT/'test/armsx2_graphics_settings_test.mm'),'-framework','Foundation','-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True,timeout=20)
