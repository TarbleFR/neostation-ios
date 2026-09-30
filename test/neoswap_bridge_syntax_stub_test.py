#!/usr/bin/env python3
"""Guard the Objective-C++ bridge syntax preflight NeoSwap include stub."""

from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = (
    ".github/workflows/ios-ci.yml",
    ".github/workflows/neoswap-ipa.yml",
)
BRIDGE_ROOT = ROOT / "packages/rpcs3_internal_bridge/ios/Classes"
NEOSWAP_HEADERS = ROOT / "packages/neo_swap/ios/Classes"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def bridge_neoswap_imports() -> set[str]:
    imports: set[str] = set()
    pattern = re.compile(r'#\s*(?:import|include)\s*<neo_swap/([^>]+)>')
    for path in BRIDGE_ROOT.rglob("*"):
        if path.suffix not in {".h", ".m", ".mm"}:
            continue
        for match in pattern.finditer(path.read_text()):
            imports.add(match.group(1))
    return imports


def main() -> None:
    missing = sorted(
        header for header in bridge_neoswap_imports()
        if not (NEOSWAP_HEADERS / header).is_file()
    )
    require(not missing, "Bridge imports missing NeoSwap headers: " + ", ".join(missing))

    for workflow_path in WORKFLOWS:
        workflow = (ROOT / workflow_path).read_text()
        require(
            'mkdir -p "$STUB/neo_swap"' in workflow,
            f"{workflow_path} does not create the NeoSwap syntax stub include directory",
        )
        require(
            'cp packages/neo_swap/ios/Classes/*.h "$STUB/neo_swap/"' in workflow,
            f"{workflow_path} does not copy the full public NeoSwap header surface",
        )
        require(
            "packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm" in workflow,
            f"{workflow_path} no longer syntax-checks the RPCS3 internal bridge",
        )

    print("PASS NeoSwap bridge syntax stub includes all public headers")


if __name__ == "__main__":
    main()
