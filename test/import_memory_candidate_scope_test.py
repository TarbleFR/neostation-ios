"""Hash-lock the explicit requested candidate, including local uncommitted deltas."""
from pathlib import Path
import hashlib
import json
import os
import re
import stat
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BASE = '3ccde925351b3e59985ba466e013e87a857d6ad0'
MANIFEST_PATH = 'native/import-memory-candidate.json'
manifest = json.loads((ROOT / MANIFEST_PATH).read_text())
assert manifest['baseline'] == BASE
assert manifest['target_build'] == 398
assert manifest['real_device_8gib_validated'] is False
assert manifest['real_device_donation_validated'] is False
assert manifest['real_device_dolphin_motion_validated'] is False
assert manifest['required_donation_evidence'] == ['macOS kernel', 'macOS NSXPC', 'iOS18Simulator']
assert manifest['real_device_relay_validated'] is False
assert manifest['real_device_relay_gameplay_validated'] is False
assert manifest['abi']['neoswap_relay'] == 1
assert manifest['required_relay_evidence'] == [
    'macOS NSXPC creator exit, written pages and coherent aliases',
    'iOS18Simulator extension exit, aliases, release and relaunch',
    'iPhone arm64 compile and link only',
    'macOS 8GiB retained capacity with separately measured 1MiB sparse sample',
]
assert manifest['required_relay_checks'] == [
    '.github/workflows/neoswap-relay-check.yml',
    'test/rpcs3_neoswap_relay_test.py',
]
assert manifest['relay_capacity_is_resident_ram'] is False
assert manifest['relay_target_capacity_bytes'] == 8 * 1024 ** 3
assert manifest['relay_target_object_count'] == 16
assert manifest['abi']['neoswap_managed'] == 1
assert manifest['abi']['neoswap_source_archive'] == 1
managed = manifest['managed_swap']
assert managed['stage'] == 'owned CPU framework with compiled GLSL source consumer'
assert managed['integrated_rpcs3_consumers'] == ['compiled GLSL source snapshots']
assert managed['physical_iPhone_validated'] is False
assert managed['gameplay_validated'] is False
assert managed['automatic_guest_paging_activated'] is False
assert managed['required_evidence'] == [
    'exact-source sanitized mutable RAM-storage-RAM cycle',
    'C ABI content, errors, generations and leases after context destruction',
    'executed macOS Swift ABI client',
    'materialized iPhone arm64 library linkage and iOS18 Swift typecheck',
]

# Additions require a review of the requested production scope. Never derive
# this whitelist from git status or from the hash manifest itself.
PRODUCTION_FILES = {
    'packages/neo_swap/ios/Classes/NeoSwapMemorySamples.h',
    'build-utils/neoplay_deployment.rb',
    'native/neoswap-storage/SourceABI.h',
    'native/neoswap-storage/SourceClient.h',
    'native/neoswap-storage/SourceClient.cpp',
    'native/neoswap-storage/SourceArchive.h',
    'native/neoswap-storage/SourceArchive.cpp',
    'packages/neo_swap/ios/Classes/SourceABI.h',
    # Build398: bounded owned CPU swap module; Core and shader ABI retained.
    'native/neoswap-storage/ManagedSwap.h',
    'native/neoswap-storage/ManagedSwap.cpp',
    'native/neoswap-storage/ManagedSwapABI.h',
    'native/neoswap-storage/ManagedSwapABI.cpp',
    'packages/neo_swap/ios/Classes/ManagedSwapABI.h',
    # Build398: the embedded RPCS3 menu is owned by NeoStation.
    'packages/rpcs3_internal_bridge/ios/Classes/RPCS3EmbeddedMenuInput.h',
    'packages/rpcs3_internal_bridge/ios/Classes/RPCS3GameInputController.h',
    'packages/rpcs3_internal_bridge/ios/Classes/RPCS3GameInputController.mm',
    # Reviewed shader-storage host additions.
    'build-utils/configure_neoswap_storage.py',
    'packages/neo_swap/lib/neo_swap.dart',
    'packages/neo_swap/ios/Classes/NeoSwapStorageService.h',
    'packages/neo_swap/ios/Classes/NeoSwapStorageService.mm',
    'packages/neo_swap/ios/Classes/StorageABI.h',
    'native/neoswap-storage/ShaderCache.h',
    'native/neoswap-storage/ShaderCache.cpp',
    'native/neoswap-storage/ShaderPolicy.h',
    'native/neoswap-storage/SessionSlot.h',

    # Build392: keep the Build391 launch runtime unchanged; correct candidate hashes from canonical Git blobs rather than Windows CRLF bytes.
    'build-utils/private-test-373-recipient.pem',
    '.github/workflows/neoswap-relay-check.yml',
    'NOTICE.md',
    'assets/legal/Guest-Page-Relay-MIT.txt',
    'build-utils/configure_neoswap_relay.py',
    'native/neoswap-relay/Backend.cpp',
    'native/neoswap-relay/Backend.h',
    'native/neoswap-relay/Info.plist',
    'native/neoswap-relay/LICENSE',
    'native/neoswap-relay/NeoSwapPageRelay.entitlements',
    'native/neoswap-relay/NeoSwapPageRelay.h',
    'native/neoswap-relay/NeoSwapPageRelay.mm',
    'native/neoswap-relay/NeoSwapPageRelayHandler.h',
    'native/neoswap-relay/NeoSwapPageRelayHandler.mm',
    'native/neoswap-relay/relay_macos_probe.mm',
    'native/neoswap-relay/run_relay_macos_probe.sh',
    'packages/neo_swap/ios/Classes/NeoSwapRelay.h',
    'packages/neo_swap/ios/Classes/NeoSwapRelayService.h',
    'packages/neo_swap/ios/Classes/NeoSwapRelayService.mm',
    'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3CoreABI.h',

    '.gitignore',
    '.github/workflows/cheats-media-check.yml',
    '.github/workflows/dolphin-motion-check.yml',
    '.github/workflows/dusklight-core.yml',
    '.github/workflows/ios-ci.yml',
    '.github/workflows/neoswap-check.yml',
    '.github/workflows/neoswap-1gib-proof.yml',
    '.github/workflows/neoswap-vulkan-proof.yml',
    '.github/workflows/neoswap-vulkan-1gib-proof.yml',
    '.github/workflows/neoswap-donation-check.yml',
    '.github/workflows/neoswap-ipa.yml',
    '.github/workflows/rpcs3-core.yml',
    'assets/legal/Dusklight-CC0-1.0.txt',
    'build-utils/build_rpcs3_embedded_core.sh',
    'build-utils/rpcs3_core_syntax_gate.py',
    'build-utils/dolphin_motion_localizations.py',
    'build-utils/dusklight/build_core.py',
    'build-utils/dusklight/source.json',
    'build-utils/kartpad/migration-target.json',
    'build-utils/kartpad/inspect_personal_pack.py',
    'build-utils/configure_neoswap_donor.py',
    'build-utils/embed_neoswap_donor_entitlements.py',
    'build-utils/embed_legal_bundle.py',
    'build-utils/private-test-368-recipient.pem',
    'build-utils/rpcs3/canonical-source.json',
    'build-utils/rpcs3/embedded-core.patch',
    'build-utils/validate_neoswap_ipa.py',
    'build-utils/validate_neoswap_vulkan_evidence.py',
    'build-utils/validate_dusklight_ipa.py',
    'build-utils/validate_rpcs3_ipa.py',
    'build-utils/validate_single_ipa_distribution.py',
    'lib/data/datasources/sqlite_database_service.dart',
    'lib/l10n/neoswap_locale.dart',
    'lib/models/game_model.dart',
    'lib/screens/settings_screen/neoswap_dialog.dart',
    'lib/services/game/game_list_service.dart',
    'lib/services/ports_display_title.dart',
    'lib/services/ports_game_identity.dart',
    'native/dolphin_motion/strings.json',
    'native/cheats/NeoCheatDocument.h',
    'native/dolphin_textures/labels.json',
    'native/dusklight/upstream-manifest.json',
    'native/dusklight/upstream/CMakeLists.txt',
    'native/dusklight/upstream/extern/aurora/lib/dolphin/AR.cpp',
    'native/dusklight/upstream/extern/aurora/lib/webgpu/gpu.cpp',
    'native/dusklight/upstream/extern/aurora/lib/webgpu/gpu.hpp',
    'native/neoswap/NeoSwapClient.h',
    'native/neoswap/localizations.json',
    'native/neoswap-donation/Broker.cpp',
    'native/neoswap-donation/Broker.h',
    'native/neoswap-donation/DonorLedger.h',
    'native/neoswap-donation/Info.plist',
    'native/neoswap-donation/MetalDonationProbe.h',
    'native/neoswap-donation/VulkanDonationProbe.h',
    'native/neoswap-donation/NeoSwapDonor.entitlements',
    'native/neoswap-donation/NeoSwapDonorIPC.h',
    'native/neoswap-donation/NeoSwapDonorIPC.mm',
    'native/neoswap-donation/NeoSwapDonorRequestHandler.h',
    'native/neoswap-donation/NeoSwapDonorRequestHandler.mm',
    'native/neoswap-donation/NeoSwapMachHandle.h',
    'native/neoswap-donation/NeoSwapMachHandle.mm',
    'native/neoswap-donation/Pool.cpp',
    'native/neoswap-donation/Pool.h',
    'native/neoswap-donation/ipc_macos_probe.mm',
    'native/neoswap-donation/macOS_probe.cpp',
    'native/neoswap-donation/references.json',
    'native/neoswap-donation/run_ipc_macos_probe.sh',
    'native/neoswap-donation/run_macos_probe.sh',
    'packages/dolphin_internal_bridge/ci/verify_ipa.py',
    'packages/dolphin_internal_bridge/ios/Classes/NeoCheatDocument.h',
    'packages/armsx2_internal_bridge/ios/Classes/NeoCheatDocument.h',
    'packages/dolphin_internal_bridge/ios/Classes/DOLTextureLabels.h',
    'packages/dolphin_internal_bridge/ios/Classes/DOLTextureSettings.h',
    'packages/dolphin_internal_bridge/ios/Classes/DOLTextureStore.h',
    'packages/dolphin_internal_bridge/ios/Classes/DOLTextureZip.h',
    'packages/dolphin_internal_bridge/ios/Classes/DolphinInternalBridgePlugin.mm',
    'packages/dolphin_internal_bridge/ios/Classes/DolphinPhoneShakeLabels.h',
    'packages/dolphin_internal_bridge/ios/Classes/DolphinSessionMenu.mm',
    'packages/dolphin_internal_bridge/ios/Classes/TouchController/DolphinPhoneShake.swift',
    'packages/dolphin_internal_bridge/ios/Classes/TouchController/DolphinPhoneShakeBinding.h',
    'packages/dolphin_internal_bridge/ios/Classes/TouchController/DolphinPhoneShakeRouting.h',
    'packages/dolphin_internal_bridge/ios/Classes/TouchController/DolphinPhoneShakeRouting.mm',
    'packages/dolphin_internal_bridge/ios/Classes/TouchController/DolphinShakeDetector.swift',
    'packages/dolphin_internal_bridge/ios/Classes/TouchController/DolphinTouchOverlay.swift',
    'packages/dolphin_internal_bridge/ios/Classes/TouchController/TCManagerInterface.h',
    'packages/dolphin_internal_bridge/ios/Classes/TouchController/TCManagerInterface.mm',
    'packages/dolphin_internal_bridge/ios/dolphin_internal_bridge.podspec',
    'packages/neo_swap/ios/Classes/NeoSwap.cpp',
    'packages/neo_swap/ios/Classes/NeoSwapClientStats.h',
    'packages/neo_swap/ios/Classes/NeoSwapHost.h',
    'packages/neo_swap/ios/Classes/NeoSwapPlugin.mm',
    'packages/neo_swap/ios/neo_swap.podspec',
    'packages/rpcs3_internal_bridge/ios/Classes/NeoSwapUsagePolicy.h',
    'packages/rpcs3_internal_bridge/ios/Classes/RPCS3InGameLocalization.mm',
    'packages/rpcs3_internal_bridge/ios/Classes/RPCS3PerformanceOverlay.h',
    'packages/rpcs3_internal_bridge/ios/Classes/RPCS3PerformanceOverlay.mm',
    'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm',
}
SUPPORT_FILES = {
    'test/neoswap_memory_samples_test.cpp',
    'test/neoplay_deployment_project_test.py',
    'test/check_neo_swap_simulator.py',
    'docs/neoswap-build398-memory-logs.md',
    'native/neoswap-storage/run_source_validation.py',
    'native/neoswap-storage/tests/source_archive_test.cpp',
    'build-utils/validate_source_archive_evidence.py',
    'test/neoswap_source_archive_host_test.py',
    'test/rpcs3_source_archive_test.py',
    'test/rpcs3_core_syntax_gate_test.py',
    'test/native/rpcs3_source_archive_client_test.cpp',
    # Actual mutable block/file cycle, C boundary and Swift interop proofs.
    'native/neoswap-storage/run_managed_validation.py',
    'native/neoswap-storage/tests/managed_swap_test.cpp',
    'native/neoswap-storage/tests/managed_swap_abi_test.cpp',
    'native/neoswap-storage/tests/managed_swap_swift_test.swift',
    'docs/neoswap-managed-swap-stage1.md',
    'docs/neoswap-managed-swap-stage1-linux-proof.json',
    'build-utils/validate_managed_swap_evidence.py',
    'test/neoswap_managed_swap_host_test.py',
    # Build398: menu behavior, NeoPlay navigation regression, and device evidence.
    'test/native/rpcs3_embedded_menu_input_test.cpp',
    'test/rpcs3_input_bridge_test.py',
    'test/jit_backend_preference_service_test.dart',
    'docs/neoswap-build396-findings.md',
    'docs/neoswap-framework-direction.md',
    # Exact consumer/service/GPU evidence.
    'build-utils/validate_shader_storage_evidence.py',
    'native/neoswap-storage/run_shader_validation.py',
    'native/neoswap-storage/tests/shader_cache_test.cpp',
    'native/neoswap-storage/tests/vulkan_shader_storage.cpp',
    'native/neoswap-storage/tests/service_runtime.mm',
    'test/neoswap_shader_storage_test.dart',
    'test/neoswap_shader_storage_host_test.py',
    'docs/neoswap-storage-build396.md',

    'native/neoswap-storage/StorageABI.h',
    'native/neoswap-storage/Client.h',
    'native/neoswap-storage/ShaderKey.h',
    'test/rpcs3_shader_storage_test.py',
    'test/native/rpcs3_shader_storage_client_test.cpp',
    # Isolated native storage module; no production Core or IPA hookup.
    ".github/workflows/neoswap-storage-prototype.yml",
    "docs/neoswap-storage-prototype.md",
    "native/neoswap-storage/ApplePressure.cpp",
    "native/neoswap-storage/ApplePressure.h",
    "native/neoswap-storage/CacheEntry.h",
    "native/neoswap-storage/Metrics.cpp",
    "native/neoswap-storage/Store.cpp",
    "native/neoswap-storage/Store.h",
    "native/neoswap-storage/run_validation.py",
    "native/neoswap-storage/tests/benchmark.cpp",
    "native/neoswap-storage/tests/store_test.cpp",
    'test/neoswap_cpu_buffers_test.cpp',
    'test/neoswap_pool_fragmentation_test.cpp',
    'docs/neoswap-guest-relay-build373.md',
    'docs/neoswap-guest-relay-build372.md',
    # Relay ownership/alias/error checks and exact Core identity fixture.
    'test/native/rpcs3_neoswap_relay_test.cpp',
    'test/neoswap_relay_extension_test.py',
    'test/neoswap_relay_simulator_test.py',
    'test/relay_backend_test.cpp',
    'test/rpcs3_neoswap_relay_test.py',
    'test/rpcs3_build306_single_path_test.py',

    'test/cheat_bulk_parser_test.cpp',
    'test/cheat_bulk_store_test.mm',
    'test/cheat_editor361_ui_test.py',
    'docs/dolphin-phone-shake-routing.md',
    'docs/import-memory-build368.md',
    'docs/native-updates-20260930.md',
    'docs/neoswap-device-analysis-20260930.md',
    'docs/rpcs3-xitrix-v0101-audit.md',
    'test/check_neo_swap_scope.py',
    'test/cheat_bulk_scope_test.py',
    'test/dolphin_account_267_test.py',
    'test/dolphin_motion_localizations_test.py',
    'test/dolphin_pacing362_ui_test.py',
    'test/dolphin_phone_shake_binding_test.cpp',
    'test/dolphin_phone_shake_routing_test.mm',
    'test/dolphin_phone_shake_routing_test.py',
    'test/dolphin_phone_shake_test.py',
    'test/dolphin_texture_localizations_test.py',
    'test/dolphin_texture_store_test.mm',
    'test/dolphin_texture_zip_test.cpp',
    'test/dolphin_texture_zip_test.py',
    'test/dusklight_bridge_contract_test.py',
    'test/dusklight_terminal_shutdown_test.py',
    'test/import_memory_candidate_scope_test.py',
    'test/neoswap_bridge_syntax_stub_test.py',
    'test/kartpad_display_title_test.dart',
    'test/kartpad_personal_pack_test.py',
    'test/legal_bundle_preflight_test.py',
    'test/native/rpcs3_neoswap_stats_getter_test.cpp',
    'test/native/rpcs3_spu_analyzer_support.h',
    'test/native/rpcs3_spu_branch_analyzer_test.cpp',
    'test/native/rpcs3_vk_conditional_render_test.cpp',
    'test/native/rpcs3_vk_memory_pressure_test.cpp',
    'test/neo_swap_core_pin_test.py',
    'test/rpcs3_neoswap_vulkan_buffer_test.py',
    'test/native/rpcs3_neoswap_vulkan_buffer_test.cpp',
    'test/neo_swap_dialog_test.dart',
    'test/neoswap/control_probe.mm',
    'test/neoswap_client_stats_test.cpp',
    'test/neoswap_capacity_probe_test.cpp',
    'test/neoswap_demand_test.cpp',
    'test/neoswap_evidence_lifecycle_test.py',
    'test/neoswap_vulkan_evidence_test.py',
    'test/neoswap_donor_contract_test.py',
    'test/neoswap_donor_ledger_test.cpp',
    'test/neoswap/Flutter/Flutter.h',
    'test/neoswap_donor_simulator_test.py',
    'test/neoswap_test.cpp',
    'test/neoswap_usage_policy_test.cpp',
    'test/rpcs3_neoswap_localizations_test.py',
    'test/rpcs3_xitrix_v0101_native_test.py',
    'test/single_ipa_distribution_test.py',
    'test/stikjit_scoped_host_test.py',
}
# Build397: explicitly owner-authorized NeoPlay, Apple TV guidance and battery HUD.
# Preserve every Build396 allocator/Core assertion below; add only these reviewed paths.
PRODUCTION_FILES |= {
    '.github/workflows/neoplay-check.yml',
    'build-utils/configure_neoplay_ios.py',
    'build-utils/neoplay/local-network.json',
    'build-utils/neoplay_native_project.rb',
    'build-utils/neoplay_resources.rb',
    'build-utils/validate_neoplay_ipa.py',
    'lib/l10n/neoplay_companion_locale.dart',
    'lib/l10n/neoplay_locale.dart',
    'lib/main.dart',
    'lib/screens/settings_screen/new_settings_options/tools_settings_content.dart',
    'lib/widgets/neoplay_apple_tv_card.dart',
    'lib/widgets/neoplay_dialog.dart',
    'lib/widgets/neoplay_game_hud_host.dart',
    'packages/neoplay_bridge/ios/Classes/NPAirPlayMonitor.swift',
    'packages/neoplay_bridge/ios/Classes/NPCapture.swift',
    'packages/neoplay_bridge/ios/Classes/NPCompanionPolicy.swift',
    'packages/neoplay_bridge/ios/Classes/NPController.swift',
    'packages/neoplay_bridge/ios/Classes/NPControllerBatteryMonitor.swift',
    'packages/neoplay_bridge/ios/Classes/NPDiagnostics.swift',
    'packages/neoplay_bridge/ios/Classes/NPDiscovery.swift',
    'packages/neoplay_bridge/ios/Classes/NPGameHUD.swift',
    'packages/neoplay_bridge/ios/Classes/NPGameHUDAnchor.swift',
    'packages/neoplay_bridge/ios/Classes/NPGoogleCast.swift',
    'packages/neoplay_bridge/ios/Classes/NPHTTPServer.swift',
    'packages/neoplay_bridge/ios/Classes/NPMuxer.swift',
    'packages/neoplay_bridge/ios/Classes/NPPolicy.swift',
    'packages/neoplay_bridge/ios/Classes/NPWindowsTransport.swift',
    'packages/neoplay_bridge/ios/Classes/NeoPlayBridgePlugin.swift',
    'packages/neoplay_bridge/ios/neoplay_bridge.podspec',
    'packages/neoplay_bridge/lib/neoplay_bridge.dart',
    'packages/neoplay_bridge/pubspec.yaml',
    'pubspec.yaml',
    'tools/neoplay-receiver/.gitignore',
    'tools/neoplay-receiver/index.html',
    'tools/neoplay-receiver/package-lock.json',
    'tools/neoplay-receiver/package.json',
    'tools/neoplay-receiver/player.mjs',
    'tools/neoplay-receiver/protocol.mjs',
    'tools/neoplay-receiver/server.mjs',
}
SUPPORT_FILES |= {
    'build-utils/neoplay/collect_fixtures.py',
    'docs/neoplay/APPLE_TV_AND_CONTROLLER_BATTERY.md',
    'docs/neoplay/BUILD397.md',
    'docs/neoplay/README.md',
    'docs/neoplay/companion-validation-2026-10-02.json',
    'docs/neoplay/validation-2026-10-02.json',
    'test/neoplay/companion_tests.swift',
    'test/neoplay/encoded_media_tests.swift',
    'test/neoplay/native_tests.swift',
    'test/neoplay_build397_integration_test.py',
    'test/neoplay_companion_contract_test.py',
    'test/neoplay_companion_test.dart',
    'test/neoplay_config_test.py',
    'test/neoplay_dialog_test.dart',
    'test/neoplay_ipa_packaging_test.py',
    'test/neoplay_locale_test.dart',
    'tools/neoplay-receiver/playback-smoke.mjs',
    'tools/neoplay-receiver/test/receiver.test.mjs',
}

approved = set(manifest['files_sha256'])
assert approved == PRODUCTION_FILES, 'Production whitelist/manifest mismatch: ' + str(approved ^ PRODUCTION_FILES)
assert set(manifest['git_modes']) == approved
for path, expected in manifest['files_sha256'].items():
    file = ROOT / path
    assert stat.S_ISREG(file.lstat().st_mode), 'Non-regular approved production file: ' + path
    assert hashlib.sha256(file.read_bytes()).hexdigest() == expected, 'Approved production hash changed: ' + path
    mode = '100755' if os.stat(file).st_mode & 0o111 else '100644'
    assert mode == manifest['git_modes'][path], 'Approved executable mode changed: ' + path
    old = subprocess.check_output(['git', 'ls-tree', BASE, '--', path], cwd=ROOT, text=True)
    if old:
        assert mode == old.split()[0], 'Existing production mode changed: ' + path
assert set(manifest['support_files_sha256']) == SUPPORT_FILES, 'Explicit support identity set changed'
assert set(manifest['support_git_modes']) == SUPPORT_FILES, 'Explicit support mode set changed'
for path, expected in manifest['support_files_sha256'].items():
    file = ROOT / path
    assert stat.S_ISREG(file.lstat().st_mode), 'Non-regular approved support file: ' + path
    assert hashlib.sha256(file.read_bytes()).hexdigest() == expected, 'Approved support hash changed: ' + path
    mode = '100755' if os.stat(file).st_mode & 0o111 else '100644'
    assert mode == manifest['support_git_modes'][path], 'Approved support mode changed: ' + path
    old = subprocess.check_output(['git', 'ls-tree', BASE, '--', path], cwd=ROOT, text=True)
    if old:
        assert mode == old.split()[0], 'Existing support mode changed: ' + path

# Compare the final working tree and the index independently. A staged change
# canceled only in the working tree remains a source delta that needs review.
# New source files need the separate untracked query. Git-ignored generated
# build/artifact/cache output is intentionally outside the source candidate.
tracked = subprocess.check_output(['git', 'diff', '--no-renames', '--name-only', '-z', BASE, '--'], cwd=ROOT)
cached = subprocess.check_output(['git', 'diff', '--cached', '--no-renames', '--name-only', '-z', BASE, '--'], cwd=ROOT)
untracked = subprocess.check_output(['git', 'ls-files', '--others', '--exclude-standard', '-z'], cwd=ROOT)
changed = {path.decode('utf-8') for path in (tracked + cached + untracked).split(b'\0') if path}
unexpected = changed - approved - SUPPORT_FILES - {MANIFEST_PATH}
assert not unexpected, 'Unapproved candidate files (including untracked): ' + str(sorted(unexpected))
reviewed_hashes = manifest['files_sha256'] | manifest['support_files_sha256']
reviewed_modes = manifest['git_modes'] | manifest['support_git_modes']
for path in (item.decode('utf-8') for item in cached.split(b'\0') if item):
    if path == MANIFEST_PATH:
        continue
    entry = subprocess.check_output(['git', 'ls-files', '--stage', '-z', '--', path], cwd=ROOT)
    rows = [row for row in entry.split(b'\0') if row]
    assert len(rows) == 1, 'Missing or unmerged indexed candidate file: ' + path
    metadata, indexed_path = rows[0].split(b'\t', 1)
    mode, object_id, stage = metadata.decode('ascii').split()
    assert indexed_path.decode('utf-8') == path and stage == '0', 'Invalid candidate index entry: ' + path
    assert mode == reviewed_modes[path], 'Indexed candidate mode differs from reviewed file: ' + path
    data = subprocess.check_output(['git', 'cat-file', 'blob', object_id], cwd=ROOT)
    assert hashlib.sha256(data).hexdigest() == reviewed_hashes[path], 'Indexed candidate hash differs from reviewed file: ' + path


def before(path):
    return subprocess.check_output(['git', 'show', BASE + ':' + path], cwd=ROOT)


assert (ROOT / '.gitignore').read_bytes() == before('.gitignore') + (
    b'# Materialized from the canonical donation sources before CocoaPods installation.\n'
    b'/packages/neo_swap/ios/Classes/Donation/\n'
    b'# Materialized from the canonical guest relay sources before CocoaPods installation.\n'
    b'/packages/neo_swap/ios/Classes/Relay/\n'
    b'\n# Canonical storage host copies, generated before CocoaPods.\n'
    b'packages/neo_swap/ios/Classes/Storage/\n'
), 'Unrelated source/build exclusions changed'


# Preserve the original three JIT helper bundles, their launch/pairing scripts,
# all unrelated core recipes and save routing: none is whitelisted above.
for path in (
    'native/dolphin_internal_helper/Info.plist',
    'native/rpcs3_internal_helper/Info.plist',
    'native/armsx2_internal_helper/Info.plist',
    'packages/neo_swap/ios/Classes/NeoSwap.h',
    'lib/services/kartpad_internal_service.dart',
    'build-utils/armsx2/source.json',
    'build-utils/kartpad/source.json',
    'build-utils/stikjit/source.json',
):
    assert (ROOT / path).read_bytes() == before(path), 'Protected helper/core/ABI/routing changed: ' + path

# Original allocator/probe API unchanged: only one boolean preference.
storage_method = "\n  /// Optional regenerable shader cache; applies on the next game launch.\n  static Future<Map<String, dynamic>> setShaderStorage(bool enabled) =>\n      _call('setShaderStorage', {'enabled': enabled});\n"
assert (ROOT/'packages/neo_swap/lib/neo_swap.dart').read_text().replace(storage_method,'') == before('packages/neo_swap/lib/neo_swap.dart').decode('utf-8')

# The requested Dusklight update replaces only its reviewed upstream pins.
# Keep its disc routing and SDL source identical to the preceding candidate.
old_dusklight = json.loads(before('build-utils/dusklight/source.json'))
new_dusklight = json.loads((ROOT / 'build-utils/dusklight/source.json').read_text())
assert set(new_dusklight) == set(old_dusklight) | {'release'}
assert new_dusklight['release'] == 'v2.0.3'
assert new_dusklight['commit'] == '40457c6adb381928e4b5fef6ed459ed291edd5e2'
assert new_dusklight['submodules'] == {
    'aurora': '3227d76c60e1e782ca576610bce61c9e7744d8be',
    'borealis': '4ac5e7052a8c49a122f8d57f626b5c75c5ca6968',
}
for key in set(old_dusklight) - {'commit', 'submodules'}:
    assert new_dusklight[key] == old_dusklight[key], ('Dusklight routing/SDL changed', key)

for workflow_path in ('.github/workflows/neoswap-ipa.yml', '.github/workflows/ios-ci.yml'):
    workflow = (ROOT / workflow_path).read_text()
    old_workflow = before(workflow_path).decode('utf-8')
    for key in ('DOLPHIN_SHA', 'DOLPHIN_CORE_HOST_SHA', 'ARMSX2_CORE_HOST_SHA',
                'KARTPAD_CORE_HOST_SHA', 'KARTPAD_CORE_RUN_ID'):
        pattern = r'(?m)^      ' + key + r': (.+)$'
        assert re.findall(pattern, workflow) == re.findall(pattern, old_workflow), (workflow_path, key)
    pattern = r'(?m)^      DUSKLIGHT_CORE_HOST_SHA: (.+)$'
    if workflow_path == '.github/workflows/neoswap-ipa.yml':
        # Related owned-GLSL consumer requires this exact newly built Core;
        # success and complete identity remain mandatory before IPA assembly.
        assert re.findall(r'(?m)^      RPCS3_CORE_HOST_SHA: (.+)$', workflow) == ['2e18a46d3f7733ed7ae8f237615e2c7a4fd2501d']
        assert re.findall(r'(?m)^      RPCS3_CORE_RUN_ID: (.+)$', workflow) == ["'37103098994'"]
        assert "assert result['head_sha']==os.environ['RPCS3_CORE_HOST_SHA']" in workflow
        assert "assert result['conclusion']=='success'" in workflow
        assert 'validate_core_input_identity(identity)' in workflow
        assert "assert identity['neoswap_source_archive_abi'] == 1" in workflow
        assert re.findall(pattern, workflow) == ['94ed2d91e1547e1879fab214b6ef082b642dff84']
        assert re.findall(r'(?m)^      DUSKLIGHT_CORE_RUN_ID: (.+)$', workflow) == ["'36720032937'"]
        assert "identity['source_release'] == pins['release'] == 'v2.0.3'" in workflow
        assert "result['head_sha'] == os.environ['DUSKLIGHT_CORE_HOST_SHA']" in workflow
        assert "identity['submodules'] == pins['submodules']" in workflow
    else:
        assert re.findall(pattern, workflow) == re.findall(pattern, old_workflow)
        for key in ('RPCS3_CORE_HOST_SHA', 'RPCS3_CORE_RUN_ID'):
            assert re.findall(r'(?m)^      '+key+r': (.+)$', workflow) == re.findall(r'(?m)^      '+key+r': (.+)$', old_workflow)
workflow = (ROOT / '.github/workflows/neoswap-ipa.yml').read_text()
assert 'contents: write' not in workflow and 'gh release create' not in workflow

broker = (ROOT / 'packages/neo_swap/ios/Classes/NeoSwap.cpp').read_text()
assert 'c->capacity_bytes > 8 * 1024 * MiB' in broker
assert '(kind != NEOSWAP_CPU_DATA && kind != NEOSWAP_CPU_CACHE)' in broker
assert broker.count('struct Broker {') == 1
assert '#ifdef NEOSWAP_TESTING' in broker

catalog = json.loads((ROOT / 'native/dolphin_textures/labels.json').read_text())
assert set(catalog) == {'en', 'es', 'ru', 'zh', 'zh_Hant', 'pt', 'fr', 'de', 'it', 'id', 'ja', 'ko'}
for locale, values in catalog.items():
    assert set(values) == set(catalog['en']) and all(values.values()), locale
    for key, value in values.items():
        assert set(re.findall(r'\{\w+\}', value)) == set(re.findall(r'\{\w+\}', catalog['en'][key])), (locale, key)
print('PASS requested candidate scope: explicit hashed production paths, tracked/untracked deltas, '
      'unchanged original JIT helpers/other cores/save routing and complete texture locales; device evidence separate')
