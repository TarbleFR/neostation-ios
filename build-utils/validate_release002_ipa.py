#!/usr/bin/env python3
"""Check requested version, compiled features, localization and source provenance."""
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
p.add_argument('ipa',type=Path);p.add_argument('--build-number',required=True)
p.add_argument('--report',type=Path,required=True);a=p.parse_args()
strings=json.loads((ROOT/'native/dolphin_motion/strings.json').read_text())
pin=json.loads((ROOT/'build-utils/stikjit/source.json').read_text())
with zipfile.ZipFile(a.ipa) as z:
    assert z.testzip() is None
    apps={n.split('/')[1] for n in z.namelist() if n.startswith('Payload/') and len(n.split('/'))>2 and n.split('/')[1].endswith('.app')}
    assert len(apps)==1
    app='Payload/'+apps.pop()+'/'
    info=plistlib.loads(z.read(app+'Info.plist'))
    assert info['CFBundleShortVersionString']=='0.0.2'
    assert info['CFBundleVersion']==a.build_number
    assert info['NSMotionUsageDescription']==strings['en']['usage']
    for name in ('RPCS3JITHelper','ARMSX2JITHelper','DolphinJITHelper'):
        helper=plistlib.loads(z.read(app+'PlugIns/'+name+'.appex/Info.plist'))
        assert helper['CFBundleShortVersionString']=='0.0.2',name
        assert helper['CFBundleVersion']==a.build_number,name
    locales={}
    for language,row in strings.items():
        ios_language={'zh':'zh-Hans','zh_Hant':'zh-Hant'}.get(language,language)
        data=z.read(app+ios_language+'.lproj/InfoPlist.strings')
        if data.startswith(b'bplist') or data.startswith(b'<?xml'):
            assert plistlib.loads(data)['NSMotionUsageDescription']==row['usage']
        else:
            if data.startswith(b'\xff\xfe') or data.startswith(b'\xfe\xff'):
                decoded=data.decode('utf-16')
            else: decoded=data.decode('utf-8')
            assert row['usage'] in decoded,language
        locales[language]=True
    binary=z.read(app+'Frameworks/dolphin_internal_bridge.framework/dolphin_internal_bridge')
    for marker in (b'DolphinPhoneShake',b'NeoStation.Dolphin.PhoneShake.Enabled',
                   b'NeoStation.Dolphin.PhoneShakeChanged',b'DolphinFramePacing',b'setPreferredFrameRateRange:'):
        assert marker in binary,marker
    assert 'Rétablir le comportement de la Build 361'.encode() not in binary
    image=macho(binary)
    assert any('CoreMotion.framework/CoreMotion' in d['path'] for d in image['dependencies'])
    provenance=json.loads(z.read(app+'Frameworks/StikJIT.framework/NeoStation-StikJIT-source.json'))
    assert provenance['revision']==pin['revision'] and provenance['version']==pin['version']
    assert provenance['verifiedCheckout']==pin['revision']
    from build_patched_stikjit import input_fingerprint
    assert provenance['sourceInputsSha256']==input_fingerprint()
report={'appVersion':'0.0.2','build':a.build_number,'deliveryFilename':'Neostation iOS 0.0.2.ipa',
        'shakeCompiled':True,'coreMotionLinked':True,'motionLocales':locales,
        'obsoleteRestoreActionRemoved':True,'stikjitProvenance':provenance,
        'realDeviceValidated':False,'ipaSha256':hashlib.sha256(a.ipa.read_bytes()).hexdigest()}
a.report.parent.mkdir(parents=True,exist_ok=True)
a.report.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
