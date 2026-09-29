from pathlib import Path
import sys
import tempfile
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'build-utils'))
from dolphin_motion_localizations import stage,STRINGS
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
print('PASS: 12 privacy localizations; byte-identical repeat; unrelated strings preserved')
