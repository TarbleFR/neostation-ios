#!/usr/bin/env python3
"""Extract only pinned App Store-subset cores, never the IPA executable."""
import argparse
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import stat
import struct
import tempfile
import zipfile

PINS_PATH = Path(__file__).with_name('source.json')
PINS = json.loads(PINS_PATH.read_text())
FORBIDDEN = {'dolphin','azahar','citra','cemu','pcsx2','play','flycast','ppsspp','mupen64plus_next','melonds','melondsds'}


def digest(data): return hashlib.sha256(data).hexdigest()


def safe_name(info):
    path=PurePosixPath(info.filename)
    if path.is_absolute() or '..' in path.parts or '\\' in info.filename:
        raise ValueError(f'Unsafe ZIP path: {info.filename}')
    if stat.S_ISLNK(info.external_attr >> 16): raise ValueError(f'Symlink ZIP entry: {info.filename}')
    return path


def macho(data):
    if len(data) < 32: raise ValueError('Truncated Mach-O')
    # The supplied signed frameworks use FAT containers with exactly one arm64
    # device slice. Preserve their bytes/signature; do not thin and rebrand them.
    if struct.unpack_from('>I',data)[0] == 0xcafebabe:
        count=struct.unpack_from('>I',data,4)[0]
        if count != 1: raise ValueError('Curated core must have only one arm64 slice')
        cpu,subtype,offset,length,alignment=struct.unpack_from('>5I',data,8)
        if cpu!=0x0100000c or offset+length>len(data): raise ValueError('Invalid FAT arm64 slice')
        return macho(data[offset:offset+length])
    magic,cpu,subtype,kind,commands,command_bytes,flags,reserved=struct.unpack_from('<8I',data)
    if magic!=0xfeedfacf or cpu!=0x0100000c or kind!=6:
        raise ValueError(f'Expected thin arm64 MH_DYLIB, got magic={magic:x} cpu={cpu:x} type={kind}')
    cursor=32;platform=None;minimum=None;dependencies=[];install_name=None
    if cursor+command_bytes>len(data): raise ValueError('Truncated Mach-O load commands')
    for i in range(commands):
        cmd,size=struct.unpack_from('<II',data,cursor)
        if size<8 or cursor+size>32+command_bytes: raise ValueError('Invalid Mach-O load command')
        if cmd==0x32:
            platform,minos,sdk=struct.unpack_from('<III',data,cursor+8)
            minimum=f'{minos>>16}.{(minos>>8)&255}.{minos&255}'
        elif cmd==0x25:
            platform=2;minos=struct.unpack_from('<I',data,cursor+8)[0]
            minimum=f'{minos>>16}.{(minos>>8)&255}.{minos&255}'
        if cmd in {0xc,0x18|0x80000000,0x1f|0x80000000,0xd}:
            off=struct.unpack_from('<I',data,cursor+8)[0]
            value=data[cursor+off:cursor+size].split(b'\0')[0].decode()
            if cmd==0xd: install_name=value
            else: dependencies.append(value)
        cursor+=size
    if platform!=2: raise ValueError(f'Expected device iOS binary, platform={platform}')
    for dep in dependencies:
        if not dep.startswith(('/usr/lib/','/System/Library/Frameworks/','/System/Library/PrivateFrameworks/','@rpath/')):
            raise ValueError(f'Host-only Mach-O dependency: {dep}')
        if dep.startswith('/System/Library/PrivateFrameworks/'):
            raise ValueError(f'Private framework dependency: {dep}')
    return {'architectures':['arm64'],'platform':'iOS','minimumOS':minimum,'installName':install_name,'dependencies':dependencies}


def appstore_ids(upstream):
    text=(upstream/'pkg/apple/update-cores.sh').read_text()
    body=re.search(r'^appstore_cores=\(\s*(.*?)^\)',text,re.M|re.S)
    if not body: raise ValueError('Pinned upstream App Store allowlist missing')
    return {line.split('#',1)[0].strip() for line in body.group(1).splitlines() if line.split('#',1)[0].strip()}


def parse_info(data):
    text=data.decode('utf-8')
    return {m.group(1):m.group(2) for m in re.finditer(r'^\s*(\w+)\s*=\s*"([^"\r\n]*)"',text,re.M)}


def extract(ipa,output,upstream):
    with ipa.open('rb') as stream: actual=hashlib.file_digest(stream,'sha256').hexdigest()
    if actual!=PINS['sourceIpa']['sha256'] or ipa.stat().st_size!=PINS['sourceIpa']['bytes']:
        raise ValueError(f'Supplied IPA hash/length mismatch: {actual}')
    allowed=appstore_ids(upstream)
    ids={c['id'] for c in PINS['cores']}
    if ids & FORBIDDEN or not ids <= allowed: raise ValueError('Curated manifest has forbidden/non-App Store cores')
    if output.exists(): raise ValueError(f'Output already exists: {output}')
    output.parent.mkdir(parents=True,exist_ok=True)
    work=Path(tempfile.mkdtemp(prefix='retroarch-package-',dir=output.parent))
    try:
        with zipfile.ZipFile(ipa) as archive:
            for entry in archive.infolist(): safe_name(entry)
            prefix='Payload/RetroArch.app/'
            meta=plistlib.loads(archive.read(prefix+'Info.plist'))
            if meta['CFBundleVersion']!=PINS['sourceIpa']['bundleVersion']: raise ValueError('IPA version mismatch')
            assets=zipfile.ZipFile(io.BytesIO(archive.read(prefix+'assets.zip')))
            framework_paths={str(PurePosixPath(c['binary']).parent) for c in PINS['cores']}
            for entry in archive.infolist():
                name=safe_name(entry)
                if entry.is_dir(): continue
                relative=str(name).removeprefix(prefix)
                if not any(relative.startswith(p+'/') for p in framework_paths): continue
                path=work/relative;path.parent.mkdir(parents=True,exist_ok=True)
                path.write_bytes(archive.read(entry))
                path.chmod((entry.external_attr >> 16) & 0o777 or 0o644)
            cores=[]
            resources=work/'Resources'/'RetroArchResources'
            for core in PINS['cores']:
                binary=work/core['binary'];data=binary.read_bytes()
                if digest(data)!=core['sha256']: raise ValueError(f'Core identity mismatch: {core["id"]}')
                info=assets.read(core['info'])
                if digest(info)!=core['infoSha256']: raise ValueError(f'Core info identity mismatch: {core["id"]}')
                parsed=parse_info(info)
                if parsed.get('is_experimental','false').lower()!='false': raise ValueError(f'Experimental core: {core["id"]}')
                entry={**core,'macho':macho(data),'qualification':'requires-device-validation'}
                # Titles are only the curated engine names. Console routing is
                # determined by explicit systemIds, never info-file discovery.
                entry['title']={'fceumm':'FCEUmm','nestopia':'Nestopia','snes9x':'Snes9x','gambatte':'Gambatte','sameboy':'SameBoy',
                    'mgba':'mGBA','genesis_plus_gx':'Genesis Plus GX','picodrive':'PicoDrive','mednafen_pce_fast':'Beetle PCE FAST',
                    'pcsx_rearmed':'PCSX ReARMed','mednafen_psx':'Beetle PSX'}[core['id']]
                cores.append(entry)
            curated_info={c['info'] for c in cores}
            for entry in assets.infolist():
                name=safe_name(entry)
                if entry.is_dir(): continue
                if name.parts[0] not in {'assets','autoconfig','overlays','info'}: continue
                if name.parts[0]=='info' and str(name) not in curated_info: continue
                path=resources/str(name);path.parent.mkdir(parents=True,exist_ok=True)
                path.write_bytes(assets.read(entry))
            for directory in ('system','saves','states','config','shaders','overlays','cheats','logs','games'):
                (resources/directory).mkdir(parents=True,exist_ok=True)
            manifest={'schemaVersion':1,'sourceIpa':PINS['sourceIpa'],'frontend':PINS['frontend'],'cores':cores,
                'capabilities':{'shaderFormats':['glslp'],'shaderPackBundled':False,'overlayLoadCompletion':'async-command-result',
                    'saveStateFormat':'libretro-raw','coreUpdaterEnabled':False,'jitEnabled':False},
                'excludedCoreIds':sorted(FORBIDDEN)}
            (work/'Resources'/'retroarch-core-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
            licenses=work/'Resources'/'RetroArchResources'/'licenses';licenses.mkdir()
            for name in ('COPYING','README.md'):
                source=upstream/name
                if source.exists(): shutil.copy2(source,licenses/('RetroArch-'+name))
            (licenses/'core-license-identifiers.json').write_text(json.dumps({c['id']:c['license'] for c in cores},indent=2)+'\n')
        work.rename(output)
    except BaseException:
        shutil.rmtree(work,ignore_errors=True)
        raise
    return manifest


def verify(package):
    manifest=json.loads((package/'Resources'/'retroarch-core-manifest.json').read_text())
    expected={c['id'] for c in PINS['cores']}
    if {c['id'] for c in manifest['cores']}!=expected: raise ValueError('Package core selection differs from pins')
    framework_dirs={p.name for p in (package/'Frameworks').glob('*.framework')}
    expected_dirs={PurePosixPath(c['binary']).parts[1] for c in PINS['cores']}
    if framework_dirs!=expected_dirs: raise ValueError('Package includes missing or extra core frameworks')
    expected_info={PurePosixPath(c['info']).name for c in PINS['cores']}
    actual_info={p.name for p in (package/'Resources'/'RetroArchResources'/'info').glob('*.info')}
    if actual_info!=expected_info: raise ValueError('Package has uncurated core info')
    for core in PINS['cores']:
        data=(package/core['binary']).read_bytes()
        if digest(data)!=core['sha256']: raise ValueError(f'Core hash mismatch: {core["id"]}')
        macho(data)
        info=(package/'Resources'/'RetroArchResources'/core['info']).read_bytes()
        if digest(info)!=core['infoSha256']: raise ValueError(f'Core info hash mismatch: {core["id"]}')
    if (package/'Resources'/'RetroArch').exists() or (package/'RetroArch.app').exists(): raise ValueError('Standalone app was embedded')
    return {'success':True,'cores':len(expected),'sourceIpaSha256':PINS['sourceIpa']['sha256'],'frontendCommit':PINS['frontend']['commit']}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ipa',type=Path)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--upstream',type=Path)
    parser.add_argument('--verify-only',action='store_true')
    args=parser.parse_args()
    if not args.verify_only:
        if not args.ipa or not args.upstream: parser.error('--ipa and --upstream are required for extraction')
        extract(args.ipa.resolve(),args.output.resolve(),args.upstream.resolve())
    print(json.dumps(verify(args.output.resolve()),indent=2))

if __name__=='__main__': main()
