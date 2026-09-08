"""Static reachability contract for the temporary iOS NeoSync exclusions.

The executable Dart policy tests the routing decisions themselves.  These
checks make sure the policy is actually wired into every user-facing transfer
boundary while all four emulator launch integrations remain installed and
all standalone iOS emulator NeoSync routes stay disabled.
"""

from __future__ import annotations

import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def section(source: str, start: str, end: str) -> str:
    if start not in source or end not in source:
        raise AssertionError(f"missing source-contract boundary: {start!r} / {end!r}")
    return source.split(start, 1)[1].split(end, 1)[0]


class NeoSyncIosExclusionSourceContractTests(unittest.TestCase):
    def test_emulator_launch_routes_survive_while_dolphin_neosync_is_disabled(self):
        launcher = read("lib/services/game/game_launch_service.dart")
        dolphin_route = section(
            launcher,
            "DOLPHIN_ISOLATION_BEGIN: explicit_gc_wii_route",
            "DOLPHIN_ISOLATION_END: explicit_gc_wii_route",
        )

        self.assertIn("DolphinInternalV2Service.launch", dolphin_route)
        self.assertIn("onSessionStopped:", dolphin_route)

        dolphin_sync = read("lib/providers/neosync/neosync_dolphin.dart")
        self.assertIn("bool _isDolphinGame(GameModel game) => false;", dolphin_sync)
        self.assertIn("_allDolphinLocalSaves() async => const [];", dolphin_sync)
        self.assertIn("DolphiniOS NeoSync is disabled on iOS", dolphin_sync)

        # Removing an emulator from NeoSync must not remove it from NeoStation.
        for launch_call in (
            "Rpcs3LaunchService.launchTitle",
            "MelonxLibraryService.launchGameByRomPath",
            "Armsx2LibraryService.launchGameByRomPath",
            "RetroArchLibraryService.launchGameByRomPath",
        ):
            self.assertIn(launch_call, launcher)

    def test_one_policy_is_used_by_game_cloud_transfer_and_ui_boundaries(self):
        policy = read("lib/services/neosync/neo_sync_save_policy.dart")
        self.assertIn("isIosEmulatorExcluded", policy)
        self.assertIn("isIosCloudFileExcluded", policy)
        self.assertIn("if (isIosCloudPathExcluded(cloudPath)) return false;", policy)
        excluded_slugs = section(
            policy,
            "static const iosExcludedEmulatorSlugs = {",
            "};",
        )
        for emulator in ("rpcs3", "armsx2", "melonx", "dolphinios"):
            self.assertIn(emulator, excluded_slugs.lower())

        core = read("lib/providers/neosync/neosync_core.dart")
        upload = read("lib/providers/neosync/neosync_upload.dart")
        download = read("lib/providers/neosync/neosync_download.dart")
        status = read("lib/providers/neosync/neosync_status.dart")
        provider = read("lib/providers/neo_sync_provider.dart")
        adapter = read("lib/sync/providers/neo_sync_adapter.dart")
        interface = read("lib/sync/i_sync_provider.dart")
        status_icon = read("lib/widgets/neo_sync_status_icon.dart")
        manage_tab = read(
            "lib/screens/game_screen/game_settings_dialog/"
            "game_settings_manage_tab.dart"
        )

        # Per-game discovery, status, pre-launch and post-game entry points.
        self.assertGreaterEqual(core.count("_isIosNeoSyncGameExcluded"), 6)
        self.assertIn("_isIosNeoSyncGameExcluded", upload)
        self.assertIn("NeoSyncSavePolicy.isIosEmulatorExcluded", provider)
        # Automatic downloads and explicit restores must both reject old cloud
        # objects for the disabled native adapters before resolving a path.
        self.assertGreaterEqual(download.count("_isIosNeoSyncCloudFileExcluded"), 3)
        self.assertIn("_isIosNeoSyncCloudFileExcluded", status)
        self.assertIn("NeoSyncSavePolicy.isIosCloudFileExcluded", provider)
        self.assertIn("NeoSyncOriginIndex.isDolphinCandidate", provider)
        self.assertIn("preserve: _preserveIosInactiveCloudFile", status)
        # Both compact status and the per-game switch must disappear.
        self.assertIn("syncProvider.supportsGame", status_icon)
        self.assertIn("syncProvider.supportsGame", manage_tab)
        self.assertIn("bool supportsGame(GameModel game, SystemModel system)", interface)
        self.assertIn("_provider.supportsGame(game, system)", adapter)

    def test_global_upload_no_longer_scans_native_adapter_roots(self):
        upload = read("lib/providers/neosync/neosync_upload.dart")
        active_upload = section(
            upload,
            "Future<void> autoSyncUploads() async {",
            "Future<void> _processAutoUploadFile(",
        )
        self.assertIn("_syncAllDolphinGames(download: false)", active_upload)
        for forbidden in (
            "linkedArmsx2FolderPath",
            "linkedMelonxSaveFolderPath",
            "Rpcs3LibraryService.linkedDataPath",
            "emulatorSlug: 'armsx2'",
            "emulatorSlug: 'melonx'",
            "emulatorSlug: 'rpcs3'",
        ):
            self.assertNotIn(forbidden, active_upload)

        download = read("lib/providers/neosync/neosync_download.dart")
        active_download = section(
            download,
            "Future<void> autoSyncDownloads() async {",
            "/// Fase 2: Descargar archivos de la nube",
        )
        self.assertIn("_syncAllDolphinGames(upload: false)", active_download)

    def test_transport_wrapper_keeps_native_routes_blocked_and_never_purges_locally(self):
        wrapper = read("lib/services/neosync/neo_sync_service.dart")
        blocked = section(
            wrapper,
            "static const Set<String> _blockedIosEmulators = <String>{",
            "};",
        )
        for emulator in ("rpcs3", "armsx2", "melonx"):
            self.assertIn(emulator, blocked.lower())
        # DolphiniOS is blocked by NeoSyncSavePolicy before transport dispatch.
        self.assertIn("NeoSyncSavePolicy.isIosCloudPathExcluded", wrapper)
        self.assertIn("NeoSyncSavePolicy.isIosCloudFileExcluded", wrapper)
        self.assertIn("tokens.contains(emulator)", wrapper)
        self.assertGreaterEqual(wrapper.count("_blockedNativeKey(file.path)"), 2)
        for family in ("armsx2", "rpcs3", "melonx"):
            self.assertIn(f"NeoSyncSaveFamily.{family}", wrapper)
        self.assertIn(
            "file.saveKind == NeoSyncSaveKind.foreign",
            wrapper,
        )
        for destructive_legacy_cleanup in (
            "_cleanupLegacyIosArtifacts",
            "clearBookmark",
            "NeoStation', 'Dolphin', 'NeoSync",
            ".neosync-previous-",
            ".neosync-stage-",
        ):
            self.assertNotIn(destructive_legacy_cleanup, wrapper)

        base = read("lib/services/neosync/neo_sync_service_base.dart")
        self.assertIn("bool Function(NeoSyncFile)? preserve", base)
        self.assertIn("preserve: preserve", base)

    def test_dolphin_v1_accepts_only_raw_cards_and_wii_title_data(self):
        store = read("lib/services/dolphin_neosync_store.dart")
        # Native identity still recognizes historical Wii title classes; the
        # narrower V1 eligibility decision belongs to forGame below.
        self.assertIn("0001000[014]", store)

        game_targets = section(
            store,
            "static List<DolphinSaveTarget> forGame(DolphinSaveIdentity game)",
            "static List<DolphinSaveTarget> statesForGame",
        )
        wii_v1 = section(
            store,
            "static bool _supportsWiiV1",
            "static List<DolphinSaveTarget> forGame",
        )
        self.assertIn("MemoryCard", game_targets)
        self.assertNotIn("'gci'", game_targets)
        self.assertIn("'wii-data'", game_targets)
        self.assertIn("_supportsWiiV1", game_targets)
        self.assertIn("00010000", wii_v1)
        self.assertIn("gameIdHex", wii_v1)

        state_targets = section(
            store,
            "static List<DolphinSaveTarget> statesForGame",
            "static DolphinSaveTarget? raw",
        )
        self.assertNotIn("DolphinSaveTarget._", state_targets)

        parser = section(
            store,
            "static DolphinSaveTarget? parse(String cloudPath)",
            "/// Reserved namespace",
        )
        self.assertIn("parsed.isState", parser)
        self.assertNotIn("gci-", parser)
        self.assertIn("wii-data.nsav", parser)

        active_targets = section(
            store,
            "Future<List<DolphinSaveTarget>> targetsForGame",
            "Future<DolphinSaveSnapshot?> snapshot",
        )
        self.assertNotIn("statesForGame", active_targets)

        resolver = read("lib/providers/neosync/neosync_path_resolver.dart")
        generic_dolphin = section(
            resolver,
            "DOLPHIN_ISOLATION_BEGIN: dolphin_save_roots",
            "DOLPHIN_ISOLATION_END: dolphin_save_roots",
        )
        self.assertIn("return [];", generic_dolphin)
        self.assertNotIn("rootDirectory", generic_dolphin)

    def test_ios_native_save_tokens_are_removed_but_emulator_seeds_remain(self):
        system_dir = ROOT / "assets" / "systems"
        raw_systems = {
            file.name: file.read_text(encoding="utf-8")
            for file in system_dir.glob("*.json")
        }
        all_json = "\n".join(raw_systems.values())
        for token in ("{ARMSX2_IOS_SAVES}", "{RPCS3_IOS_SAVEDATA}"):
            self.assertNotIn(token, all_json)

        resolver = read("lib/providers/neosync/neosync_path_resolver.dart")
        for token in ("{ARMSX2_IOS_SAVES}", "{RPCS3_IOS_SAVEDATA}"):
            tombstone = section(
                resolver,
                f"if (pathStr == '{token}' && Platform.isIOS) {{",
                "}",
            )
            self.assertIn("return [];", tombstone)

        ps2 = json.loads(raw_systems["ps2.json"])
        switch = json.loads(raw_systems["switch.json"])

        armsx2 = next(
            emulator
            for emulator in ps2["emulators"]
            if emulator.get("unique_id") == "ps2.ios.armsx2"
        )
        melonx = next(
            emulator
            for emulator in switch["emulators"]
            if emulator.get("unique_id") == "switch.ios.melonx"
        )
        self.assertEqual(armsx2["platforms"]["ios"]["url_scheme"], "armsx2")
        self.assertEqual(melonx["platforms"]["ios"]["url_scheme"], "melonx")

        ps3 = json.loads(raw_systems["ps3.json"])
        self.assertTrue(
            any(emulator.get("unique_id") == "ps3.rpcs3" for emulator in ps3["emulators"])
        )

        # A representative RetroArch system remains opted into NeoSync.
        n64 = json.loads(raw_systems["n64.json"])
        self.assertTrue(n64["neosync"]["sync"])
        self.assertIn("{SYNC_DIR}", n64["neosync"]["android_sync_folder"])


if __name__ == "__main__":
    unittest.main()
