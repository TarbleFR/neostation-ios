"""Regression: Build366 passed compilation but a stale365 delivery gate rejected it."""
from pathlib import Path
import json,plistlib,subprocess,sys,tempfile,zipfile
ROOT=Path(__file__).resolve().parents[1]
TOKENS=b'cheatImportFromMenu cheatImportPreview batchImport displayDocument: importCheatFilePressed previewEntries'
with tempfile.TemporaryDirectory() as folder:
    directory=Path(folder)
    def run(build,expected=None,missing=False,version='0.0.2'):
        ipa=directory/'candidate.ipa';report=directory/'report.json';report.unlink(missing_ok=True)
        with zipfile.ZipFile(ipa,'w') as z:
            root='Payload/NeoStation.app/'
            z.writestr(root+'Info.plist',plistlib.dumps({'CFBundleShortVersionString':version,'CFBundleVersion':str(build)}))
            for bridge in ('dolphin_internal_bridge','armsx2_internal_bridge'):
                z.writestr(root+f'Frameworks/{bridge}.framework/{bridge}',TOKENS.replace(b'previewEntries',b'') if missing else TOKENS)
        args=[sys.executable,str(ROOT/'build-utils/validate_cheat_bulk_ipa.py'),str(ipa),'--report',str(report)]
        if expected is not None:args+=['--build-number',str(expected)]
        result=subprocess.run(args,capture_output=True,text=True)
        return result.returncode,json.loads(report.read_text()) if report.exists() else None
    assert run(365)[0]==0
    code,report=run(366,366);assert code==0 and report['build']==366
    assert run(365,366)[0]!=0
    assert run(366)[0]!=0
    assert run(366,366,missing=True)[0]!=0
    assert run(366,366,version='0.0.3')[0]!=0
print('PASS IPA gate: explicit expected build, legacy365 default, wrong build/version and missing binaries rejected')
