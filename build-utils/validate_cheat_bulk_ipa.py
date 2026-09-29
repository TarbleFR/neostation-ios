from pathlib import Path
import argparse
import hashlib
import json
import plistlib
import zipfile
p=argparse.ArgumentParser();p.add_argument('ipa',type=Path);p.add_argument('--report',type=Path,required=True);p.add_argument('--build-number',type=int,default=365);a=p.parse_args()
assert a.build_number>0, 'Expected a positive build number'
with zipfile.ZipFile(a.ipa) as z:
    apps={n.split('/')[1] for n in z.namelist() if n.startswith('Payload/') and len(n.split('/'))>2 and n.split('/')[1].endswith('.app')}
    assert len(apps)==1
    root='Payload/'+apps.pop()+'/'
    info=plistlib.loads(z.read(root+'Info.plist'))
    assert info['CFBundleShortVersionString']=='0.0.2' and info['CFBundleVersion']==str(a.build_number), 'Unexpected application version/build'
    bridges={}
    for bridge in ('dolphin_internal_bridge','armsx2_internal_bridge'):
        binary=z.read(root+f'Frameworks/{bridge}.framework/{bridge}')
        for token in (b'cheatImportFromMenu',b'cheatImportPreview',b'batchImport',b'displayDocument:',b'importCheatFilePressed',b'previewEntries'):
            assert token in binary,(bridge,token)
        bridges[bridge]=hashlib.sha256(binary).hexdigest()
report={'version':'0.0.2','build':a.build_number,'feature':'Named bulk cheat import',
        'compiledBothEditors':True,'frameworksSha256':bridges,
        'ipaSha256':hashlib.sha256(a.ipa.read_bytes()).hexdigest(),
        'testerOriginalFileProvided':False,'realDeviceValidated':False}
a.report.parent.mkdir(parents=True,exist_ok=True);a.report.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
