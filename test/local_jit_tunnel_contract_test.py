#!/usr/bin/env python3
"""Regression checks for NeoStation's integrated device-local JIT tunnel."""
from __future__ import annotations

import plistlib
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class LocalJitTunnelContractTests(unittest.TestCase):
    def test_packet_tunnel_is_device_local_and_system_managed(self):
        source = (
            ROOT / 'native/local_jit_tunnel/PacketTunnelProvider.swift'
        ).read_text()
        self.assertIn('final class PacketTunnelProvider: NEPacketTunnelProvider', source)
        self.assertIn('defaultInterfaceAddress = "10.7.1.1"', source)
        self.assertIn('defaultPeerAddress = "10.7.0.1"', source)
        self.assertIn('NEIPv4Route(', source)
        self.assertIn('self.readAndReflectPackets()', source)
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

    def test_manager_persists_on_demand_and_handles_signer_rewrites(self):
        manager = (
            ROOT /
            'packages/stikjit_bridge/ios/Classes/NeoStationLocalTunnelManager.swift'
        ).read_text()
        self.assertIn('NETunnelProviderManager.loadAllFromPreferences', manager)
        self.assertIn('NEOnDemandRuleConnect()', manager)
        self.assertIn('manager.isOnDemandEnabled = true', manager)
        self.assertIn('Bundle.main.builtInPlugInsURL', manager)
        self.assertIn('NeoStationLocalTunnel.appex', manager)
        self.assertIn('ensureWaiters', manager)
        self.assertIn('activeVPNConflict', manager)
        self.assertIn('removeDuplicateManagers', manager)
        self.assertIn('schemaVersionKey', manager)

    def test_every_jit_path_ensures_tunnel_before_remote_pairing(self):
        bridge = (
            ROOT / 'packages/stikjit_bridge/lib/stikjit_bridge.dart'
        ).read_text()
        self.assertEqual(bridge.count('await ensureLocalTunnel();'), 2)

        rpcs3 = (ROOT / 'lib/services/rpcs3_internal_service.dart').read_text()
        dolphin = (
            ROOT / 'lib/services/dolphin_internal_v2_service.dart'
        ).read_text()
        self.assertIn('LocalJitTunnelService.ensureRunningForJit()', rpcs3)
        self.assertIn('LocalJitTunnelService.ensureRunningForJit()', dolphin)
        self.assertIn('if (Platform.isIOS)', rpcs3)
        self.assertIn('if (Platform.isIOS)', dolphin)
        self.assertIn('stikjit.local_tunnel_failed', dolphin)

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
        self.assertIn("project.new_target(:app_extension, 'NeoStationLocalTunnel'", configurator)
        self.assertIn("'packet-tunnel-provider'", configurator)
        self.assertIn("framework_path = 'System/Library/Frameworks/NetworkExtension.framework'", configurator)
        self.assertGreaterEqual(
            workflow.count('python3 build-utils/configure_local_jit_tunnel.py'),
            2,
        )
        self.assertIn("app / 'PlugIns/NeoStationLocalTunnel.appex'", signer)
        self.assertIn('LOCAL_TUNNEL_EXTENSION_ENTITLEMENTS', signer)

    def test_startup_and_resume_refresh_are_non_blocking(self):
        main = (ROOT / 'lib/main.dart').read_text()
        lifecycle = (ROOT / 'lib/widgets/app_lifecycle_handler.dart').read_text()
        self.assertIn("refreshInBackground(reason: 'cold start')", main)
        self.assertIn("refreshInBackground(reason: 'app resume')", lifecycle)
        self.assertIn('unawaited(', main)
        self.assertIn('unawaited(', lifecycle)


if __name__ == '__main__':
    unittest.main()
