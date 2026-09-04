"""One-shot cleanup loaded from the build-utils script directory."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
(root / '.github/workflows/dolphin-internal-isolated-v2-materialize.yml').unlink(missing_ok=True)
(root / 'sitecustomize.py').unlink(missing_ok=True)
(root / 'usercustomize.py').unlink(missing_ok=True)
Path(__file__).unlink(missing_ok=True)
