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
        self.assertNotIn('fallbackSuffix', manager)
        self.assertIn('forResource: "embedded"', manager)
        self.assertIn('withExtension: "mobileprovision"', manager)
        self.assertIn('PropertyListSerialization.propertyList', manager)
        self.assertIn('com.apple.developer.networking.networkextension', manager)
        self.assertNotIn('com.apple.developer.networking.vpn.api', manager)
        self.assertIn('signingMissing', manager)
        self.assertIn('ensureWaiters', manager)
        self.assertIn('disableWaiters', manager)
        self.assertIn('activeVPNConflict', manager)
        self.assertIn('removeDuplicateManagers', manager)
        self.assertIn('schemaVersionKey', manager)
        self.assertIn('manager.saveToPreferences', manager)
        self.assertIn('NEVPNError.configurationReadWriteFailed', manager)
        self.assertIn('manager.connection.stopVPNTunnel()', manager)
        self.assertIn('manager.isOnDemandEnabled = false', manager)
        self.assertIn('"authorized": configured', manager)
        self.assertIn('"configured": configured', manager)

    def test_tools_exposes_authorize_enable_disable_and_resume_refresh(self):
        tools = (
            ROOT /
            'lib/screens/settings_screen/new_settings_options/tools_settings_content.dart'
        ).read_text()
        bridge = (ROOT / 'packages/stikjit_bridge/lib/stikjit_bridge.dart').read_text()
        plugin = (
            ROOT / 'packages/stikjit_bridge/ios/Classes/StikjitBridgePlugin.swift'
        ).read_text()
        service = (ROOT / 'lib/services/local_jit_tunnel_service.dart').read_text()

        self.assertIn('with WidgetsBindingObserver', tools)
        self.assertIn('AppLifecycleState.resumed', tools)
        self.assertIn('LocalJitTunnelLocale.authorizeAction', tools)
        self.assertIn('LocalJitTunnelLocale.enableAction', tools)
        self.assertIn('LocalJitTunnelLocale.disableAction', tools)
        self.assertIn('LocalJitTunnelService.authorizeAndEnable()', tools)
        self.assertIn('LocalJitTunnelService.disable()', tools)
        self.assertIn("invokeMethod<Object?>('disableLocalTunnel')", bridge)
        self.assertIn('call.method == "disableLocalTunnel"', plugin)
        self.assertIn('if (!current.authorized || !current.enabled)', service)
        self.assertIn('no system authorization prompt was requested', service)

    def test_vpn_locale_declares_all_twelve_supported_languages(self):
        locale = (ROOT / 'lib/l10n/local_jit_tunnel_locale.dart').read_text()
        for key in (
            'en', 'de', 'es', 'fr', 'id', 'it', 'ja', 'ko', 'pt', 'ru',
            'zh', 'zh_Hant',
        ):
            self.assertIn(f"'{key}': {{", locale)
        self.assertIn('static const allKeys', locale)
        self.assertIn('missingKeysForLocale', locale)
        self.assertNotIn('LocalDevVPN', locale)

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
        self.assertIn("'com.apple.NetworkExtensions.iOS'", configurator)
        self.assertIn("'CodeSignOnCopy'", configurator)
        self.assertNotIn("'com.apple.developer.networking.vpn.api'", configurator)
        self.assertIn("framework_path = 'System/Library/Frameworks/NetworkExtension.framework'", configurator)
        self.assertGreaterEqual(
            workflow.count('python3 build-utils/configure_local_jit_tunnel.py'),
            2,
        )
        self.assertIn("app / 'PlugIns/NeoStationLocalTunnel.appex'", signer)
        self.assertIn('LOCAL_TUNNEL_EXTENSION_ENTITLEMENTS', signer)
        self.assertIn(
            'NeoStationLocalTunnel-signing.entitlements',
            (
                ROOT /
                'packages/dolphin_internal_bridge/ci/build_support.py'
            ).read_text(),
        )
        packager = (
            ROOT / 'packages/dolphin_internal_bridge/ci/build_support.py'
        ).read_text()
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

    def test_startup_and_resume_refresh_are_non_blocking(self):
        main = (ROOT / 'lib/main.dart').read_text()
        lifecycle = (ROOT / 'lib/widgets/app_lifecycle_handler.dart').read_text()
        self.assertIn("refreshInBackground(reason: 'cold start')", main)
        self.assertIn("refreshInBackground(reason: 'app resume')", lifecycle)
        self.assertIn('unawaited(', main)
        self.assertIn('unawaited(', lifecycle)


if __name__ == '__main__':
    unittest.main()
