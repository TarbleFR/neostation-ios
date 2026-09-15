#!/usr/bin/env python3
"""Regression checks for NeoStation's session-scoped local JIT route."""
from __future__ import annotations

import plistlib
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class LocalJitTunnelContractTests(unittest.TestCase):
    def test_packet_tunnel_is_device_local_and_has_force_kill_watchdog(self):
        source = (
            ROOT / 'native/local_jit_tunnel/PacketTunnelProvider.swift'
        ).read_text()
        self.assertIn('final class PacketTunnelProvider: NEPacketTunnelProvider', source)
        self.assertIn('defaultInterfaceAddress = "10.7.1.1"', source)
        self.assertIn('defaultPeerAddress = "10.7.0.1"', source)
        self.assertIn('NEIPv4Route(', source)
        self.assertIn('self.readAndReflectPackets()', source)
        self.assertIn('heartbeatMessage = "heartbeat"', source)
        self.assertIn('heartbeatTimeout: TimeInterval = 5.0', source)
        self.assertIn('ProcessInfo.processInfo.systemUptime', source)
        self.assertIn('cancelTunnelWithError(nil)', source)
        self.assertIn('startWatchdog()', source)
        self.assertIn('stopWatchdog()', source)
        self.assertNotIn('URLSession', source)
        self.assertNotIn('http://', source)
        self.assertNotIn('https://', source)

    def test_extension_declares_packet_tunnel_contract(self):
        info = plistlib.loads(
            (ROOT / 'native/local_jit_tunnel/Info.plist').read_bytes()
        )
        extension = info['NSExtension']
        self.assertEqual(
            extension['NSExtensionPointIdentifier'],
            'com.apple.networkextension.packet-tunnel',
        )
        self.assertIn('PacketTunnelProvider', extension['NSExtensionPrincipalClass'])
        entitlements = plistlib.loads(
            (
                ROOT /
                'native/local_jit_tunnel/NeoStationLocalTunnel.entitlements'
            ).read_bytes()
        )
        self.assertEqual(
            entitlements['com.apple.developer.networking.networkextension'],
            ['packet-tunnel-provider'],
        )

    def test_route_probe_precedes_external_vpn_conflict_handling(self):
        manager = (
            ROOT /
            'packages/stikjit_bridge/ios/Classes/NeoStationLocalTunnelManager.swift'
        ).read_text()
        bridge = (ROOT / 'packages/stikjit_bridge/lib/stikjit_bridge.dart').read_text()

        self.assertIn('import Network', manager)
        self.assertIn('static let peerAddress = "10.7.0.1"', manager)
        self.assertIn('static let jitPort: UInt16 = 49152', manager)
        self.assertIn('NWConnection(', manager)
        self.assertIn('routeProbeTimeout: TimeInterval = 1.25', manager)
        self.assertNotIn('connectionTimeout: TimeInterval = 45', manager)

        external_start = manager.index('private func probeExternalThenEnsureOwned(')
        external_end = manager.index('private func ensureOwnedTunnel(', external_start)
        external_body = manager[external_start:external_end]
        self.assertIn('probeJitRoute', external_body)
        self.assertIn('externalRouteResponse()', external_body)
        self.assertIn('ensureOwnedTunnel(generation: generation)', external_body)

        owned_start = manager.index('private func ensureOwnedTunnel(')
        owned_end = manager.index('private func performDisable()', owned_start)
        owned_body = manager[owned_start:owned_end]
        self.assertIn('activeVPNConflict', owned_body)
        self.assertIn('!Self.isOwned(', owned_body)

        self.assertIn('Future<LocalJitTunnelState> ensureJitRoute()', bridge)
        self.assertIn('=> ensureLocalTunnel();', bridge)
        self.assertNotIn("error.code != 'local_tunnel_vpn_conflict'", bridge)
        self.assertNotIn("status: 'externalRoute'", bridge)

    def test_neostation_manager_never_uses_on_demand(self):
        manager = (
            ROOT /
            'packages/stikjit_bridge/ios/Classes/NeoStationLocalTunnelManager.swift'
        ).read_text()
        self.assertIn('NETunnelProviderManager.loadAllFromPreferences', manager)
        self.assertNotIn('NEOnDemandRuleConnect', manager)
        self.assertNotIn('isOnDemandEnabled = true', manager)
        self.assertIn('manager.isOnDemandEnabled = false', manager)
        self.assertIn('manager.onDemandRules = []', manager)
        self.assertIn('manager.isEnabled = false', manager)
        self.assertIn('Bundle.main.builtInPlugInsURL', manager)
        self.assertIn('NeoStationLocalTunnel.appex', manager)
        self.assertIn('forResource: "embedded"', manager)
        self.assertIn('withExtension: "mobileprovision"', manager)
        self.assertIn('PropertyListSerialization.propertyList', manager)
        self.assertIn('com.apple.developer.networking.networkextension', manager)
        self.assertNotIn('com.apple.developer.networking.vpn.api', manager)
        self.assertIn('signingMissing', manager)
        self.assertIn('removeDuplicateManagers', manager)
        self.assertIn('schemaVersionKey', manager)
        self.assertIn('manager.saveToPreferences', manager)
        self.assertIn('NEVPNError.configurationReadWriteFailed', manager)

    def test_stop_has_priority_and_stale_callbacks_cannot_restart(self):
        manager = (
            ROOT /
            'packages/stikjit_bridge/ios/Classes/NeoStationLocalTunnelManager.swift'
        ).read_text()
        self.assertIn('operationGeneration', manager)
        self.assertIn('activeEnsureGeneration', manager)
        self.assertIn('stopRequested', manager)
        self.assertIn('ensureIsCurrent', manager)
        self.assertIn('case cancelled', manager)

        disable_start = manager.index('func disable(completion:')
        disable_end = manager.index('private func beginEnsureIfPossible()', disable_start)
        disable_body = manager[disable_start:disable_end]
        self.assertIn('self.operationGeneration &+= 1', disable_body)
        self.assertIn('self.activeManager?.connection.stopVPNTunnel()', disable_body)
        self.assertIn('self.stopHeartbeat()', disable_body)

        perform_start = manager.index('private func performDisable()')
        perform_end = manager.index('private func removeDuplicateManagers(', perform_start)
        perform_body = manager[perform_start:perform_end]
        self.assertNotIn('self.configure(', perform_body)
        self.assertIn('manager.isEnabled = false', perform_body)
        self.assertIn('manager.isOnDemandEnabled = false', perform_body)
        self.assertIn('manager.onDemandRules = []', perform_body)

    def test_app_heartbeats_extension_and_extension_self_terminates(self):
        manager = (
            ROOT /
            'packages/stikjit_bridge/ios/Classes/NeoStationLocalTunnelManager.swift'
        ).read_text()
        provider = (
            ROOT / 'native/local_jit_tunnel/PacketTunnelProvider.swift'
        ).read_text()
        self.assertIn('heartbeatInterval: TimeInterval = 1.5', manager)
        self.assertIn('NETunnelProviderSession', manager)
        self.assertIn('sendProviderMessage', manager)
        self.assertIn('Data(Constants.heartbeatMessage.utf8)', manager)
        self.assertIn('heartbeatTimeout: TimeInterval = 5.0', provider)
        self.assertIn('lastHeartbeatUptime', provider)
        self.assertIn('cancelTunnelWithError(nil)', provider)

    def test_lifecycle_starts_on_resume_and_stops_on_every_background_state(self):
        main = (ROOT / 'lib/main.dart').read_text()
        lifecycle = (ROOT / 'lib/widgets/app_lifecycle_handler.dart').read_text()
        service = (ROOT / 'lib/services/local_jit_tunnel_service.dart').read_text()

        self.assertIn("refreshInBackground(reason: 'cold start')", main)
        self.assertIn("refreshInBackground(reason: 'app resume')", lifecycle)
        self.assertIn('AppLifecycleState.inactive', lifecycle)
        self.assertIn('AppLifecycleState.paused', lifecycle)
        self.assertIn('AppLifecycleState.hidden', lifecycle)
        self.assertIn('AppLifecycleState.detached', lifecycle)
        self.assertIn("reason: 'normal app exit'", lifecycle)
        self.assertIn('LocalJitTunnelService.stopForLifecycle(', lifecycle)
        self.assertIn('++_lifecycleGeneration', service)
        self.assertIn('await disable();', service)
        self.assertIn('await ensureRunningForJit();', service)
        self.assertNotIn('PairingFileService.hasStoredPairingFile()', service)

    def test_game_launches_share_one_route_abstraction(self):
        bridge = (ROOT / 'packages/stikjit_bridge/lib/stikjit_bridge.dart').read_text()
        service = (ROOT / 'lib/services/local_jit_tunnel_service.dart').read_text()
        rpcs3 = (ROOT / 'lib/services/rpcs3_internal_service.dart').read_text()
        dolphin = (ROOT / 'lib/services/dolphin_internal_v2_service.dart').read_text()

        self.assertEqual(bridge.count('await ensureJitRoute();'), 2)
        self.assertIn('StikjitBridge.ensureJitRoute()', service)
        self.assertIn('LocalJitTunnelService.ensureRunningForJit()', rpcs3)
        self.assertIn('LocalJitTunnelService.ensureRunningForJit()', dolphin)
        self.assertIn('if (Platform.isIOS)', rpcs3)
        self.assertIn('if (Platform.isIOS)', dolphin)
        self.assertIn('stikjit.local_tunnel_failed', dolphin)

    def test_vpn_locale_declares_all_twelve_supported_languages(self):
        locale = (ROOT / 'lib/l10n/local_jit_tunnel_locale.dart').read_text()
        for key in (
            'en', 'de', 'es', 'fr', 'id', 'it', 'ja', 'ko', 'pt', 'ru',
            'zh', 'zh_Hant',
        ):
            self.assertIn(f"'{key}': {{", locale)
        self.assertIn('static const allKeys', locale)
        self.assertIn('missingKeysForLocale', locale)

    def test_generated_host_embeds_and_signs_the_extension(self):
        configurator = (
            ROOT / 'build-utils/configure_local_jit_tunnel.py'
        ).read_text()
        workflow = (
            ROOT / '.github/workflows/build-ipa-once.yml'
        ).read_text()
        signer = (
            ROOT / 'build-utils/embed_rpcs3_host_entitlements.py'
        ).read_text()
        self.assertIn(
            "project.new_target(:app_extension, 'NeoStationLocalTunnel'",
            configurator,
        )
        self.assertIn("'packet-tunnel-provider'", configurator)
        self.assertIn("'com.apple.NetworkExtensions.iOS'", configurator)
        self.assertIn("'CodeSignOnCopy'", configurator)
        self.assertNotIn("'com.apple.developer.networking.vpn.api'", configurator)
        self.assertIn(
            "framework_path = 'System/Library/Frameworks/NetworkExtension.framework'",
            configurator,
        )
        self.assertGreaterEqual(
            workflow.count('python3 build-utils/configure_local_jit_tunnel.py'),
            2,
        )
        self.assertIn("app / 'PlugIns/NeoStationLocalTunnel.appex'", signer)
        self.assertIn('LOCAL_TUNNEL_EXTENSION_ENTITLEMENTS', signer)
        packager = (
            ROOT / 'packages/dolphin_internal_bridge/ci/build_support.py'
        ).read_text()
        self.assertIn('NeoStationLocalTunnel-signing.entitlements', packager)
        self.assertIn("LOGS / 'NeoStation-signing.entitlements'", packager)
        self.assertIn(
            "LOGS / 'NeoStationLocalTunnel-signing.entitlements'",
            packager,
        )
        validator = (
            ROOT / 'build-utils/validate_single_ipa_distribution.py'
        ).read_text()
        self.assertIn("'installationUnits': 1", validator)
        self.assertIn("'separateTunnelIPARequired': False", validator)
        self.assertIn("'userSignsOneIPA': True", validator)


if __name__ == '__main__':
    unittest.main()
