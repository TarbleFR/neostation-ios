from pathlib import Path
import sys
import tempfile
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'build-utils'))
from dolphin_motion_localizations import stage,STRINGS,render_header
root=Path(__file__).resolve().parents[1]
assert set(STRINGS)=={'en','es','ru','zh','zh_Hant','pt','fr','de','it','id','ja','ko'}
keys={'title','help','usage','routeFailed','sensorUnavailable'}
for language,strings in STRINGS.items():
    assert set(strings)==keys,language
    assert all(isinstance(value,str) and value.strip() for value in strings.values()),language
assert (root/'packages/dolphin_internal_bridge/ios/Classes/DolphinPhoneShakeLabels.h').read_text()==render_header()
with tempfile.TemporaryDirectory() as folder:
    root=Path(folder)
    (root/'fr.lproj').mkdir()
    (root/'fr.lproj/InfoPlist.strings').write_text('"CFBundleDisplayName" = "NeoStation";\n',encoding='utf-8')
    stage(root)
    before={str(p.relative_to(root)):p.read_bytes() for p in root.rglob('*.strings')}
    stage(root)
    after={str(p.relative_to(root)):p.read_bytes() for p in root.rglob('*.strings')}
    assert before==after and len(after)==12
    assert 'CFBundleDisplayName' in (root/'fr.lproj/InfoPlist.strings').read_text(encoding='utf-8')
print('PASS: 12 motion help/error/privacy localizations; generated header identical; repeatable staging preserves other strings')
