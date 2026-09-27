#!/usr/bin/env python3
"""Guard the retained native donor used by the Build 351 IPA workflow."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = (ROOT / ".github/workflows/ios-ci.yml").read_text()
PREPARE = (ROOT / "build-utils/prepare_fast_native_runtime.py").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def main() -> None:
    require("artifact-ids: 10932894067" in WORKFLOW,
            "Build 351 must pin the retained Build 350 donor artifact")
    require("run-id: 36323843067" in WORKFLOW,
            "Build 351 must bind the donor artifact to its successful run")
    require("35321768668" not in WORKFLOW and "35321768668" not in PREPARE,
            "the pruned Build 270 donor must not remain referenced")

    for token in (
        "7129d9c654fb6d28f2fa92ae1a4c14d1f25a1fc3e87788237676b48a0fb3aa2d",
        "4866265eca27327c3fc9be14190fec082b58a5e1946f541ced34e46c13ceabd9",
        "4de72ef84a1aef6d6d3b547222c730227b48e91d8d5eb7e59c1f9235961e4efe",
        "DONOR_RUN_ID=36323843067",
        "DONOR_ARTIFACT_ID=10932894067",
        "StikJIT donor hash mismatch",
    ):
        require(token in PREPARE, f"missing Build 350 donor contract: {token}")

    donor = WORKFLOW.index("Download validated Build 350 native donor")
    rpcs3 = WORKFLOW.index("Download pinned passive RPCS3 Core", donor)
    dolphin = WORKFLOW.index("Download rebuilt embedded Dolphin Core", rpcs3)
    require(donor < rpcs3 < dolphin,
            "pinned RPCS3 and Dolphin Cores must replace donor bootstrap binaries")
    print("Build 351 retained native donor contract: OK")


if __name__ == "__main__":
    main()
