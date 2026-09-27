#!/usr/bin/env python3
"""Guard the exact Build 352 RPCS3 Core and IPA identity."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = (ROOT / ".github/workflows/ios-ci.yml").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def main() -> None:
    for token in (
        "NeoStation iOS Build 352 RPCS3 GOW3 memory candidate",
        "BUILD_NUMBER: ${{ inputs.build_number || '352' }}",
        "NeoStation-iOS-Build-352-RPCS3-GOW3-Memory-Candidate",
        "RPCS3_CORE_HOST_SHA: 7ecc36bdb9f1206aedff02cb15aa23341c242f91",
        "RPCS3_CORE_RUN_ID: '36343065903'",
        "test/rpcs3_build352_gow3_memory_test.py",
    ):
        require(token in WORKFLOW, f"missing Build 352 RPCS3 pin: {token}")

    require("af37d32a5fca433b40ca6d3a6b3a8232c865cc82" not in WORKFLOW,
            "Build 351 RPCS3 Core is still pinned")
    require("36336534425" not in WORKFLOW,
            "Build 351 RPCS3 Core run is still pinned")
    print("Build 352 RPCS3 Core pin: OK")


if __name__ == "__main__":
    main()
