#!/usr/bin/env python3
"""Allow a clean RPCS3 iOS Core shutdown to be followed by one new initialize.

Build 303 deliberately removes NeoStation's bespoke reset_failed_startup ABI.
The upstream lifecycle already cleans FAILED through rpcs3_ios_shutdown(), but
begin_initialize() only accepts UNINITIALIZED. Accept STOPPED as the second
clean entry state so a user-initiated retry can reuse the passive-loaded Core.
"""
from pathlib import Path
import sys

MARKER = "NEOSTATION_BUILD303_RESTARTABLE_LIFECYCLE_V1"
OLD = """		if (m_state != RPCS3_IOS_STATE_UNINITIALIZED)
		{
			return RPCS3_IOS_INVALID_STATE;
		}
"""
NEW = f"""		// {MARKER}
		// STOPPED is produced only by a successful shutdown. It is therefore a
		// clean lifecycle boundary and may start a new explicit initialization.
		if (m_state != RPCS3_IOS_STATE_UNINITIALIZED &&
			m_state != RPCS3_IOS_STATE_STOPPED)
		{{
			return RPCS3_IOS_INVALID_STATE;
		}}
"""

def patch(root: Path) -> None:
    path = root / "rpcs3/ios/RPCS3IOSContract.h"
    text = path.read_text()
    if MARKER in text:
        return
    if OLD not in text:
        raise RuntimeError("RPCS3 lifecycle begin_initialize contract drifted")
    path.write_text(text.replace(OLD, NEW, 1))

if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch_rpcs3_build303_restartable_lifecycle.py <rpcs3-source>")
    patch(Path(sys.argv[1]))
