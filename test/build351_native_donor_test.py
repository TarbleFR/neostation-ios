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
    for stale_run in ("35850858213", "35805854967", "35969089056"):
        require(stale_run not in WORKFLOW,
                f"pruned native artifact run remains referenced: {stale_run}")

    for token in (
        "7129d9c654fb6d28f2fa92ae1a4c14d1f25a1fc3e87788237676b48a0fb3aa2d",
        "4866265eca27327c3fc9be14190fec082b58a5e1946f541ced34e46c13ceabd9",
        "cadb6cd56c4b5d01b623bf9696800d48ba504eef8129a8de468c11381de8d162",
        "5a64e2fd48c47831fd07306c90e28036535a125bd887149d92ba4567ac9af8a7",
        "DONOR_RUN_ID=36323843067",
        "DONOR_ARTIFACT_ID=10932894067",
    ):
        require(token in PREPARE, f"missing Build 350 donor contract: {token}")

    require("STIKJIT_SHA" not in PREPARE and "official_stik" not in PREPARE,
            "the native donor must never install a legacy JIT runtime or module")

    donor = WORKFLOW.index("Download validated Build 350 native donor")
    rpcs3 = WORKFLOW.index("Download pinned passive RPCS3 Core", donor)
    dolphin = WORKFLOW.index("Verify retained stable Dolphin Core", rpcs3)
    armsx2 = WORKFLOW.index("Verify retained stable ARMSX2 Core identity", dolphin)
    dusklight = WORKFLOW.index("Verify retained stable Dusklight Core identity", armsx2)
    require(donor < rpcs3 < dolphin < armsx2 < dusklight,
            "retained stable Cores must be verified after the RPCS3 replacement")
    print("Build 351 retained native donor contract: OK")


if __name__ == "__main__":
    main()
