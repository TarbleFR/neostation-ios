#!/usr/bin/env python3
"""Install immutable native bootstrap assets from the validated Build 350 IPA.

Fast experimental builds reuse native Core and UI resources from the stable
baseline, never its JIT framework. RPCS3Core and DolphinCore are temporary bootstrap inputs here and are
replaced by separately pinned, hash-verified artifacts before Xcode consumes
them. StikJIT is built separately from the canonical source pin; neither its
binary, scripts nor Swift interfaces are transplanted from a donor.
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
DOLPHIN_SHA='7129d9c654fb6d28f2fa92ae1a4c14d1f25a1fc3e87788237676b48a0fb3aa2d'
RPCS3_SHA='4866265eca27327c3fc9be14190fec082b58a5e1946f541ced34e46c13ceabd9'
ARMSX2_SHA='cadb6cd56c4b5d01b623bf9696800d48ba504eef8129a8de468c11381de8d162'
DUSKLIGHT_SHA='5a64e2fd48c47831fd07306c90e28036535a125bd887149d92ba4567ac9af8a7'
DONOR_RUN_ID=36323843067
DONOR_ARTIFACT_ID=10932894067


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


def main() -> None:
    parser=argparse.ArgumentParser()
    parser.add_argument('artifact', type=Path)
    parser.add_argument('--build-number', required=True)
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
        dolphin=app/'Frameworks/DolphinCore.framework'
        rpcs3=app/'Frameworks/libRPCS3Core.dylib'
        armsx2=app/'Frameworks/ARMSX2Core.framework'
        dusklight=app/'Frameworks/DusklightCore.framework'
        dusklight_identity=app/'Dusklight-native-identity.json'
        dusklight_licenses=app/'Dusklight-Licenses'
        dolphin_bridge=app/'Frameworks/dolphin_internal_bridge.framework'

        for required in (
            dolphin/'DolphinCore', rpcs3,
            armsx2/'ARMSX2Core', dusklight/'DusklightCore',
            dusklight_identity, app/'cacert.pem',
        ):
            demand(required.is_file(), f'Missing donor runtime: {required}')
        demand(dusklight_licenses.is_dir(), 'Donor Dusklight notices are missing')

        demand(sha(dolphin/'DolphinCore')==DOLPHIN_SHA, 'DolphinCore donor hash mismatch')
        demand(sha(rpcs3)==RPCS3_SHA, 'RPCS3Core donor hash mismatch')
        demand(sha(armsx2/'ARMSX2Core')==ARMSX2_SHA, 'ARMSX2Core donor hash mismatch')
        demand(sha(dusklight/'DusklightCore')==DUSKLIGHT_SHA, 'DusklightCore donor hash mismatch')
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

        armsx2_root=ROOT/'dist/armsx2'
        if armsx2_root.exists():
            shutil.rmtree(armsx2_root)
        copytree(armsx2, armsx2_root/'ARMSX2Core.framework')
        (armsx2_root/'ARMSX2Core.framework/ARMSX2Core').chmod(0o755)
        armsx2_source=json.loads((ROOT/'build-utils/armsx2/source.json').read_text())
        (armsx2_root/'identity.json').write_text(json.dumps({
            'host_commit':'82351b75114df5fb33387f2157745bccaf1c872d',
            'revision':armsx2_source['revision'],
            'abi_version':armsx2_source['abi_version'],
            'architectures':['arm64'],
            'sha256':ARMSX2_SHA,
            'donor_run':DONOR_RUN_ID,
            'donor_artifact':DONOR_ARTIFACT_ID,
        }, indent=2)+'\n')

        dusklight_root=ROOT/'dist/dusklight'
        if dusklight_root.exists():
            shutil.rmtree(dusklight_root)
        copytree(dusklight, dusklight_root/'DusklightCore.framework')
        (dusklight_root/'DusklightCore.framework/DusklightCore').chmod(0o755)
        copytree(dusklight_licenses, dusklight_root/'licenses')
        shutil.copy2(dusklight_identity, dusklight_root/'identity.json')
        donor_dusklight=json.loads(dusklight_identity.read_text())
        demand(
            donor_dusklight.get('host_commit') ==
            '4de572747e794d69756fda5db761a7650e98e9f6',
            'Dusklight donor host commit mismatch',
        )
        demand(donor_dusklight.get('abi_version') == 7,
               'Dusklight donor ABI mismatch')
        demand(donor_dusklight.get('sha256') == DUSKLIGHT_SHA,
               'Dusklight donor identity hash mismatch')

        sys_src=app/'Sys'
        sys_dst=ROOT/'ios/Runner/Sys'
        demand(sys_src.is_dir(), 'Donor Dolphin Sys resources missing')
        copytree(sys_src, sys_dst)
        shutil.copy2(app/'cacert.pem', ROOT/'ios/Runner/cacert.pem')

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

        identity=ROOT/'build/fast-native/identity.json'
        identity.parent.mkdir(parents=True, exist_ok=True)
        identity.write_text(json.dumps({
            'donorIpa':ipa.name,
            'donorRun':DONOR_RUN_ID,
            'donorArtifact':DONOR_ARTIFACT_ID,
            'dolphinCoreSha256':sha(dolphin/'DolphinCore'),
            'armsx2CoreSha256':sha(armsx2/'ARMSX2Core'),
            'dusklightCoreSha256':sha(dusklight/'DusklightCore'),
            'rpcs3CoreSha256':sha(rpcs3),
            'touchResourcesCopied':copied,
        }, indent=2)+'\n')
        print(identity.read_text())


if __name__=='__main__':
    main()
