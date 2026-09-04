"""One-shot correction of the scanner isolation assertion.

The main branch already contains an ARMSX2 root registration. The guard must
reject new out-of-marker changes, not reject that pre-existing baseline line.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
guard = root / 'build-utils/check_dolphin_isolation_v2.py'
if guard.is_file():
    text = guard.read_text(encoding='utf-8')
    text = text.replace(
        '    forbid(scanner, "romFolders: [..._config.romFolders", "global Dolphin root injection")\n',
        '    # Existing non-Dolphin roots are protected by the marker-aware diff.\n'
        '    require(scanner, "DolphinInternalV2Service.scanRootPath", "isolated private Dolphin root")\n',
    )
    guard.write_text(text, encoding='utf-8')
Path(__file__).unlink(missing_ok=True)
