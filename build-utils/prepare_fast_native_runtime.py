#!/usr/bin/env python3
"""Install immutable native binaries from the validated Build 270 donor IPA.

Fast experimental builds do not rebuild RPCS3Core, DolphinCore or StikJIT.
This script verifies the known runtime hashes/scripts before placing those
artifacts into the normal CocoaPods/package locations.
"""
from pathlib import Path
import argparse, hashlib, json, plistlib, shutil, subprocess, tempfile, zipfile

ROOT=Path(__file__).resolve().parents[1]
DOLPHIN_SHA='60012e203c927d468cb6d82d21aa8f8e14299fedbf0b2f80ce0ea982d4e173ee'
RPCS3_SHA='dba1bb3bf8847faf3e378c1815ffe895521d8d6404e468bb6a2eee5fa8cb4ddd'
UNIVERSAL_SHA='22b0146b14ac230b3e04f1cbcaadbfddd898cbe6bb96c554981bef9cff311ba1'
LEGACY_SHA='787df4678ca17fd100a1d002203bfac8771fae062175aa510da8d6af9f8167ec'\nOFFICIAL_STIK_ZIP_SHA='444b8d439df8455c34afbb51e279fd225265279195475f9b3fdbcf3a71a27e85'

def sha(path):
    h=hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda:handle.read(1024*1024),b''):
            h.update(chunk)
    return h.hexdigest()

def demand(ok,msg):
    if not ok:
        raise SystemExit(msg)

def find_ipa(root):
    items=list(root.rglob('*.ipa'))
    demand(len(items)==1,f'Expected exactly one donor IPA, found: {items}')
    return items[0]

def copytree(src,dst):
    if dst.exists(): shutil.rmtree(dst)
    dst.parent.mkdir(parents=True,exist_ok=True)
    shutil.copytree(src,dst,symlinks=True)

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('artifact',type=Path)
    parser.add_argument('--build-number',required=True)
    args=parser.parse_args()
    donor=args.artifact.resolve()

    with tempfile.TemporaryDirectory(prefix='neostation-fast-native-') as temp:
        work=Path(temp)
        if donor.is_dir():
            ipa=find_ipa(donor)
        elif donor.suffix=='.ipa':
            ipa=donor
        elif donor.suffix=='.zip':
            with zipfile.ZipFile(donor) as archive:
                archive.extractall(work/'artifact')
            ipa=find_ipa(work/'artifact')
        else:
            raise SystemExit(f'Unsupported donor path: {donor}')

        with zipfile.ZipFile(ipa) as archive:
            demand(archive.testzip() is None,'Donor IPA ZIP is corrupt')
            names=archive.namelist()
            apps=sorted({
                name.split('/')[1]
                for name in names
                if name.startswith('Payload/') and len(name.split('/'))>2
                and name.split('/')[1].endswith('.app')
            })
            demand(len(apps)==1,f'Expected one donor application, found {apps}')
            archive.extractall(work/'ipa')

        app=work/'ipa'/'Payload'/apps[0]
        stik=app/'Frameworks/StikJIT.framework'
        dolphin=app/'Frameworks/DolphinCore.framework'
        rpcs3=app/'Frameworks/libRPCS3Core.dylib'
        dolphin_bridge=app/'Frameworks/dolphin_internal_bridge.framework'

        for required in (stik/'StikJIT', dolphin/'DolphinCore', rpcs3):
            demand(required.is_file(),f'Missing donor runtime: {required}')

        demand(sha(dolphin/'DolphinCore')==DOLPHIN_SHA,'DolphinCore donor hash mismatch')
        demand(sha(rpcs3)==RPCS3_SHA,'RPCS3Core donor hash mismatch')
        demand(sha(stik/'universal.js')==UNIVERSAL_SHA,'StikJIT universal.js donor hash mismatch')
        demand(sha(stik/'legacy.js')==LEGACY_SHA,'StikJIT legacy.js donor hash mismatch')

        # Embedded app frameworks are stripped of Swift interfaces. Use the
        # official 1.5.0 XCFramework only as the module/interface shell, then
        # replace its device runtime and scripts with the exact donor bytes.
        official_root=work/'official-stik'
        with zipfile.ZipFile(official_stik) as archive:
            demand(archive.testzip() is None,'Official StikJIT archive is corrupt')
            archive.extractall(official_root)
        official_items=list(official_root.rglob('StikJIT.xcframework'))
        demand(len(official_items)==1,f'Expected one official StikJIT XCFramework, found {official_items}')
        xcframework=work/'StikJIT.xcframework'
        copytree(official_items[0],xcframework)
        device=xcframework/'ios-arm64/StikJIT.framework'
        demand((device/'Modules').is_dir(),'Official StikJIT Swift module is missing')
        shutil.copy2(stik/'StikJIT',device/'StikJIT')
        (device/'StikJIT').chmod(0o755)
        for script_name,expected in (('universal.js',UNIVERSAL_SHA),('legacy.js',LEGACY_SHA)):
            shutil.copy2(stik/script_name,device/script_name)
            demand(sha(device/script_name)==expected,f'Patched {script_name} hash mismatch')
        donor_info=stik/'Info.plist'
        if donor_info.is_file():
            shutil.copy2(donor_info,device/'Info.plist')

        for package in ('stikjit_bridge','dolphin_jit_helper'):
            copytree(
                xcframework,
                ROOT/f'packages/{package}/ios/Frameworks/StikJIT.xcframework'
            )

        copytree(
            dolphin,
            ROOT/'packages/dolphin_internal_bridge/ios/Frameworks/DolphinCore.framework'
        )
        info_path=ROOT/'packages/dolphin_internal_bridge/ios/Frameworks/DolphinCore.framework/Info.plist'
        if info_path.is_file():
            info=plistlib.loads(info_path.read_bytes())
            info['CFBundleVersion']=str(args.build_number)
            info_path.write_bytes(plistlib.dumps(info,fmt=plistlib.FMT_XML,sort_keys=False))

        core_dst=ROOT/'packages/rpcs3_internal_bridge/ios/Frameworks/libRPCS3Core.dylib'
        core_dst.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(rpcs3,core_dst)
        core_dst.chmod(0o755)

        # Reuse the immutable Dolphin system data and native touchscreen assets
        # that were already packaged in the validated donor.
        sys_src=app/'Sys'
        sys_dst=ROOT/'ios/Runner/Sys'
        demand(sys_src.is_dir(),'Donor Dolphin Sys resources missing')
        copytree(sys_src,sys_dst)

        touch_dst=ROOT/'packages/dolphin_internal_bridge/ios/TouchResources'
        if touch_dst.exists(): shutil.rmtree(touch_dst)
        touch_dst.mkdir(parents=True)
        demand(dolphin_bridge.is_dir(),'Donor Dolphin bridge framework missing')
        copied=0
        for child in dolphin_bridge.iterdir():
            if child.suffix=='.png' or child.name.endswith('.nib'):
                target=touch_dst/child.name
                if child.is_dir(): shutil.copytree(child,target)
                else: shutil.copy2(child,target)
                copied+=1
        demand(copied>0,'No Dolphin touchscreen resources found in donor framework')

        logs=ROOT/'build/dolphin-ci'
        logs.mkdir(parents=True,exist_ok=True)
        stik_binary_sha=sha(stik/'StikJIT')
        release={
            'release':'1.5.0',
            'sourceRevision':'640fac91de403fdb85a3778aa0bbb7f30737b74c',
            'donorRun':35321768668,
            'binarySha256':stik_binary_sha,
            'universalJsSha256':UNIVERSAL_SHA,
            'legacyJsSha256':LEGACY_SHA,
            'platform':'ios-arm64',
            'officialInterfaceArchiveSha256':OFFICIAL_STIK_ZIP_SHA,\n            'fastReuse':True,
        }
        (logs/'stikjit-release.json').write_text(json.dumps(release,indent=2)+'\n')

        identity=ROOT/'build/fast-native/identity.json'
        identity.parent.mkdir(parents=True,exist_ok=True)
        identity.write_text(json.dumps({
            'donorIpa':ipa.name,
            'donorRun':35321768668,
            'stikjitBinarySha256':stik_binary_sha,
            'universalJsSha256':sha(stik/'universal.js'),
            'legacyJsSha256':sha(stik/'legacy.js'),
            'dolphinCoreSha256':sha(dolphin/'DolphinCore'),
            'rpcs3CoreSha256':sha(rpcs3),
            'touchResourcesCopied':copied,
        },indent=2)+'\n')
        print(identity.read_text())

if __name__=='__main__':
    main()
