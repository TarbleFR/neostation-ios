#!/usr/bin/env python3
"""Guard the exact validated Build 353 XITRIX v0.10 RPCS3 Core pin."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = (ROOT / ".github/workflows/ios-ci.yml").read_text()

def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)

def main() -> None:
    for token in (
        "RPCS3_CORE_HOST_SHA: 7fbdc9fd26c094499179bf6f42727b8b2e59c281",
        "RPCS3_CORE_RUN_ID: '36418910869'",
        "test/rpcs3_build352_gow3_memory_test.py",
    ):
        require(token in WORKFLOW, f"missing validated Build 353 RPCS3 pin: {token}")

    for stale in (
        "RPCS3_CORE_HOST_SHA: 7ecc36bdb9f1206aedff02cb15aa23341c242f91",
        "RPCS3_CORE_RUN_ID: '36343065903'",
        "NeoStation iOS Build 352 RPCS3 GOW3 memory candidate",
    ):
        require(stale not in WORKFLOW, f"stale Build 352 RPCS3 pin remains: {stale}")

    print("Validated Build 353 RPCS3 Core pin: OK")

if __name__ == "__main__":
    main()
