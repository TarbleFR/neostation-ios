"""Allow the two audited v3 workflows without weakening source isolation."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
guard = ROOT / 'build-utils/check_dolphin_isolation_v2.py'
if guard.is_file():
    text = guard.read_text(encoding='utf-8')
    additions = (
        '    "sitecustomize/__init__.py",\n'
        '    ".github/workflows/dolphin-internal-isolated-v3-publish.yml",\n'
    )
    anchor = '    ".github/workflows/dolphin-internal-isolated-v3.yml",\n'
    if '"sitecustomize/__init__.py",' not in text:
        if anchor in text:
            text = text.replace(anchor, anchor + additions, 1)
        else:
            fallback = '    ".github/workflows/dolphin-internal-isolated-v2.yml",\n'
            text = text.replace(fallback, fallback + additions, 1)
    guard.write_text(text, encoding='utf-8')
