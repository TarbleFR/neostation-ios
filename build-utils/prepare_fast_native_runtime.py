#!/usr/bin/env python3
"""Install immutable native binaries from the validated Build 270 donor IPA.

Fast experimental builds do not rebuild RPCS3Core, DolphinCore or StikJIT.
The official StikJIT 1.5.0 XCFramework supplies compile-time Swift interfaces;
the runtime binary and scripts are replaced with the hash-verified donor bytes.
"""
from pathlib import Path
import argparse
import hashlib
import json
import plistlib
import shutil
import tempfile
import zipfile

ROOT=Path(__file__).resolve().parents[1]
DOLPHIN_SHA='60012e203c927d468cb6d82d21aa8f8e14299fedbf0b2f80ce0ea982d4e173ee'
RPCS3_SHA='dba1bb3bf8847faf3e378c1815ffe895521d8d6404e468bb6a2eee5fa8cb4ddd'
UNIVERSAL_SHA='22b0146b14ac230b3e04f1cbcaadbfddd898cbe6bb96c554981bef9cff311ba1'
LEGACY_SHA='787df4678ca17fd100a1d002203bfac8771fae062175aa510da8d6af9f8167ec'
OFFICIAL_STIK_ZIP_SHA='444b8d439df8455c34afbb51e279fd225265279195475f9b3fdbcf3a71a27e85'


def sha(path: Path) -> str:
    digest=hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024*1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def demand(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def find_ipa(root: Path) -> Path:
    items=list(root.rglob('*.ipa'))
    demand(len(items)==1, f'Expected exactly one donor IPA, found: {items}')
    return items[0]


def copytree(src: Path, dst: Path) -> None:
    if dst.exists():
        shutil.rmtree(dst)
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(src, dst, symlinks=True)


def normalize_swift_interfaces(xcframework: Path) -> int:
    """Normalize known Swift qualification issues in StikJIT 1.5.0 interfaces."""
    interfaces = sorted(xcframework.rglob('*.swiftinterface'))
    demand(bool(interfaces), 'StikJIT XCFramework contains no textual Swift interfaces')
    changed = 0
    for interface in interfaces:
        text = interface.read_text(encoding='utf-8')
        patched = text.replace('StikJIT.DDIPaths', 'DDIPaths')
        patched = patched.replace('StikJIT.StikJIT.', 'StikJIT.')
        if patched != text:
            interface.write_text(patched, encoding='utf-8')
            changed += 1
    for interface in interfaces:
        text = interface.read_text(encoding='utf-8')
        demand(
            'StikJIT.DDIPaths' not in text and 'StikJIT.StikJIT.' not in text,
            f'Invalid StikJIT textual-interface qualification remains: {interface}',
        )
    return changed


def device_framework(xcframework: Path) -> Path:
    info=plistlib.loads((xcframework/'Info.plist').read_bytes())
    matches=[]
    for library in info.get('AvailableLibraries', []):
        if library.get('SupportedPlatform') != 'ios':
            continue
        if library.get('SupportedPlatformVariant'):
            continue
        identifier=library.get('LibraryIdentifier')
        library_path=library.get('LibraryPath')
        if not identifier or not library_path:
            continue
        candidate=xcframework/identifier/library_path
        if candidate.name == 'StikJIT.framework' and candidate.is_dir():
            matches.append(candidate)
    demand(len(matches)==1, f'Expected one device StikJIT framework, found: {matches}')
    return matches[0]


def main() -> None:
    parser=argparse.ArgumentParser()
    parser.add_argument('artifact', type=Path)
    parser.add_argument('--build-number', required=True)
    parser.add_argument('--stik-xcframework-zip', type=Path, required=True)
    args=parser.parse_args()

    donor=args.artifact.resolve()
    official_stik=args.stik_xcframework_zip.resolve()
    demand(official_stik.is_file(), 'Official StikJIT XCFramework ZIP is missing')
    demand(
        sha(official_stik)==OFFICIAL_STIK_ZIP_SHA,
        'Official StikJIT 1.5.0 archive hash mismatch',
    )

    with tempfile.TemporaryDirectory(prefix='neostation-fast-native-') as temp:
        work=Path(temp)
        if donor.is_dir():
            ipa=find_ipa(donor)
        elif donor.suffix=='.ipa':
            ipa=donor
        elif donor.suffix=='.zip':
            with zipfile.ZipFile(donor) as archive:
                demand(archive.testzip() is None, 'Donor artifact ZIP is corrupt')
                archive.extractall(work/'artifact')
            ipa=find_ipa(work/'artifact')
        else:
            raise SystemExit(f'Unsupported donor path: {donor}')

        with zipfile.ZipFile(ipa) as archive:
            demand(archive.testzip() is None, 'Donor IPA ZIP is corrupt')
            names=archive.namelist()
            apps=sorted({
                name.split('/')[1]
                for name in names
                if name.startswith('Payload/')
                and len(name.split('/'))>2
                and name.split('/')[1].endswith('.app')
            })
            demand(len(apps)==1, f'Expected one donor application, found {apps}')
            archive.extractall(work/'ipa')

        app=work/'ipa'/'Payload'/apps[0]
        stik=app/'Frameworks/StikJIT.framework'
        dolphin=app/'Frameworks/DolphinCore.framework'
        rpcs3=app/'Frameworks/libRPCS3Core.dylib'
        dolphin_bridge=app/'Frameworks/dolphin_internal_bridge.framework'

        for required in (stik/'StikJIT', dolphin/'DolphinCore', rpcs3):
            demand(required.is_file(), f'Missing donor runtime: {required}')

        demand(sha(dolphin/'DolphinCore')==DOLPHIN_SHA, 'DolphinCore donor hash mismatch')
        demand(sha(rpcs3)==RPCS3_SHA, 'RPCS3Core donor hash mismatch')
        demand(sha(stik/'universal.js')==UNIVERSAL_SHA, 'StikJIT universal.js donor hash mismatch')
        demand(sha(stik/'legacy.js')==LEGACY_SHA, 'StikJIT legacy.js donor hash mismatch')

        official_root=work/'official-stik'
        with zipfile.ZipFile(official_stik) as archive:
            demand(archive.testzip() is None, 'Official StikJIT archive is corrupt')
            archive.extractall(official_root)
        official_items=list(official_root.rglob('StikJIT.xcframework'))
        demand(
            len(official_items)==1,
            f'Expected one official StikJIT XCFramework, found {official_items}',
        )
        xcframework=work/'StikJIT.xcframework'
        copytree(official_items[0], xcframework)
        normalized_interfaces=normalize_swift_interfaces(xcframework)
        device=device_framework(xcframework)
        demand((device/'Modules').is_dir(), 'Official StikJIT Swift module is missing')

        # Keep the official compile-time module shell but execute the exact
        # runtime bytes validated in the donor IPA.
        shutil.copy2(stik/'StikJIT', device/'StikJIT')
        (device/'StikJIT').chmod(0o755)
        for script_name, expected in (
            ('universal.js', UNIVERSAL_SHA),
            ('legacy.js', LEGACY_SHA),
        ):
            shutil.copy2(stik/script_name, device/script_name)
            demand(sha(device/script_name)==expected, f'Patched {script_name} hash mismatch')
        if (stik/'Info.plist').is_file():
            shutil.copy2(stik/'Info.plist', device/'Info.plist')

        # Keep one verified compile-time StikJIT XCFramework. Both helper
        # targets resolve this same module instead of compiling duplicate copies.
        copytree(
            xcframework,
            ROOT/'packages/stikjit_bridge/ios/Frameworks/StikJIT.xcframework',
        )

        dolphin_dst=ROOT/'packages/dolphin_internal_bridge/ios/Frameworks/DolphinCore.framework'
        copytree(dolphin, dolphin_dst)
        # zipfile extraction does not reliably restore POSIX executable bits.
        # Restore the verified donor Mach-O mode before Xcode/IPA packaging.
        (dolphin_dst/'DolphinCore').chmod(0o755)
        info_path=dolphin_dst/'Info.plist'
        if info_path.is_file():
            info=plistlib.loads(info_path.read_bytes())
            info['CFBundleVersion']=str(args.build_number)
            info_path.write_bytes(
                plistlib.dumps(info, fmt=plistlib.FMT_XML, sort_keys=False)
            )

        core_dst=ROOT/'packages/rpcs3_internal_bridge/ios/Frameworks/libRPCS3Core.dylib'
        core_dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(rpcs3, core_dst)
        core_dst.chmod(0o755)

        sys_src=app/'Sys'
        sys_dst=ROOT/'ios/Runner/Sys'
        demand(sys_src.is_dir(), 'Donor Dolphin Sys resources missing')
        copytree(sys_src, sys_dst)

        touch_dst=ROOT/'packages/dolphin_internal_bridge/ios/TouchResources'
        if touch_dst.exists():
            shutil.rmtree(touch_dst)
        touch_dst.mkdir(parents=True)
        demand(dolphin_bridge.is_dir(), 'Donor Dolphin bridge framework missing')
        copied=0
        for child in dolphin_bridge.iterdir():
            if child.suffix=='.png' or child.name.endswith('.nib'):
                target=touch_dst/child.name
                if child.is_dir():
                    shutil.copytree(child, target)
                else:
                    shutil.copy2(child, target)
                copied+=1
        demand(copied>0, 'No Dolphin touchscreen resources found in donor framework')

        logs=ROOT/'build/dolphin-ci'
        logs.mkdir(parents=True, exist_ok=True)
        stik_binary_sha=sha(stik/'StikJIT')
        release={
            'release':'1.5.0',
            'sourceRevision':'640fac91de403fdb85a3778aa0bbb7f30737b74c',
            'donorRun':35321768668,
            'binarySha256':stik_binary_sha,
            'universalJsSha256':UNIVERSAL_SHA,
            'legacyJsSha256':LEGACY_SHA,
            'platform':'ios-arm64',
            'officialInterfaceArchiveSha256':OFFICIAL_STIK_ZIP_SHA,
            'normalizedSwiftInterfaces':normalized_interfaces,
            'fastReuse':True,
        }
        (logs/'stikjit-release.json').write_text(
            json.dumps(release, indent=2)+'\n'
        )

        identity=ROOT/'build/fast-native/identity.json'
        identity.parent.mkdir(parents=True, exist_ok=True)
        identity.write_text(json.dumps({
            'donorIpa':ipa.name,
            'donorRun':35321768668,
            'officialInterfaceArchiveSha256':OFFICIAL_STIK_ZIP_SHA,
            'normalizedSwiftInterfaces':normalized_interfaces,
            'stikjitBinarySha256':stik_binary_sha,
            'universalJsSha256':sha(stik/'universal.js'),
            'legacyJsSha256':sha(stik/'legacy.js'),
            'dolphinCoreSha256':sha(dolphin/'DolphinCore'),
            'rpcs3CoreSha256':sha(rpcs3),
            'touchResourcesCopied':copied,
        }, indent=2)+'\n')
        print(identity.read_text())


if __name__=='__main__':
    main()
