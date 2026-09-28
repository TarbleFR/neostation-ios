#!/usr/bin/env python3
"""Regression contract for RPCS3 occupied-slot overwrite."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MENU = (ROOT / "packages/rpcs3_internal_bridge/ios/Classes/Rpcs3SessionMenu.mm").read_text()
PATCH = (ROOT / "build-utils/rpcs3/embedded-core.patch").read_text(errors="ignore")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def main() -> None:
    require("NEOSTATION_RPC3_OVERWRITE_V2" in MENU,
            "overwrite race fix marker is missing")
    require("@property(nonatomic, assign) BOOL suppressNextStateReload;" in MENU,
            "modal-dismiss state-refresh suppression is missing")

    appear = MENU.index("- (void)viewWillAppear:")
    reload = MENU.index("- (void)reloadStates")
    appear_body = MENU[appear:reload]
    require("if (self.suppressNextStateReload)" in appear_body,
            "viewWillAppear does not suppress the modal-dismiss refresh")
    require("[self reloadStates];" in appear_body,
            "normal state refresh was accidentally removed")

    marker = MENU.index("NEOSTATION_RPC3_OVERWRITE_V2")
    overwrite = MENU.index('actionWithTitle:[self text:@"overwrite"]', marker)
    operation = MENU.index("[menu operateState:slot load:NO];", overwrite)
    require(marker < overwrite < operation,
            "confirmed overwrite no longer reaches the slot save operation")
    require("0.5 * NSEC_PER_SEC" in MENU[overwrite:operation + 800],
            "one-shot suppression is not cleared after alert dismissal")

    require('fmt::format("%s_1_%u.SAVESTAT.zst", m_title_id, slot - 1)' in PATCH,
            "Core no longer maps numbered slots to deterministic filenames")
    require("neostation_rpcs3_ios_save_state_slot(uint32_t slot)" in PATCH,
            "Core numbered save entry point is missing")

    print("PASS: RPCS3 occupied-slot overwrite reaches the same deterministic Core slot")


if __name__ == "__main__":
    main()
