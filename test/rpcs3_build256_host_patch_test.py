#!/usr/bin/env python3
"""Contract checks for Build 256's localized ten-slot and stretch UI."""

from pathlib import Path
import sys


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def main() -> None:
    root = Path(sys.argv[1]).resolve() if len(sys.argv) == 2 else Path(__file__).resolve().parents[1]
    classes = root / "packages/rpcs3_internal_bridge/ios/Classes"
    plugin = (classes / "Rpcs3InternalBridgePlugin.mm").read_text()
    abi = (classes / "Rpcs3CoreABI.h").read_text()
    localization = (classes / "RPCS3InGameLocalization.mm").read_text()

    require(plugin.count("NEOSTATION_RPCS3_BUILD256_HOST_V1") == 1,
            "Build 256 host marker is missing or duplicated")
    require('LOAD("neostation_rpcs3_ios_save_state_slot", save_state_slot)' in plugin,
            "numbered native save symbol is not loaded")
    require("(*save_state_slot)(uint32_t slot)" in abi,
            "host ABI lacks the numbered save function")
    require("for (NSUInteger slot = 1; slot <= 10; ++slot)" in plugin,
            "save/load menus are not bounded to ten slots")
    require("confirmOverwriteSlot:" in plugin and "UIAlertActionStyleDestructive" in plugin,
            "occupied slots do not ask for overwrite confirmation")
    require('"gpu.stretch_to_display"' in plugin and "showStretchMenu" in plugin,
            "per-game stretch mode is missing")
    require("localizedSavestateError:" in plugin and
            "[self localizedSavestateError:originalError]" in plugin,
            "native savestate failures can still leak untranslated text")
    require("stateFreshRestart" in plugin and "boot_game(titleId.UTF8String, NULL)" in plugin,
            "failed state loads do not recover to a normal game boot")
    for locale in ("de", "en", "es", "fr", "id", "it", "ja", "ko", "pt", "ru", "zh", "zh_Hant"):
        require(f'@"{locale}": @{{' in localization, f"missing locale {locale}")
    for key in ("slot", "emptySlot", "overwrite", "overwriteTitle", "overwriteMessage",
                "stretch", "stretchTitle", "stretchMessage", "normal", "stretched",
                "stateSafePoint", "stateVideoActive", "stateInvalid", "stateMissing",
                "stateWriteFailed", "stateBusy", "stateUnknown", "stateFreshRestart"):
        require(localization.count(f'@"{key}":') == 12,
                f"{key} is not translated in exactly 12 locales")
    print("RPCS3 Build 256 host/localization patch contract: OK")


if __name__ == "__main__":
    main()
