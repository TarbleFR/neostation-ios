"""Exercise the real installer/validator with controlled Mach-O artifacts."""
import copy
import hashlib
import io
import json
from pathlib import Path
import plistlib
import struct
import sys
import tarfile
import tempfile
import unittest
import zipfile

TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS))
import embed_package as embed
import configure_host as configure

FRONTEND_HOST = '1' * 40
HOST = '2' * 40


def dylib(symbols=('_NeoRetroArch_GetAPI',), imports=(), kind=6,
          install_name='@rpath/libRetroArchCore.dylib', dependency=None):
    name = install_name.encode() + b'\0'
    size = (24 + len(name) + 7) & ~7
    identity = struct.pack('<6I', 0xd, size, 24, 0, 0, 0) + name + b'\0' * (size - 24 - len(name))
    version = struct.pack('<6I', 0x32, 24, 2, 18 << 16, 18 << 16, 0)
    extra = b''
    if dependency:
        dependency_name = dependency.encode() + b'\0'
        dependency_size = (24 + len(dependency_name) + 7) & ~7
        extra = (struct.pack('<6I', 0xc, dependency_size, 24, 0, 0, 0) + dependency_name
                 + b'\0' * (dependency_size - 24 - len(dependency_name)))
    strings = b'\0'
    rows = []
    for symbol, defined in [(s, True) for s in symbols] + [(s, False) for s in imports]:
        offset = len(strings)
        strings += symbol.encode() + b'\0'
        rows.append(struct.pack('<IBBHQ', offset, 0xf if defined else 1, 1 if defined else 0, 0, 0))
    table_offset = 32 + len(identity) + len(version) + len(extra) + 24
    symtab = struct.pack('<6I', 2, 24, table_offset, len(rows), table_offset + 16 * len(rows), len(strings))
    commands = identity + version + extra + symtab
    header = struct.pack('<8I', 0xfeedfacf, 0x0100000c, 0, kind, 3 + bool(extra), len(commands), 0, 0)
    return header + commands + b''.join(rows) + strings


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + '\n')


class Fixture:
    def __init__(self, root):
        self.package = root / 'package'
        self.app = root / 'Runner.app'
        self.frontend = dylib()
        self.core = dylib(symbols=('_retro_run',), install_name='@rpath/fceumm.libretro.framework/fceumm.libretro')
        self.info = b'display_name = "FCEUmm"\nis_experimental = "false"\n'
        self.pins = {
            'schemaVersion': 1,
            'sourceIpa': {'sha256': 'a' * 64, 'bytes': 1, 'url': 'https://example.test/RetroArch.ipa', 'bundleVersion': '1'},
            'frontend': {'commit': 'b' * 40, 'abiVersion': 1, 'runtimeIdentity': 'neostation-retroarch-curated-v1'},
            'cores': [{'id': 'fceumm', 'binary': 'Frameworks/fceumm.libretro.framework/fceumm.libretro',
                       'systemIds': ['nes'], 'sha256': embed.sha256(self.core), 'info': 'info/fceumm_libretro.info',
                       'infoSha256': embed.sha256(self.info), 'title': 'Nintendo - FCEUmm',
                       'supportedExtensions': ['nes'], 'license': 'GPLv2', 'savestate': True, 'cheats': True}],
        }
        self.put('Frameworks/libRetroArchCore.dylib', self.frontend)
        self.put(self.pins['cores'][0]['binary'], self.core)
        self.put('Frameworks/fceumm.libretro.framework/Info.plist', plistlib.dumps({'CFBundleExecutable': 'fceumm.libretro'}))
        self.put('Frameworks/fceumm.libretro.framework/_CodeSignature/CodeResources', b'original donor signature resource')
        self.put('Resources/RetroArchResources/info/fceumm_libretro.info', self.info)
        self.put('Resources/RetroArchResources/overlays/pad.cfg', b'user-editable default preset')
        self.put('Resources/RetroArchResources/assets/font.ttf', b'pinned asset fixture')
        self.write_source()
        self.sync_metadata()
        self.app.mkdir()
        self.app_info = {'CFBundleIdentifier': 'com.neogamelab.neostation', 'CFBundleExecutable': 'Runner',
                         'UIFileSharingEnabled': True, 'LSSupportsOpeningDocumentsInPlace': True,
                         'MinimumOSVersion': '18.0'}
        (self.app / 'Info.plist').write_bytes(plistlib.dumps(self.app_info))
        (self.app / 'Runner').write_bytes(b'unchanged existing Flutter host')
        native = self.app / 'Frameworks' / 'DolphinCore.framework' / 'DolphinCore'
        native.parent.mkdir(parents=True)
        native.write_bytes(b'unchanged existing Dolphin core')

    def put(self, relative, data):
        path = self.package / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def write_source(self):
        metadata = {'frontendCommit': self.pins['frontend']['commit'],
                    'sourceIpaSha256': self.pins['sourceIpa']['sha256'], 'adapterAbiVersion': 1,
                    'standaloneApplicationEntry': False}
        path = self.package / 'retroarch-frontend-corresponding-source.tar.gz'
        with tarfile.open(path, 'w:gz') as archive:
            data = json.dumps(metadata).encode()
            entry = tarfile.TarInfo('source/neostation/prepared-source.json')
            entry.size = len(data)
            archive.addfile(entry, io.BytesIO(data))

    def sync_metadata(self):
        write_json(self.package / 'source-pins.json', self.pins)
        write_json(self.package / 'Resources/retroarch-core-manifest.json', {
            'sourceIpa': self.pins['sourceIpa'], 'frontend': self.pins['frontend'], 'cores': copy.deepcopy(self.pins['cores'])})
        write_json(self.package / 'frontend-validation.json', {
            'success': True, 'sourceBuild': True, 'standaloneEntry': False, 'hostCommit': FRONTEND_HOST,
            'frontendCommit': self.pins['frontend']['commit'], 'sourceIpaSha256': self.pins['sourceIpa']['sha256'],
            'frontendSha256': embed.sha256(self.frontend), 'frontendMacho': embed.macho(self.frontend),
            'abiVersion': 1, 'runtimeIdentity': self.pins['frontend']['runtimeIdentity']})

    def add_psp(self):
        core = copy.deepcopy(self.pins['cores'][0])
        asset = b'official support font; not a BIOS'
        source = b'pinned PSP upstream corresponding source archive'
        index = {'font.zim': embed.sha256(asset)}
        core.update({'id': 'ppsspp', 'binary': 'Frameworks/ppsspp.libretro.framework/ppsspp.libretro',
                     'systemIds': ['psp', 'pspminis'], 'info': 'info/ppsspp_libretro.info', 'cheats': False,
                     'forcedOptions': {'ppsspp_cpu_core': 'Interpreter', 'ppsspp_backend': 'opengl'},
                     'supplementaryInput': {'coreArchiveSha256': 'c' * 64, 'assetsSourceSha256': embed.sha256(source),
                                           'assetsIndexSha256': embed.sha256(json.dumps(index, sort_keys=True, separators=(',', ':')).encode())}})
        self.pins['cores'].append(core)
        self.put(core['binary'], self.core)
        self.put('Resources/RetroArchResources/' + core['info'], self.info)
        self.put('Resources/RetroArchResources/system/PPSSPP/font.zim', asset)
        self.put('ppsspp-corresponding-source.tar.gz', source)
        write_json(self.package / 'ppsspp-assets-index.json', index)
        write_json(self.package / 'ppsspp-package-audit.json', {
            'success': True, 'binarySha256': core['sha256'], 'coreArchiveSha256': 'c' * 64,
            'sourceArchiveSha256': embed.sha256(source), 'infoSha256': core['infoSha256'],
            'runtimeRequiredOptions': core['forcedOptions']})
        self.sync_metadata()

    def install(self):
        return embed.embed(self.package, self.app, FRONTEND_HOST, HOST, self.pins)

    def ipa(self, path, extra=None):
        with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as archive:
            for file in self.app.rglob('*'):
                if file.is_file():
                    archive.write(file, 'Payload/NeoStation.app/' + file.relative_to(self.app).as_posix())
            if extra:
                archive.writestr(*extra)
        return path


class EmbeddedPackageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.fixture = Fixture(self.root)

    def tearDown(self):
        self.temp.cleanup()

    def test_install_preserves_existing_engines_and_original_core_bytes(self):
        unrelated = self.fixture.app / 'Frameworks/DolphinCore.framework/DolphinCore'
        original = unrelated.read_bytes()
        result = self.fixture.install()
        self.assertEqual(unrelated.read_bytes(), original)
        self.assertEqual((self.fixture.app / self.fixture.pins['cores'][0]['binary']).read_bytes(), self.fixture.core)
        self.assertEqual(result['frontendHostCommit'], FRONTEND_HOST)
        self.assertEqual(result['hostCommit'], HOST)
        self.assertFalse(result['deviceValidated'])
        self.assertFalse((self.fixture.app / 'retroarch-frontend-corresponding-source.tar.gz').exists())

    def test_install_is_idempotent(self):
        first = self.fixture.install()
        before = {p: p.read_bytes() for p in self.fixture.app.rglob('*') if p.is_file()}
        self.assertEqual(self.fixture.install(), first)
        self.assertEqual({p: p.read_bytes() for p in self.fixture.app.rglob('*') if p.is_file()}, before)

    def test_tampered_core_is_rejected_before_copying(self):
        self.fixture.put(self.fixture.pins['cores'][0]['binary'], self.fixture.core + b'wrong core')
        with self.assertRaisesRegex(ValueError, 'Core binary identity'):
            self.fixture.install()
        self.assertFalse((self.fixture.app / embed.FRONTEND_NAME).exists())

    def test_uncurated_package_framework_is_rejected(self):
        self.fixture.put('Frameworks/dolphin.libretro.framework/dolphin.libretro', self.fixture.core)
        with self.assertRaisesRegex(ValueError, 'uncurated core frameworks'):
            self.fixture.install()

    def test_uncurated_existing_app_core_is_rejected_without_removal(self):
        bad = self.fixture.app / 'Frameworks/citra.libretro.framework/citra.libretro'
        bad.parent.mkdir(parents=True)
        bad.write_bytes(self.fixture.core)
        with self.assertRaisesRegex(ValueError, 'Uncurated libretro'):
            self.fixture.install()
        self.assertTrue(bad.exists())
        self.assertFalse((self.fixture.app / embed.FRONTEND_NAME).exists())

    def test_conflicting_existing_runtime_is_not_overwritten(self):
        runtime = self.fixture.app / embed.FRONTEND_NAME
        runtime.write_bytes(b'existing different frontend')
        with self.assertRaisesRegex(ValueError, 'Conflicting app-owned'):
            self.fixture.install()
        self.assertEqual(runtime.read_bytes(), b'existing different frontend')

    def test_frontend_exports_must_match_real_host_boundary(self):
        self.fixture.frontend = dylib(symbols=('_rarch_main',))
        self.fixture.put(embed.FRONTEND_NAME, self.fixture.frontend)
        self.fixture.sync_metadata()
        with self.assertRaisesRegex(ValueError, 'public exports'):
            self.fixture.install()

    def test_frontend_must_not_import_second_application_entry(self):
        self.fixture.frontend = dylib(imports=('_UIApplicationMain',))
        self.fixture.put(embed.FRONTEND_NAME, self.fixture.frontend)
        self.fixture.sync_metadata()
        with self.assertRaisesRegex(ValueError, 'second UIApplication'):
            self.fixture.install()

    def test_missing_dynamic_dependency_is_rejected_before_copying(self):
        self.fixture.frontend = dylib(dependency='@rpath/MissingRuntime.framework/MissingRuntime')
        self.fixture.put(embed.FRONTEND_NAME, self.fixture.frontend)
        self.fixture.sync_metadata()
        with self.assertRaisesRegex(ValueError, 'dependency missing'):
            self.fixture.install()
        self.assertFalse((self.fixture.app / embed.FRONTEND_NAME).exists())

    def test_frontend_executable_is_rejected(self):
        self.fixture.put(embed.FRONTEND_NAME, dylib(kind=2))
        with self.assertRaisesRegex(ValueError, 'MH_DYLIB'):
            self.fixture.install()

    def test_mixed_frontend_build_commit_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'different host commit'):
            embed.embed(self.fixture.package, self.fixture.app, '3' * 40, HOST, self.fixture.pins)

    def test_documents_must_remain_accessible(self):
        self.fixture.app_info['UIFileSharingEnabled'] = False
        (self.fixture.app / 'Info.plist').write_bytes(plistlib.dumps(self.fixture.app_info))
        with self.assertRaisesRegex(ValueError, 'sharing is disabled'):
            self.fixture.install()

    def test_source_package_must_not_ship_user_bios(self):
        self.fixture.put('Resources/RetroArchResources/system/scph5501.bin', b'not a distributable input')
        with self.assertRaisesRegex(ValueError, 'must not ship user BIOS'):
            self.fixture.install()

    def test_supplementary_psp_assets_require_pinned_index_and_profile(self):
        self.fixture.add_psp()
        self.fixture.install()
        asset = self.fixture.app / 'RetroArchResources/system/PPSSPP/font.zim'
        self.assertTrue(asset.is_file())
        self.fixture.put('Resources/RetroArchResources/system/PPSSPP/font.zim', b'tampered support asset')
        with self.assertRaisesRegex(ValueError, 'support asset changed'):
            embed.validate_package(self.fixture.package, FRONTEND_HOST, self.fixture.pins)

    def test_symlink_resource_is_rejected(self):
        target = self.root / 'external'
        target.write_bytes(b'outside package')
        (self.fixture.package / 'Resources/RetroArchResources/assets/link').symlink_to(target)
        with self.assertRaisesRegex(ValueError, 'Symlink in package'):
            self.fixture.install()

    def test_final_ipa_proves_core_frontend_resource_and_source_identity(self):
        self.fixture.install()
        ipa = self.fixture.ipa(self.root / 'NeoStation.ipa')
        result = embed.validate_ipa(ipa, self.fixture.package, FRONTEND_HOST, HOST, self.fixture.pins)
        self.assertTrue(result['structuralValidation'])
        self.assertFalse(result['deviceValidated'])
        self.assertEqual(result['ipaSha256'], embed.file_hash(ipa))

    def test_final_ipa_rejects_extra_core(self):
        self.fixture.install()
        ipa = self.fixture.ipa(self.root / 'bad.ipa',
            ('Payload/NeoStation.app/Frameworks/azahar.libretro.framework/azahar.libretro', self.fixture.core))
        with self.assertRaisesRegex(ValueError, 'Uncurated/nested libretro'):
            embed.validate_ipa(ipa, self.fixture.package, FRONTEND_HOST, HOST, self.fixture.pins)

    def test_final_ipa_rejects_edited_core(self):
        self.fixture.install()
        (self.fixture.app / self.fixture.pins['cores'][0]['binary']).write_bytes(b'changed after embedding')
        ipa = self.fixture.ipa(self.root / 'bad.ipa')
        with self.assertRaisesRegex(ValueError, 'embedded file identity mismatch'):
            embed.validate_ipa(ipa, self.fixture.package, FRONTEND_HOST, HOST, self.fixture.pins)


class GeneratedHostMetadataTests(unittest.TestCase):
    def test_configure_metadata_is_idempotent_and_preserves_unrelated_settings(self):
        with tempfile.TemporaryDirectory() as directory:
            ios = Path(directory)
            (ios / 'Runner').mkdir()
            (ios / 'Runner.xcodeproj').mkdir()
            path = ios / 'Runner/Info.plist'
            previous = {'CFBundleIdentifier': 'com.neogamelab.neostation', 'MinimumOSVersion': '17.4',
                        'NSLocalNetworkUsageDescription': 'existing description', 'UIBackgroundModes': ['audio']}
            path.write_bytes(plistlib.dumps(previous))
            podfile = ios / 'Podfile'
            podfile.write_text("# platform :ios, '17.4'\ntarget 'Runner' do\n  use_frameworks!\nend\n")
            entitlements = ios / 'Runner/Runner.entitlements'
            entitlements.write_bytes(b'existing emulator entitlement bytes')
            configure.configure(ios, edit_project=False)
            first = path.read_bytes(), podfile.read_bytes()
            configure.configure(ios, edit_project=False)
            self.assertEqual((path.read_bytes(), podfile.read_bytes()), first)
            data = plistlib.loads(path.read_bytes())
            self.assertTrue(data['UIFileSharingEnabled'])
            self.assertTrue(data['LSSupportsOpeningDocumentsInPlace'])
            self.assertEqual(data['MinimumOSVersion'], '18.0')
            self.assertEqual(data['UIBackgroundModes'], ['audio'])
            self.assertEqual(data['NSLocalNetworkUsageDescription'], 'existing description')
            self.assertEqual(entitlements.read_bytes(), b'existing emulator entitlement bytes')
            self.assertIn("platform :ios, '18.0'", podfile.read_text())

    def test_newer_deployment_target_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            podfile = Path(directory) / 'Podfile'
            podfile.write_text("platform :ios, '19.0'\n")
            configure.configure_podfile(podfile)
            self.assertIn("'19.0'", podfile.read_text())


if __name__ == '__main__':
    unittest.main()
