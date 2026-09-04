"""Delete the temporary compile fixer after its successful execution."""
import atexit
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
if Path(sys.argv[0]).name == 'dolphin_v2_compile_fixes.py':
    def _cleanup() -> None:
        (root / 'build-utils/dolphin_v2_compile_fixes.py').unlink(missing_ok=True)
        Path(__file__).unlink(missing_ok=True)
    atexit.register(_cleanup)
