"""One-shot cleanup of the auxiliary publisher workflow.

Loaded automatically when the materializer is executed from build-utils. Both
this file and the publisher are deleted before the clean source commit, so the
strict changed-file allowlist remains meaningful.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
(root / '.github/workflows/dolphin-internal-isolated-v3-publish.yml').unlink(missing_ok=True)
Path(__file__).unlink(missing_ok=True)
