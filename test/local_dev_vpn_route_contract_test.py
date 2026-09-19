#!/usr/bin/env python3
from pathlib import Path
import plistlib
import unittest


ROOT = Path(__file__).resolve().parents[1]


def source(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


class LocalDevVpnRouteContractTest(unittest.TestCase):
    def test_native_probe_is_bounded_read_only_and_diagnostic(self) -> None:
        probe = source(
            "packages/stikjit_bridge/ios/Classes/LocalDevVpnRouteProbe.swift"
        )
        self.assertIn("import Network", probe)
        self.assertNotIn("NetworkExtension", probe)
        self.assertNotIn("NETunnelProviderManager", probe)
        self.assertNotIn("loadAllFromPreferences", probe)
        self.assertIn('static let host = "10.7.0.1"', probe)
        self.assertIn("static let port: UInt16 = 49152", probe)
        self.assertIn("static let timeout: TimeInterval = 1.25", probe)
        self.assertIn("guard !finished else { return }", probe)
        for diagnostic in (
            '"elapsedMs"',
            '"state"',
            '"networkState"',
            '"errorCode"',
            '"errorDescription"',
        ):
            self.assertIn(diagnostic, probe)

    def test_flutter_channel_has_no_vpn_profile_controls(self) -> None:
        native = source(
            "packages/stikjit_bridge/ios/Classes/StikjitBridgePlugin.swift"
        )
        dart = source("packages/stikjit_bridge/lib/stikjit_bridge.dart")

        self.assertIn('call.method == "probeLocalDevVpnRoute"', native)
        self.assertIn(
            "static Future<LocalDevVpnRouteState> probeLocalDevVpnRoute()",
            dart,
        )
        self.assertEqual(dart.count("await probeLocalDevVpnRoute();"), 2)
        for obsolete in (
            "NeoStationLocalTunnelManager",
            "ensureLocalTunnel",
            "activateOwnedTunnel",
            "localTunnelStatus",
            "disableLocalTunnel",
            "LocalJitTunnelState",
        ):
            self.assertNotIn(obsolete, native)
            self.assertNotIn(obsolete, dart)

    def test_route_service_coalesces_and_bounds_probes(self) -> None:
        service = source("lib/services/local_dev_vpn_route_service.dart")
        self.assertIn(
            "static Future<LocalDevVpnRouteState>? _probeInFlight;", service
        )
        self.assertIn("final existing = _probeInFlight;", service)
        self.assertIn("if (existing != null) return existing;", service)
        self.assertIn(".timeout(", service)
        self.assertIn("LocalDevVpnRouteException", service)

        for obsolete in (
            "local_jit_tunnel_service.dart",
            "local_jit_debugger_lease.dart",
            "local_jit_session_coordinator.dart",
            "local_jit_lifecycle_policy.dart",
        ):
            self.assertFalse((ROOT / "lib/services" / obsolete).exists())

    def test_every_stikjit_entry_point_uses_the_fixed_endpoint(self) -> None:
        entry_points = (
            "packages/stikjit_bridge/ios/Classes/StikjitBridgePlugin.swift",
            "packages/stikjit_bridge/ios/Classes/StikjitBridgePluginV2.swift",
            "packages/stikjit_bridge/ios/Classes/NeoStationStikjitBridgePlugin.swift",
            "packages/rpcs3_jit_helper/ios/Classes/Rpcs3JITRequestHandlerBase.swift",
            "packages/dolphin_jit_helper/ios/Classes/DolphinJITRequestHandlerBase.swift",
        )
        for relative in entry_points:
            with self.subTest(relative=relative):
                contents = source(relative)
                self.assertNotIn("Configuration.default", contents)
                self.assertIn('deviceAddress: "10.7.0.1"', contents)
                self.assertIn("rsdPort: 49152", contents)

        diagnostic_sources = entry_points + (
            "packages/stikjit_bridge/ios/Classes/Armsx2NeoStationProcessActivator.swift",
        )
        for relative in diagnostic_sources:
            with self.subTest(relative=relative):
                self.assertNotIn("local tunnel", source(relative).lower())

    def test_bonjour_resolver_is_absent_but_privacy_copy_remains(self) -> None:
        self.assertFalse(
            (ROOT / "build-utils/patch_stikjit_remote_pairing.py").exists()
        )
        self.assertFalse(
            (ROOT / "test/stikjit_remote_pairing_compat_test.py").exists()
        )

        for relative in (
            "native/rpcs3_internal_helper/Info.plist",
            "native/dolphin_internal_helper/Info.plist",
        ):
            with self.subTest(relative=relative):
                contents = (ROOT / relative).read_bytes()
                info = plistlib.loads(contents)
                self.assertNotIn("NSBonjourServices", info)
                self.assertTrue(info.get("NSLocalNetworkUsageDescription"))
                self.assertNotIn(b"_remotepairing._tcp", contents)

        scaffold = source(
            "packages/dolphin_internal_bridge/ci/build_support.py"
        )
        self.assertNotIn("NSBonjourServices", scaffold)
        self.assertNotIn("_remotepairing._tcp", scaffold)
        self.assertIn("NSLocalNetworkUsageDescription", scaffold)


if __name__ == "__main__":
    unittest.main()
