"""Device delivery provenance, exact cache checks, signing and measured phases."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/delivery'
OUT.mkdir(parents=True, exist_ok=True)

def run(*args):
    return subprocess.check_output(args, stderr=subprocess.STDOUT).decode().strip()

def sha(data):
    return hashlib.sha256(data).hexdigest()

def environment():
    xcode = run('xcodebuild', '-version')
    if not xcode.startswith('Xcode 26.3\n'):
        raise ValueError('Unexpected Xcode version: ' + xcode)
    result = {'commit': os.environ['GITHUB_SHA'], 'build': os.environ['BUILD_NUMBER'],
              'mode': os.environ['DELIVERY_MODE'], 'xcode': xcode,
              'flutter': json.loads(run('flutter', '--version', '--machine')),
              'sdk': run('xcrun', '--sdk', 'iphoneos', '--show-sdk-version'),
              'cpu': run('sysctl', '-n', 'hw.logicalcpu'),
              'ramBytes': run('sysctl', '-n', 'hw.memsize'),
              'macOS': run('sw_vers', '-productVersion'),
              'cocoaPods': run('pod', '--version'),
              'ruby': run('ruby', '--version')}
    (OUT / 'environment.json').write_text(json.dumps(result, indent=2) + '\n')

def cache_inputs():
    defines = {k: os.environ.get(k, '').strip() for k in ('SCREENSCRAPER_DEV_ID','SCREENSCRAPER_DEV_PASSWORD')}
    defines.update(NEOSTATION_EXPERIMENTAL_STIKJIT_MELONX='true', NEOSTATION_MELONX_BUNDLE_ID='com.nur.nx')
    env = json.loads((OUT / 'environment.json').read_text())
    return {'commit': os.environ['GITHUB_SHA'], 'build': os.environ['BUILD_NUMBER'],
            'xcode': env['xcode'], 'sdk': env['sdk'], 'cocoaPods': env['cocoaPods'],
            'flutterVersion': env['flutter']['frameworkVersion'], 'ruby': env['ruby'],
            'definesSha256': sha(json.dumps(defines,sort_keys=True).encode()),
            'pubLockSha256': sha((ROOT / 'pubspec.lock').read_bytes())}

def record_inputs():
    # Mask encoded define values before Xcode prints generated environment.
    import base64
    for key,value in json.loads((ROOT / '.dart-defines.json').read_text()).items():
        print('::add-mask::' + base64.b64encode(f'{key}={value}'.encode()).decode())
    expected = ROOT / 'build/fast-native/delivery-cache-inputs.json'
    expected.write_text(json.dumps(cache_inputs(),sort_keys=True,indent=2) + '\n')

def check_cache():
    previous = json.loads((ROOT / 'build/fast-native/delivery-cache-inputs.json').read_text())
    if previous != cache_inputs():
        raise ValueError('Cached compilation inputs, SDK or secret defines differ')

def source_times(restore=False):
    """Preserve metadata only after verifying the exact tracked source bytes."""
    manifest=ROOT/'build/fast-native/source-times.json'
    if restore:
        records=json.loads(manifest.read_text())
        for name,record in records.items():
            path=ROOT/name
            if path.is_symlink() or not path.is_file() or sha(path.read_bytes())!=record['sha256']:
                raise ValueError('Cached source identity changed: '+name)
        for name,record in records.items():
            os.utime(ROOT/name,ns=(record['mtimeNS'],record['mtimeNS']))
    else:
        names=subprocess.check_output(['git','ls-files','-z','lib','packages','native','assets','pubspec.yaml','pubspec.lock'],cwd=ROOT).decode().split('\0')
        records={name:{'sha256':sha((ROOT/name).read_bytes()),'mtimeNS':(ROOT/name).stat().st_mtime_ns}
                 for name in names if name and (ROOT/name).is_file() and not (ROOT/name).is_symlink()}
        manifest.parent.mkdir(parents=True,exist_ok=True)
        manifest.write_text(json.dumps(records,sort_keys=True)+'\n')

def payload_fingerprint(data):
    """Seal code/data sections and ABI metadata; code signatures may differ."""
    if data[:4] != b'\xcf\xfa\xed\xfe':
        raise ValueError('Expected thin ARM64 delivery image')
    ncmds = struct.unpack_from('<I', data,16)[0]
    cursor = 32
    sections = {}
    for _ in range(ncmds):
        command,size = struct.unpack_from('<II',data,cursor)
        if command == 0x19:
            count = struct.unpack_from('<I',data,cursor+64)[0]
            for index in range(count):
                pos = cursor+72+80*index
                section,segment = struct.unpack_from('<16s16s',data,pos)
                length = struct.unpack_from('<Q',data,pos+40)[0]
                offset = struct.unpack_from('<I',data,pos+48)[0]
                if offset and length:
                    sections[(segment+section).hex()] = sha(data[offset:offset+length])
        cursor += size
    sys.path.insert(0,str(ROOT / 'packages/dolphin_internal_bridge/ci'))
    from verify_ipa import macho
    image=macho(data)
    return sha(json.dumps({'sections':sections,
        'symbols':image['definedSymbols'],'dependencies':image['dependencies'],
        'rpaths':image['rpaths'],'platform':image['platform'],
        'minimumOS':image['minimumOS'],'id':image['id']},sort_keys=True).encode())

def seal():
    stage = ROOT / 'build/ios/dolphin-unsigned'
    app = stage / 'Payload/NeoStation.app'
    images = {str(p.relative_to(app)):payload_fingerprint(p.read_bytes())
              for p in app.rglob('*') if p.is_file() and p.suffix not in ('.json', '.png', '.ttf', '.zip') and p.read_bytes()[:4] == b'\xcf\xfa\xed\xfe'}
    from sign_delivery import sign
    sign(app,OUT / 'signature.json')
    after={name:payload_fingerprint((app / name).read_bytes()) for name in images}
    if images != after:
        raise ValueError('Signing changed compiled code, data or ABI metadata')
    # A single sealed staging bundle is reused for the compatible IPA export.
    ipa=ROOT / 'dist/NeoStation.ipa'
    ipa.unlink()
    subprocess.run(['/usr/bin/zip','-qry',str(ipa),'Payload'],cwd=stage,check=True)
    subprocess.run(['unzip','-tq',str(ipa)],check=True)
    # Verify signatures against the actual final ZIP bytes, not only staging.
    import tempfile,zipfile
    with tempfile.TemporaryDirectory() as tmp:
        with zipfile.ZipFile(ipa) as z: z.extractall(tmp)
        unpacked=Path(tmp)/'Payload/NeoStation.app'
        for item in unpacked.rglob('*'):
            if item.is_file() and item.read_bytes()[:4] == b'\xcf\xfa\xed\xfe':
                item.chmod(0o755)
        subprocess.run(['codesign','--verify','--deep','--strict','--verbose=2',str(unpacked)],check=True)
    sys.path.insert(0,str(ROOT / 'packages/dolphin_internal_bridge/ci'))
    from verify_ipa import validate
    structural = validate(ipa)
    (OUT / 'final-structure.json').write_text(json.dumps(structural,indent=2)+'\n')
    (OUT / 'signed-payload-identity.json').write_text(json.dumps({
        'allCompiledCodeAndDataSectionsUnchangedBySigning':True,
        'abiMetadataUnchangedBySigning':True,'images':images,
        'ipaSha256':sha(ipa.read_bytes()),'ipaBytes':ipa.stat().st_size,
        'sideStoreAppleReSigningRequired':True},indent=2)+'\n')

def report():
    timings=Path(os.environ['DELIVERY_METRICS'])
    rows=[json.loads(line) for line in timings.read_text().splitlines()] if timings.exists() else []
    perf=Path(os.environ['RUNNER_TEMP'])/'flutter-aot-timings.json'
    xcode=Path(os.environ['RUNNER_TEMP'])/'neostation-fast-xcodebuild.log'
    summary=xcode.read_text().rsplit('Build Timing Summary',1)[-1][-7000:] if xcode.exists() else None
    result={'mode':os.environ['DELIVERY_MODE'],'commit':os.environ['GITHUB_SHA'],
            'phases':rows,'flutterTargets':json.loads(perf.read_text()) if perf.exists() else None,
            'xcodeTaskTimingSummary':summary,
            'archive':'SideStore exports the one sealed Payload directly; no Apple exportArchive without profiles',
            'deviceInstallationTested':False,'retroArchGameplayTested':False}
    (OUT / 'observed-timings.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({'mode':result['mode'],'phases':rows},indent=2))

if __name__ == '__main__':
    {'environment':environment,'record-inputs':record_inputs,'check-cache':check_cache,
     'record-source-times':source_times,'restore-source-times':lambda:source_times(True),
     'seal':seal,'report':report}[sys.argv[1]]()
