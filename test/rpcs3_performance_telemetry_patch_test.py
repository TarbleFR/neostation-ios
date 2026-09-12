#!/usr/bin/env python3
"""Contract checks for RPCS3 device performance telemetry."""

from pathlib import Path
import sys


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def main() -> None:
    root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(".")
    plugin = (root / "packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm").read_text()
    diagnostics = (root / "packages/rpcs3_internal_bridge/ios/Classes/Rpcs3Diagnostics.h").read_text()

    require(plugin.count("NEOSTATION_RPCS3_PERFORMANCE_TELEMETRY_V1") == 1,
            "performance telemetry marker is missing or duplicated")
    require("os_proc_available_memory()" in plugin,
            "available-memory pressure signal is missing")
    require("NSProcessInfo.processInfo.thermalState" in plugin,
            "thermal-state signal is missing")
    require("NSEC_PER_SEC, (uint64_t)(0.1 * NSEC_PER_SEC)" in plugin,
            "telemetry must remain a low-rate one-second sampler")
    require("@\"performance_sample\"" in plugin and "@\"performance_summary\"" in plugin,
            "sample and session-summary diagnostics are required")
    require("if (bootStatus == 0) [self startDiagnosticPerformanceSampling];" in plugin,
            "sampling must start only after a successful boot")
    require(plugin.count("[self stopDiagnosticPerformanceSampling];") == 2,
            "shutdown and ordinary stop must both flush a summary")
    require("![stage isEqualToString:@\"performance_sample\"]" in diagnostics,
            "per-second samples must not synchronously fsync the emulation session")
    print("RPCS3 performance telemetry patch contract: OK")


if __name__ == "__main__":
    main()
