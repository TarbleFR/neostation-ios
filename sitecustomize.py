"""One-shot cleanup for the Dolphin source materialization workflow."""
from pathlib import Path

root = Path(__file__).resolve().parent
(root / '.github/workflows/dolphin-internal-isolated-v2-materialize.yml').unlink(missing_ok=True)
Path(__file__).unlink(missing_ok=True)
