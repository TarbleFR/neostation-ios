#!/usr/bin/env python3
"""Reject mislabeled/stale StikJIT or missing compatibility helpers in an IPA."""
from pathlib import Path
import argparse
import hashlib
import json
import plistlib
import sys
import zipfile

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'packages/dolphin_internal_bridge/ci'))
from verify_ipa import macho

p=argparse.ArgumentParser()
p.add_argument('ipa',type=Path)
p.add_argument('--identity',type=Path,required=True)
p.add_argument('--report',type=Path,required=True)
a=p.parse_args()
identity=json.loads(a.identity.read_text())
pin=json.loads((ROOT/'build-utils/stikjit/source.json').read_text())
assert identity['release']==pin['version']=='1.9.0'
assert identity['sourceRevision']==pin['revision']
with zipfile.ZipFile(a.ipa) as z:
    apps={n.split('/')[1] for n in z.namelist() if n.startswith('Payload/') and len(n.split('/'))>2 and n.split('/')[1].endswith('.app')}
    assert len(apps)==1,apps
    app='Payload/'+apps.pop()+'/'
    prefix=app+'Frameworks/StikJIT.framework/'
    binary=z.read(prefix+'StikJIT')
    digest=hashlib.sha256(binary).hexdigest()
    assert digest==identity['binarySha256'], 'StikJIT binary does not match tested native artifact'
    info=plistlib.loads(z.read(prefix+'Info.plist'))
    assert info['CFBundleShortVersionString']=='1.9.0'
    image=macho(binary)
    assert image['platform']==2 and image['architecture']=='arm64'
    assert tuple(map(int,image['minimumOS'].split('.'))) <= (18,0,0)
    for marker in (pin['classic_attach_marker'],pin['transport_marker']):
        assert marker.encode() in binary,marker
    for symbol in identity['dynamicFFIExports']:
        assert '_'+symbol in image['definedSymbols'],symbol
    for script,key in (('universal.js','universalJsSha256'),('legacy.js','legacyJsSha256')):
        assert hashlib.sha256(z.read(prefix+script)).hexdigest()==identity[key]
    helpers={}
    for name in ('RPCS3JITHelper','ARMSX2JITHelper','DolphinJITHelper'):
        base=app+'PlugIns/'+name+'.appex/'
        meta=plistlib.loads(z.read(base+'Info.plist'))
        data=z.read(base+meta['CFBundleExecutable'])
        native=macho(data)
        assert native['platform']==2
        assert tuple(map(int,native['minimumOS'].split('.'))) <= (18,0,0)
        if name!='DolphinJITHelper':
            assert b'PAIRING_FORMAT_INVALID' in data,name
            assert b'classic-attach-detach' in data,name
            assert b'universal-handshake' in data,name
        helpers[name]={'minimumOS':native['minimumOS'],'sha256':hashlib.sha256(data).hexdigest()}
    for lower in ('rpcs3','armsx2'):
        source=ROOT/f'packages/{lower}_jit_helper/ios/Resources/{lower}-universal.js'
        name=lower+'-universal.js'
        matches=[n for n in z.namelist() if n.endswith('/'+name)]
        assert matches and all(z.read(n)==source.read_bytes() for n in matches),name
report={'stikjitVersion':'1.9.0','sourceRevision':pin['revision'],
        'binarySha256':digest,'minimumOS':image['minimumOS'],
        'dynamicFFIExportCount':len(identity['dynamicFFIExports']),
        'helpers':helpers,'customCoreScriptsUnchanged':True,
        'realDeviceValidated':False}
a.report.parent.mkdir(parents=True,exist_ok=True)
a.report.write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
