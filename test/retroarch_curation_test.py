#!/usr/bin/env python3
"""Exercise allowlist policy and, when supplied, the pinned donor IPA itself."""
import argparse
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'build-utils/retroarch'))
spec = importlib.util.spec_from_file_location('curate_manifest', ROOT / 'build-utils/retroarch/curate_manifest.py')
curate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(curate)
PACKAGE_REPORT = None


class CurationPolicyTests(unittest.TestCase):
    def test_allowlist_comments_and_exact_names(self):
        parsed = curate.appstore_ids('appstore_cores=(\n snes9x\n #bsnes_hd_beta\n bsnes-jg # inline note\n)\n')
        self.assertEqual(parsed, {'snes9x', 'bsnes-jg'})
        self.assertNotIn('snes9x2005_plus', parsed)
        with self.assertRaises(ValueError):
            curate.appstore_ids('other_cores=(\nsnes9x\n)\n')

    def test_beta_experimental_missing_framework_and_explicit_policy(self):
        base = {'hw_render': 'false', 'corename': 'Snes9x'}
        self.assertEqual(curate.classify('snes9x', base, True, True, ['snes'])[0], 'software-candidate')
        for core, info, binary, metadata, systems, reason in [
            ('bsnes_hd_beta', base, True, True, ['snes'], 'experimental-or-named-beta-test'),
            ('b2', {**base, 'is_experimental': 'true'}, True, True, ['bbcmicro'], 'experimental-or-named-beta-test'),
            ('snes9x2005', base, False, True, ['snes'], 'missing-binary'),
            ('snes9x', base, True, False, ['snes'], 'missing-info'),
            ('dolphin', base, True, True, ['gc'], 'excluded-platform-policy'),
        ]:
            status, reasons = curate.classify(core, info, binary, metadata, systems)
            self.assertEqual(status, 'excluded')
            self.assertIn(reason, reasons)

    def test_hardware_requirements_are_not_assumed_from_appstore(self):
        for api in ['OpenGL Core >= 3.3', 'Vulkan >= 1.0', 'OpenGL Core >= 4.3']:
            status, _ = curate.classify('hw_core', {'hw_render': 'true', 'required_hw_api': api}, True, True, ['ps1'])
            self.assertEqual(status, 'gpu-incompatible')
        status, _ = curate.classify('gles_core', {'hw_render': 'true', 'required_hw_api': 'OpenGL ES >= 2.0'}, True, True, ['n64'])
        self.assertEqual(status, 'hardware-candidate')
        status, _ = curate.classify('unknown_hw', {'hw_render': 'true'}, True, True, ['ds'])
        self.assertEqual(status, 'hardware-unqualified')

    def test_unquoted_firmware_counts_and_required_bios_are_preserved(self):
        info = curate.parse_info(b'firmware_count = 2\nfirmware0_path = "scph5500.bin"\nfirmware0_opt = "false"\nfirmware1_path = "bios_CD_U.bin"\nfirmware1_opt = "true"\n')
        self.assertEqual(info['firmware_count'], '2')
        firmware = curate.firmware_entries(info)
        self.assertEqual(firmware[0], {'path': 'scph5500.bin', 'description': 'scph5500.bin', 'optional': False})
        self.assertTrue(firmware[1]['optional'])
        with self.assertRaises(ValueError):
            curate.firmware_entries({'firmware_count': '1', 'firmware0_path': '../bios.bin'})

    def test_nested_emulator_identifiers_and_exact_metadata_mapping(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            sample = {
                'system': {'id': '5200', 'name': 'Atari 5200', 'folders': ['5200', 'a5200'], 'extensions': ['a52', 'bin']},
                'emulators': [{'unique_id': '5200.atari5200.ra.a5200', 'platforms': {'windows': {'args': '-L a5200_libretro.dll "{file.path}"'}}, 'default_core': True}],
            }
            (folder / '5200.json').write_text(json.dumps(sample))
            records, declared, _, _ = curate.system_index(folder)
            self.assertEqual(curate.map_systems('a5200', {}, records, declared)[0], ['5200'])
            mapped, evidence = curate.map_systems('new_core', {'database': 'Atari - 5200', 'supported_extensions': 'a52'}, records, declared)
            self.assertEqual(mapped, ['5200'])
            self.assertEqual(evidence[0]['source'], 'exact-upstream-database')
            self.assertEqual(evidence[0]['matchingExtensions'], ['a52'])
            self.assertEqual(curate.map_systems('new_core', {'database': 'Atari - 5200', 'supported_extensions': 'zip'}, records, declared)[0], [])

    def test_distinct_vice_machine_modes_do_not_alias_to_c64(self):
        records = {'c64': {'asset': 'assets/systems/c64.json', 'extensions': ['d64', 'prg']}}
        info = {'database': 'Commodore - 64', 'supported_extensions': 'd64|prg'}
        for core in ['vice_x128', 'vice_xscpu64']:
            self.assertEqual(curate.map_systems(core, info, records, {})[0], [])


@unittest.skipIf(PACKAGE_REPORT is None, 'Supply --ipa and --upstream to validate the physical donor package')
class PhysicalPinnedPackageTests(unittest.TestCase):
    def test_candidate_pins_are_exact_nonexperimental_present_allowlist_subset(self):
        allowed = set(PACKAGE_REPORT['allowlist']['coreIds'])
        candidates = {core['id']: core for core in PACKAGE_REPORT['candidates']}
        for pin in PACKAGE_REPORT['softwareCandidatePins']:
            self.assertIn(pin['id'], allowed)
            evidence = candidates[pin['id']]
            self.assertFalse(evidence['missingBinary'])
            self.assertEqual(evidence['status'], 'software-candidate')
            self.assertEqual(evidence['macho']['architectures'], ['arm64'])
            self.assertEqual(evidence['macho']['platform'], 'iOS')
            self.assertNotEqual(evidence['isExperimentalDeclared'], 'true')
            self.assertEqual(len(pin['sha256']), 64)
            self.assertEqual(len(pin['infoSha256']), 64)
            self.assertTrue(pin['systemIds'])
            self.assertFalse(set(pin['systemIds']) & curate.EXCLUDED_SYSTEMS)

    def test_requested_variants_and_absent_binaries_are_distinguished(self):
        candidates = {core['id']: core for core in PACKAGE_REPORT['candidates']}
        pins = {core['id']: core for core in PACKAGE_REPORT['softwareCandidatePins']}
        for core in ['bsnes', 'bsnes-jg', 'snes9x', 'snes9x2010']:
            self.assertIn('snes', pins[core]['systemIds'])
        for core in ['genesis_plus_gx', 'genesis_plus_gx_wide', 'picodrive', 'clownmdemu']:
            self.assertTrue({'md', 'genesis'} <= set(pins[core]['systemIds']))
        self.assertTrue(candidates['snes9x2005']['missingBinary'])
        self.assertTrue(candidates['ppsspp']['missingBinary'])
        self.assertTrue({'psp', 'pspminis'} <= set(candidates['ppsspp']['systemIds']))
        self.assertNotIn('snes9x2005_plus', pins)
        self.assertNotIn('bsnes_hd_beta', pins)
        self.assertNotIn('dolphin', pins)
        self.assertNotIn('vice_x128', pins)
        self.assertNotIn('vice_xscpu64', pins)
        self.assertIn('experimental-or-named-beta-test', candidates['b2']['reasons'])
        self.assertIn('missing-binary', candidates['snes9x2005']['reasons'])
        self.assertEqual(candidates['azahar']['status'], 'gpu-incompatible')

    def test_all_mappings_use_existing_declared_asset_ids(self):
        records, _, _, _ = curate.system_index(ROOT / 'assets/systems')
        for core in PACKAGE_REPORT['candidates']:
            self.assertTrue(set(core['systemIds']) <= set(records))
            evidence = {entry['systemId'] for entry in core['mappingEvidence']}
            self.assertTrue(set(core['systemIds']) <= evidence)

    def test_hardware_n64_donor_identity_and_linkage_are_exact(self):
        core = next(entry for entry in PACKAGE_REPORT['candidates']
                    if entry['id'] == 'mupen64plus_next')
        self.assertFalse(core['missingBinary'])
        self.assertEqual(core['sha256'],
                         '9e218101d03556d2c7decd182706174a3fc738ab7fba946bc9bd36e6eee38237')
        self.assertEqual(core['infoSha256'],
                         '8d1fcd13a17310e233be4ff247bf1032f8f786fe685e24cef5ed4ea474ccdfb6')
        self.assertEqual(core['macho']['architectures'], ['arm64'])
        self.assertEqual(core['macho']['platform'], 'iOS')
        self.assertEqual(core['systemIds'], ['n64'])
        self.assertEqual(set(core['supportedExtensions']),
                         {'n64', 'v64', 'z64', 'ndd', 'bin', 'u1'})
        self.assertTrue(all(dependency.startswith(('/usr/lib/', '/System/Library/Frameworks/'))
                            for dependency in core['macho']['dependencies']))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument('--ipa', type=Path)
    parser.add_argument('--upstream', type=Path)
    parser.add_argument('--require-package', action='store_true')
    options, remaining = parser.parse_known_args()
    if bool(options.ipa) != bool(options.upstream) or (options.require_package and not options.ipa):
        parser.error('--ipa and --upstream must both be supplied for required physical package checks')
    if options.ipa:
        PACKAGE_REPORT = curate.audit(options.ipa.resolve(), options.upstream.resolve(), ROOT / 'assets/systems')
        PhysicalPinnedPackageTests.__unittest_skip__ = False
    unittest.main(argv=[sys.argv[0], *remaining])
