"""Reject reuse if an input outside the reviewed library/RetroArch delta changed.

Historical results retain their real SHA; this is not new simulator evidence.
The closed tree comparison includes tests, lockfiles, native recipes and assets.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
REFERENCE = 'af0d539b4b8b3b95fe0434fc1f72c74d7c0b6eca'
REFERENCE_RUN = 37781416715
# Receiver-only evidence was added after the last complete NeoStation build.
# It is not a product change and has its own successful, pinned CI provenance.
RECEIVER_REFERENCE = '3c70b5f4adb80232d3c50d0b648520c7db5afe2c'
RECEIVER_RUN = 37857669052
RECEIVER_INPUT = 'test/fixtures/retroarch_handoff/SourceReceiverTests.swift'
DELTA = {
    'lib/data/datasources/sqlite_database_service.dart',
    'lib/data/datasources/sqlite_service.dart', 'lib/main.dart',
    'lib/providers/sqlite_config_provider.dart',
    'lib/providers/sqlite_config_provider/scanning.dart',
    'lib/repositories/system_repository.dart',
    'lib/screens/settings_screen/new_settings_options/directories_settings_content.dart',
    'lib/screens/systems_screen/system_content.dart', 'lib/services/config_service.dart',
    'lib/services/game/game_launch_service.dart',
    'lib/services/ios_rom_library_root_resolver.dart',
    'lib/services/retroarch_library_protocol.dart',
    'lib/services/retroarch_library_service.dart',
    'lib/services/retroarch_folder_recovery.dart',
    'lib/services/retroarch_library_importer.dart',
    'packages/external_folder_access/ios/Classes/ExternalFolderAccessPlugin.swift',
    'packages/external_folder_access/ios/Classes/RetroArchURLHandoff.swift',
    'packages/external_folder_access/lib/external_folder_access.dart',
    'test/armsx2_retroarch_routing_isolation_test.dart',
    'test/ios_selective_rollback_test.dart', 'test/retroarch_folder_recovery_test.dart',
    'test/retroarch_library_restoration_test.dart',
    'test/retroarch_library_cache_test.dart', 'test/retroarch_sync_locale_test.dart',
    'test/retroarch_url_handoff_test.swift', 'test/retroarch_launch_diagnostics_test.dart',
    'test/retroarch_baseline_scope_test.py', 'test/retroarch_real_export_test.dart',
    'test/retroarch_playlist_repair_test.py',
    'test/fixtures/retroarch_handoff/ConsentTests.swift',
    'test/fixtures/retroarch_handoff/LegacyRetroArchURLHandoff.swift',
    'test/fixtures/retroarch_handoff/Receiver.swift',
    'test/fixtures/retroarch_handoff/Sender.swift',
    'test/fixtures/retroarch_handoff/PatchedSceneSyntax.m',
    'test/retroarch_relaunch_cache_test.dart',
    'test/library_scan_restart_test.dart', 'test/delivery_pipeline_test.py',
    'test/rom_folder_registration_test.dart',
    'build-utils/verify_delivery_reuse.py', 'build-utils/delivery_metrics.py',
    'build-utils/sign_delivery.py', 'build-utils/delivery_benchmark.py',
    'build-utils/delivery_cipher.py', 'build-utils/delivery-422-recipient.pem',
    'build-utils/delivery-423-recipient.pem',
    'build-utils/delivery-424-recipient.pem',
}
# Embedded libretro engine requested by the maintainer on 9 October 2026:
# every new or changed validation input of that change, file by file.
LIBRETRO_DELTA = {
    'build-utils/libretro/build_cores.py',
    'build-utils/libretro/cores.json',
    'build-utils/validate_libretro_ipa.py',
    'lib/l10n/libretro_locale.dart',
    'lib/screens/game_screen/game_settings_dialog/game_settings_emulator_tab.dart',
    'lib/screens/game_screen/my_games_list.dart',
    'lib/services/embedded_ios_session_status.dart',
    'lib/services/game_launch_manager.dart',
    'lib/services/libretro_core_catalog.dart',
    'lib/services/libretro_internal_service.dart',
    'lib/widgets/libretro_internal_playlist_actions.dart',
    'packages/libretro_internal_bridge/ios/Classes/LibretroAchievements.h',
    'packages/libretro_internal_bridge/ios/Classes/LibretroAchievements.m',
    'packages/libretro_internal_bridge/ios/Classes/LibretroAudioOutput.h',
    'packages/libretro_internal_bridge/ios/Classes/LibretroAudioOutput.m',
    'packages/libretro_internal_bridge/ios/Classes/LibretroCoreHost.h',
    'packages/libretro_internal_bridge/ios/Classes/LibretroCoreHost.m',
    'packages/libretro_internal_bridge/ios/Classes/LibretroCoreOptions.h',
    'packages/libretro_internal_bridge/ios/Classes/LibretroCoreOptions.m',
    'packages/libretro_internal_bridge/ios/Classes/LibretroGLRenderer.h',
    'packages/libretro_internal_bridge/ios/Classes/LibretroGLRenderer.m',
    'packages/libretro_internal_bridge/ios/Classes/LibretroGameViewController.h',
    'packages/libretro_internal_bridge/ios/Classes/LibretroGameViewController.m',
    'packages/libretro_internal_bridge/ios/Classes/LibretroInputState.h',
    'packages/libretro_internal_bridge/ios/Classes/LibretroInputState.m',
    'packages/libretro_internal_bridge/ios/Classes/LibretroInternalBridgePlugin.h',
    'packages/libretro_internal_bridge/ios/Classes/LibretroInternalBridgePlugin.m',
    'packages/libretro_internal_bridge/ios/Classes/LibretroJit.h',
    'packages/libretro_internal_bridge/ios/Classes/LibretroJit.m',
    'packages/libretro_internal_bridge/ios/Classes/LibretroMetalPresenter.h',
    'packages/libretro_internal_bridge/ios/Classes/LibretroMetalPresenter.m',
    'packages/libretro_internal_bridge/ios/Classes/LibretroSession.h',
    'packages/libretro_internal_bridge/ios/Classes/LibretroSession.m',
    'packages/libretro_internal_bridge/ios/Classes/LibretroSessionMenu.h',
    'packages/libretro_internal_bridge/ios/Classes/LibretroSessionMenu.m',
    'packages/libretro_internal_bridge/ios/Classes/LibretroStateCodec.h',
    'packages/libretro_internal_bridge/ios/Classes/LibretroStateCodec.m',
    'packages/libretro_internal_bridge/ios/Classes/LibretroTouchOverlay.h',
    'packages/libretro_internal_bridge/ios/Classes/LibretroTouchOverlay.m',
    'packages/libretro_internal_bridge/ios/Classes/LibretroVulkanRenderer.h',
    'packages/libretro_internal_bridge/ios/Classes/LibretroVulkanRenderer.m',
    'packages/libretro_internal_bridge/ios/Classes/LibretroZipReader.h',
    'packages/libretro_internal_bridge/ios/Classes/LibretroZipReader.m',
    'packages/libretro_internal_bridge/ios/ThirdParty/include/libretro/SOURCE.txt',
    'packages/libretro_internal_bridge/ios/ThirdParty/include/libretro/libretro.h',
    'packages/libretro_internal_bridge/ios/ThirdParty/include/libretro/libretro_vulkan.h',
    'packages/libretro_internal_bridge/ios/ThirdParty/include/vk_video/vulkan_video_codec_av1std.h',
    'packages/libretro_internal_bridge/ios/ThirdParty/include/vk_video/vulkan_video_codec_av1std_decode.h',
    'packages/libretro_internal_bridge/ios/ThirdParty/include/vk_video/vulkan_video_codec_av1std_encode.h',
    'packages/libretro_internal_bridge/ios/ThirdParty/include/vk_video/vulkan_video_codec_h264std.h',
    'packages/libretro_internal_bridge/ios/ThirdParty/include/vk_video/vulkan_video_codec_h264std_decode.h',
    'packages/libretro_internal_bridge/ios/ThirdParty/include/vk_video/vulkan_video_codec_h264std_encode.h',
    'packages/libretro_internal_bridge/ios/ThirdParty/include/vk_video/vulkan_video_codec_h265std.h',
    'packages/libretro_internal_bridge/ios/ThirdParty/include/vk_video/vulkan_video_codec_h265std_decode.h',
    'packages/libretro_internal_bridge/ios/ThirdParty/include/vk_video/vulkan_video_codec_h265std_encode.h',
    'packages/libretro_internal_bridge/ios/ThirdParty/include/vk_video/vulkan_video_codec_vp9std.h',
    'packages/libretro_internal_bridge/ios/ThirdParty/include/vk_video/vulkan_video_codec_vp9std_decode.h',
    'packages/libretro_internal_bridge/ios/ThirdParty/include/vk_video/vulkan_video_codecs_common.h',
    'packages/libretro_internal_bridge/ios/ThirdParty/include/vulkan/LICENSE.md',
    'packages/libretro_internal_bridge/ios/ThirdParty/include/vulkan/SOURCE.txt',
    'packages/libretro_internal_bridge/ios/ThirdParty/include/vulkan/vk_platform.h',
    'packages/libretro_internal_bridge/ios/ThirdParty/include/vulkan/vulkan.h',
    'packages/libretro_internal_bridge/ios/ThirdParty/include/vulkan/vulkan_core.h',
    'packages/libretro_internal_bridge/ios/ThirdParty/include/vulkan/vulkan_metal.h',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/LICENSE',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/SOURCE.txt',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/include/rc_api_editor.h',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/include/rc_api_info.h',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/include/rc_api_request.h',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/include/rc_api_runtime.h',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/include/rc_api_user.h',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/include/rc_client.h',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/include/rc_consoles.h',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/include/rc_error.h',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/include/rc_export.h',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/include/rc_hash.h',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/include/rc_runtime.h',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/include/rc_runtime_types.h',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/include/rc_util.h',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/include/rcheevos.h',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/src/rapi/rc_api_common.c',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/src/rapi/rc_api_common.h',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/src/rapi/rc_api_editor.c',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/src/rapi/rc_api_info.c',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/src/rapi/rc_api_runtime.c',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/src/rapi/rc_api_user.c',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/src/rc_client.c',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/src/rc_client_external.c',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/src/rc_client_external.h',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/src/rc_client_external_versions.h',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/src/rc_client_internal.h',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/src/rc_compat.c',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/src/rc_compat.h',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/src/rc_libretro.c',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/src/rc_libretro.h',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/src/rc_util.c',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/src/rc_version.c',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/src/rc_version.h',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/src/rcheevos/alloc.c',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/src/rcheevos/condition.c',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/src/rcheevos/condset.c',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/src/rcheevos/consoleinfo.c',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/src/rcheevos/format.c',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/src/rcheevos/lboard.c',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/src/rcheevos/memref.c',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/src/rcheevos/operand.c',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/src/rcheevos/rc_internal.h',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/src/rcheevos/rc_validate.c',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/src/rcheevos/rc_validate.h',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/src/rcheevos/richpresence.c',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/src/rcheevos/runtime.c',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/src/rcheevos/runtime_progress.c',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/src/rcheevos/trigger.c',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/src/rcheevos/value.c',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/src/rhash/aes.c',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/src/rhash/aes.h',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/src/rhash/cdreader.c',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/src/rhash/hash.c',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/src/rhash/hash_disc.c',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/src/rhash/hash_encrypted.c',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/src/rhash/hash_rom.c',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/src/rhash/hash_zip.c',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/src/rhash/md5.c',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/src/rhash/md5.h',
    'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/src/rhash/rc_hash_internal.h',
    'packages/libretro_internal_bridge/ios/libretro_internal_bridge.podspec',
    'packages/libretro_internal_bridge/lib/libretro_internal_bridge.dart',
    'packages/libretro_internal_bridge/pubspec.yaml',
    'pubspec.yaml',
    'test/cheats_media_source_contract_test.py',
    'test/frontend_media_gate_test.dart',
    'test/integrated_import_tab_contract_test.py',
    'test/libretro_core_catalog_test.dart',
    'test/libretro_core_options_test.py',
    'test/libretro_host/host_test.m',
    'test/libretro_host/stubs/Flutter/Flutter.h',
    'test/libretro_host/test_core.c',
    'test/libretro_host_test.py',
    'test/libretro_ios_syntax_test.py',
    'test/libretro_locale_test.dart',
    'test/libretro_route_contract_test.py',
    'test/localization_12_locale_coverage_test.py',
}
DELTA |= LIBRETRO_DELTA
# Obsolete files removed on 9 October 2026 at the maintainer's request: Dart
# code unreachable from lib/main.dart, the tests of that dead code, and build
# files nothing references. dusklight_locale_test now checks the live Ports
# import menu instead of the removed Dusklight-only widget.
CLEANUP_DELTA = {
    'build-utils/canonical-host-285.json',
    'build-utils/generate_import_labels.py',
    'build-utils/materialize_dolphin_isolated_v2.py',
    'build-utils/migrations/candidate302/part0.b64',
    'build-utils/patches/grid_title_build243.patch',
    'build-utils/private-test-360-recipient.pem',
    'build-utils/private-test-361-recipient.pem',
    'build-utils/private-test-362-recipient.pem',
    'build-utils/private-test-363-recipient.pem',
    'build-utils/private-test-364-recipient.pem',
    'build-utils/private-test-366-recipient.pem',
    'build-utils/private-test-367-recipient.pem',
    'build-utils/verify_delivery_reuse.py',
    'lib/models/retroarch_config_model.dart',
    'lib/services/metadata_cleanup_service.dart',
    'lib/services/retroarch_config_service.dart',
    'lib/services/retroarch_playlist_service.dart',
    'lib/services/rom_folder_organizer_service.dart',
    'lib/services/scraped_media_migration_service.dart',
    'lib/utils/switch_save_detector.dart',
    'lib/widgets/dusklight_internal_playlist_actions.dart',
    'lib/widgets/info_dialog.dart',
    'lib/widgets/selection_grid/grid_navigation.dart',
    'lib/widgets/selection_grid/selection_grid.dart',
    'lib/widgets/selection_grid/selection_grid_geometry.dart',
    'test/dusklight_locale_test.dart',
    'test/metadata_cleanup_service_test.dart',
    'test/rom_folder_organizer_service_test.dart',
    'test/selection_grid_cache_test.dart',
    'test/selection_grid_test.dart',
}
DELTA |= CLEANUP_DELTA
# Second pass, same day: declarations nothing calls (found by reference
# counts over the whole repository, iterated to a fixed point), the
# RetroAchievements hash strategies left without caller, imports they used,
# and the unused Dart wrapper of the Dolphin plugin.
UNUSED_CODE_DELTA = {
    'lib/data/datasources/sqlite_config_service.dart',
    'lib/l10n/dusklight_locale.dart',
    'lib/l10n/fork_onboarding_locale.dart',
    'lib/models/database_game_model.dart',
    'lib/models/my_systems.dart',
    'lib/providers/file_provider.dart',
    'lib/providers/menu_app_provider.dart',
    'lib/providers/neo_assets_provider.dart',
    'lib/providers/retro_achievements_provider.dart',
    'lib/providers/retroachievements/console_lookup_hash_strategy.dart',
    'lib/providers/retroachievements/default_md5_hash_strategy.dart',
    'lib/providers/retroachievements/ds_hash_strategy.dart',
    'lib/providers/retroachievements/nes_hash_strategy.dart',
    'lib/providers/retroachievements/retro_achievements_hash_strategy.dart',
    'lib/providers/retroachievements/strategy_factory.dart',
    'lib/providers/scraping_provider.dart',
    'lib/providers/sqlite_config_provider/mutators.dart',
    'lib/providers/sqlite_database_provider.dart',
    'lib/responsive.dart',
    'lib/screens/app_screen.dart',
    'lib/services/audio_policy_service.dart',
    'lib/services/game_service.dart',
    'lib/services/game_session_persistence.dart',
    'lib/services/home_music_service.dart',
    'lib/services/library_addon_service.dart',
    'lib/services/library_metadata_provider_service.dart',
    'lib/services/melonx_library_service.dart',
    'lib/services/music_player_service.dart',
    'lib/services/neo_assets_service.dart',
    'lib/services/permission_service.dart',
    'lib/services/retro_achievements_service.dart',
    'lib/services/saf_directory_service.dart',
    'lib/services/screenscraper/media_resolver.dart',
    'lib/services/screenscraper_service.dart',
    'lib/services/systems_update_service.dart',
    'lib/services/user_data_location_service.dart',
    'lib/themes/app_themes.dart',
    'lib/themes/corner_radii.dart',
    'lib/utils/centered_scroll_controller.dart',
    'lib/utils/color.dart',
    'lib/utils/gamepad_mapping.dart',
    'lib/utils/gamepad_nav.dart',
    'lib/utils/gamepad_translator.dart',
    'lib/utils/login_form_selection.dart',
    'lib/utils/optimized_md5_utils.dart',
    'lib/widgets/custom_notification.dart',
    'lib/widgets/game_view_mode_dropdown.dart',
    'packages/dolphin_internal_bridge/lib/dolphin_internal_bridge.dart',
    'packages/dolphin_internal_bridge/ios/Classes/TouchController/TCWiiPad.swift',
    'lib/models/emulator_model.dart',
    'lib/models/system_model.dart',
    'lib/services/stikjit_melonx_service.dart',
}
DELTA |= UNUSED_CODE_DELTA
# Third pass, same day, after the maintainer allowed removing unusable
# RPCS3 code: the Build 260 action-sheet menus nothing presents, the
# recovery-core patch pipeline no workflow runs, the Dolphin touch-resource
# generator, the tests of those removed files, and the RPCS3 Dart
# declarations nothing calls.
RPCS3_UNUSED_DELTA = {
    'build-utils/.rpcs3_patch_chunk00',
    'build-utils/.rpcs3_patch_chunk01',
    'build-utils/.rpcs3_patch_chunk02',
    'build-utils/.rpcs3_patch_chunk02a',
    'build-utils/.rpcs3_patch_chunk02b',
    'build-utils/.rpcs3_patch_chunk02c',
    'build-utils/.rpcs3_patch_chunk03',
    'build-utils/.rpcs3_patch_chunk03a',
    'build-utils/.rpcs3_patch_chunk04',
    'build-utils/.rpcs3_patch_chunk05',
    'build-utils/benchmark_rpcs3_pipeline_scheduler.py',
    'build-utils/build_rpcs3_recovery_core.sh',
    'build-utils/compare_rpcs3_core_profiles.py',
    'build-utils/compare_rpcs3_telemetry.py',
    'build-utils/generate_rpcs3_ios_profiles.py',
    'build-utils/materialize_rpcs3_internal.py',
    'build-utils/patch_rpcs3_armsx3_performance.py',
    'build-utils/patch_rpcs3_build251_upscale.py',
    'build-utils/patch_rpcs3_build256_host.py',
    'build-utils/patch_rpcs3_build256_savestates.py',
    'build-utils/patch_rpcs3_build258_core_architecture.py',
    'build-utils/patch_rpcs3_build258_runtime_resilience.py',
    'build-utils/patch_rpcs3_build260_modern_menu.py',
    'build-utils/patch_rpcs3_build264_gow3_core.py',
    'build-utils/patch_rpcs3_build265_core.py',
    'build-utils/patch_rpcs3_build265_host.py',
    'build-utils/patch_rpcs3_build266_v09_core.py',
    'build-utils/patch_rpcs3_build283_host.py',
    'build-utils/patch_rpcs3_build295_fixed_reservation.py',
    'build-utils/patch_rpcs3_embedded_boot.py',
    'build-utils/patch_rpcs3_iso_integrity.py',
    'build-utils/patch_rpcs3_jit_memory.py',
    'build-utils/patch_rpcs3_neostation_session.py',
    'build-utils/patch_rpcs3_performance_telemetry.py',
    'build-utils/patch_rpcs3_savestate_stability.py',
    'build-utils/patch_rpcs3_savestate_ui.py',
    'build-utils/patch_rpcs3_serial_profiles.py',
    'build-utils/patch_rpcs3_stop_reply270.py',
    'build-utils/patches/rpcs3_build243_host.patch',
    'build-utils/patches/rpcs3_build243_menu_transition.patch',
    'build-utils/patches/rpcs3_build246_safe_controls.patch',
    'build-utils/patches/rpcs3_build247_localization.patch',
    'build-utils/patches/rpcs3_build251_upscale.patch',
    'build-utils/patches/rpcs3_build264_spu_arm64_lowering.patch',
    'build-utils/patches/rpcs3_build265_core.patch',
    'build-utils/rpcs3/build266-v09-manifest.json',
    'build-utils/rpcs3/jit_arena.cpp.inc',
    'build-utils/rpcs3/jit_write_scope.h.inc',
    'build-utils/validate_rpcs3_recovery_core.py',
    'lib/l10n/rpcs3_library_locale.dart',
    'lib/l10n/rpcs3_ui_locale.dart',
    'lib/services/rpcs3_internal_service.dart',
    'lib/services/rpcs3_launch_service.dart',
    'lib/services/rpcs3_library_service.dart',
    'lib/services/rpcs3_title_catalog_service.dart',
    'packages/dolphin_internal_bridge/ci/materialize_touch_resources.py',
    'packages/dolphin_internal_bridge/ci/touch_resources.json',
    'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm',
    'packages/rpcs3_internal_bridge/vendor/README.md',
    'test/neoplay_build397_integration_test.py',
    'test/rpcs3_build251_contract_test.py',
    'test/rpcs3_build256_host_patch_test.py',
    'test/rpcs3_build258_core_profile_comparison_test.py',
    'test/rpcs3_build258_pipeline_scheduler_benchmark_test.py',
    'test/rpcs3_build260_modern_menu_test.py',
    'test/rpcs3_build265_host_test.py',
    'test/rpcs3_build266_v09_core_test.py',
    'test/rpcs3_build295_fixed_reservation_test.py',
    'test/rpcs3_embedded_boot_test.py',
    'test/rpcs3_ingame_ui_contract_test.py',
    'test/rpcs3_jit_memory_test.py',
    'test/rpcs3_performance_snapshot_test.py',
    'test/rpcs3_recovery_core_contract_test.py',
    'test/rpcs3_savestate_ui_contract_test.py',
    'test/rpcs3_silent_mode_policy_test.dart',
    'test/rpcs3_stop_reply270_test.py',
    'test/rpcs3_telemetry_comparison_test.py',
}
DELTA |= RPCS3_UNUSED_DELTA
# Same day: the Armsx2 action builder left from the retired contextual
# UIMenu, and the command handler and overload only it invoked.
ARMSX2_UNUSED_DELTA = {
    'packages/armsx2_internal_bridge/ios/Classes/Armsx2InternalBridgePlugin.mm',
}
DELTA |= ARMSX2_UNUSED_DELTA
# Embedded libretro frontend (maintainer request of 9 October 2026): PSP and
# 3DS on the embedded cores, skins per console with Delta / Provenance
# import, Metal shader presets, screen format, controls customisation,
# portrait, twelve languages. New native modules, their macOS behaviour
# tests, the Dart services and screens, and the call sites switched to the
# canonical console key. Reviewed source changes; see
# docs/libretro-skins-shaders.md.
FRONTEND_DELTA = {
    'lib/screens/libretro/libretro_consoles_screen.dart',
    'lib/screens/libretro/libretro_skin_catalog_screen.dart',
    'lib/screens/libretro/libretro_skin_manager_screen.dart',
    'lib/services/libretro_skin_catalog_service.dart',
    'lib/services/libretro_skin_service.dart',
    'packages/libretro_internal_bridge/ios/Classes/LibretroDefaultSkins.h',
    'packages/libretro_internal_bridge/ios/Classes/LibretroDefaultSkins.m',
    'packages/libretro_internal_bridge/ios/Classes/LibretroFrontendMenu.h',
    'packages/libretro_internal_bridge/ios/Classes/LibretroFrontendMenu.m',
    'packages/libretro_internal_bridge/ios/Classes/LibretroFrontendStore.h',
    'packages/libretro_internal_bridge/ios/Classes/LibretroFrontendStore.m',
    'packages/libretro_internal_bridge/ios/Classes/LibretroGeometry.h',
    'packages/libretro_internal_bridge/ios/Classes/LibretroGeometry.m',
    'packages/libretro_internal_bridge/ios/Classes/LibretroInputMap.h',
    'packages/libretro_internal_bridge/ios/Classes/LibretroInputMap.m',
    'packages/libretro_internal_bridge/ios/Classes/LibretroOrientation.h',
    'packages/libretro_internal_bridge/ios/Classes/LibretroOrientation.m',
    'packages/libretro_internal_bridge/ios/Classes/LibretroShaderLibrary.h',
    'packages/libretro_internal_bridge/ios/Classes/LibretroShaderLibrary.m',
    'packages/libretro_internal_bridge/ios/Classes/LibretroSkin.h',
    'packages/libretro_internal_bridge/ios/Classes/LibretroSkin.m',
    'packages/libretro_internal_bridge/ios/Classes/LibretroSkinLayout.h',
    'packages/libretro_internal_bridge/ios/Classes/LibretroSkinLayout.m',
    'packages/libretro_internal_bridge/ios/Classes/LibretroSkinRenderer.h',
    'packages/libretro_internal_bridge/ios/Classes/LibretroSkinRenderer.m',
    'test/libretro_frontend_test.py',
    'test/libretro_frontend_ui_contract_test.py',
    'test/libretro_host/frontend/default_skins_test.m',
    'test/libretro_host/frontend/frontend_store_test.m',
    'test/libretro_host/frontend/geometry_test.m',
    'test/libretro_host/frontend/input_map_test.m',
    'test/libretro_host/frontend/skin_layout_test.m',
    'test/libretro_host/frontend/skin_test.m',
    'test/libretro_host/shader_test.m',
    'test/libretro_shader_catalog_test.py',
    'test/libretro_shader_test.py',
    'test/libretro_skin_catalog_test.dart',
    'test/libretro_skin_manager_test.dart',
    'test/libretro_skin_service_test.dart',
    'packages/libretro_internal_bridge/ios/Classes/LibretroChromeLayout.h',
    'packages/libretro_internal_bridge/ios/Classes/LibretroChromeLayout.m',
    'test/libretro_host/frontend/chrome_layout_test.m',
    'test/libretro_playlist_actions_test.dart',
}
DELTA |= FRONTEND_DELTA
INPUT_ROOTS = ('lib/', 'packages/', 'native/', 'build-utils/', 'assets/', 'test/')

def sha(data):
    return hashlib.sha256(data).hexdigest()

def verify_tree():
    old = {}
    tree = subprocess.check_output(['git', 'ls-tree', '-r', REFERENCE], cwd=ROOT, text=True)
    for line in tree.splitlines():
        metadata, path = line.split('\t', 1)
        if path.startswith(INPUT_ROOTS) or path in ('pubspec.yaml', 'pubspec.lock'):
            old[path] = metadata.split()
    receiver_entry = subprocess.check_output(
        ['git', 'ls-tree', RECEIVER_REFERENCE, '--', RECEIVER_INPUT], cwd=ROOT, text=True)
    metadata, receiver_path = receiver_entry.strip().split('\t', 1)
    if receiver_path != RECEIVER_INPUT:
        raise ValueError('Missing pinned receiver validation input')
    old[receiver_path] = metadata.split()
    current = set(subprocess.check_output(['git', 'ls-files'], cwd=ROOT, text=True).splitlines())
    current = {p for p in current if p.startswith(INPUT_ROOTS) or p in ('pubspec.yaml', 'pubspec.lock')}
    changed = []
    unchanged = {}
    for path in sorted(set(old) | current):
        file = ROOT / path
        data = file.read_bytes() if file.is_file() else None
        oid = hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest() if data is not None else None
        if path not in old or old[path][2] != oid:
            if path not in DELTA:
                raise ValueError('Unreviewed validation input changed: ' + path)
            changed.append(path)
        else:
            mode = '100755' if file.stat().st_mode & 0o111 else '100644'
            if mode != old[path][0]:
                raise ValueError('Validation input mode changed: ' + path)
            unchanged[path] = sha(data)
    return changed, unchanged

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--offline', action='store_true')
    parser.add_argument('--output', default='build/delivery/reused-validation.json')
    args = parser.parse_args()
    changed, unchanged = verify_tree()
    run = None
    if not args.offline:
        run = json.loads(subprocess.check_output(['gh', 'api', f'repos/TarbleFR/neostation-ios/actions/runs/{REFERENCE_RUN}']))
        if run['head_sha'] != REFERENCE or run['conclusion'] != 'success' or run['path'] != '.github/workflows/neoswap-ipa.yml':
            raise ValueError('Historical complete build was not successful at the exact reference')
        jobs = json.loads(subprocess.check_output(['gh', 'api', f'repos/TarbleFR/neostation-ios/actions/runs/{REFERENCE_RUN}/jobs']))['jobs']
        build = next(j for j in jobs if 'private IPA' in j['name'])
        if build['conclusion'] != 'success' or any(s['conclusion'] != 'success' for s in build['steps']):
            raise ValueError('Historical build contains failed or skipped checks')
        receiver_run = json.loads(subprocess.check_output(['gh', 'api', f'repos/TarbleFR/neostation-ios/actions/runs/{RECEIVER_RUN}']))
        if (receiver_run['head_sha'] != RECEIVER_REFERENCE or receiver_run['conclusion'] != 'success'
                or receiver_run['path'] != '.github/workflows/retroarch-source-proof.yml'):
            raise ValueError('Pinned receiver validation was not successful')
    report = {'referenceSHA': REFERENCE, 'referenceRun': REFERENCE_RUN,
              'onlineSuccessVerified': run is not None,
              'receiverReferenceSHA': RECEIVER_REFERENCE, 'receiverReferenceRun': RECEIVER_RUN,
              'unchangedInputCount': len(unchanged),
              'unchangedInputsSha256': sha(json.dumps(unchanged, sort_keys=True).encode()),
              'changedInputsRequiringNewTests': changed,
              'deviceGameplayValidated': False}
    out = ROOT / args.output
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))

if __name__ == '__main__':
    main()
