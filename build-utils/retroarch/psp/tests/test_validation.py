import importlib.util
import json
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest
import zipfile

MODULE_PATH = Path(__file__).resolve().parents[1] / 'package.py'
spec = importlib.util.spec_from_file_location('ppsspp_package', MODULE_PATH)
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class PSPBinaryValidationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.archive = package.REPOSITORY / package.PINS['coreArchive']['repositoryPath']
        cls.binary, cls.audit = package.read_core(cls.archive)
        cls.image = cls.binary
        if struct.unpack_from('>I', cls.image)[0] == 0xcafebabe:
            _, _, offset, length, _ = struct.unpack_from('>5I', cls.image, 8)
            cls.image = cls.image[offset:offset + length]

    def test_official_pinned_binary_has_real_device_abi_and_known_source(self):
        self.assertEqual(self.audit['architectures'], ['arm64'])
        self.assertEqual(self.audit['platform'], 'iOS')
        self.assertEqual(self.audit['embeddedGitVersion'], '91a3405')
        self.assertEqual(self.audit['sourceCommit'], '91a34056d036b22ee9ec1a656875fc780eff5efb')
        self.assertTrue(package.LIBRETRO_EXPORTS <= set(self.audit['libretroExports']))
        self.assertEqual(set(self.audit['dependencies']), package.ALLOWED_DEPENDENCIES)

    def test_wrong_cpu_is_rejected(self):
        image = bytearray(self.image)
        struct.pack_into('<I', image, 4, 0x01000007)
        with self.assertRaisesRegex(ValueError, 'arm64 MH_DYLIB'):
            package.audit_macho(bytes(image))

    def test_simulator_platform_is_rejected(self):
        image = bytearray(self.image)
        cursor = 32
        for _ in range(struct.unpack_from('<I', image, 16)[0]):
            command, size = struct.unpack_from('<II', image, cursor)
            if command == 0x32:
                struct.pack_into('<I', image, cursor + 8, 7)
                break
            if command == 0x25:
                # LC_VERSION_MIN_MACOSX instead of LC_VERSION_MIN_IPHONEOS.
                struct.pack_into('<I', image, cursor, 0x24)
                break
            cursor += size
        else:
            self.fail('Real audited binary had no iOS platform declaration')
        with self.assertRaisesRegex(ValueError, 'iOS device'):
            package.audit_macho(bytes(image))

    def test_missing_defined_run_export_is_rejected(self):
        image = self.image.replace(b'_retro_run\0', b'_other_run\0')
        self.assertNotEqual(image, self.image)
        with self.assertRaisesRegex(ValueError, 'Missing defined PSP ABI exports'):
            package.audit_macho(image)

    def test_unknown_dependency_is_rejected(self):
        image = self.image.replace(b'OpenGLES.framework/OpenGLES\0', b'OtherGPU.framework/OtherGPU\0')
        self.assertNotEqual(image, self.image)
        with self.assertRaisesRegex(ValueError, 'Unexpected PSP dependencies'):
            package.audit_macho(image)

    def test_source_revision_mismatch_is_rejected(self):
        image = self.image.replace(b'91a3405\0', b'91a3406\0')
        self.assertNotEqual(image, self.image)
        with self.assertRaisesRegex(ValueError, 'source version mismatch'):
            package.audit_macho(image)

    def test_modified_archive_is_rejected_before_loading(self):
        with tempfile.TemporaryDirectory() as directory:
            copied = Path(directory) / 'core.zip'
            data = bytearray(self.archive.read_bytes())
            data[-1] ^= 1
            copied.write_bytes(data)
            with self.assertRaisesRegex(ValueError, 'SHA-256 mismatch'):
                package.read_core(copied)

    def test_hosted_psp_profile_compiles_and_protects_interpreter_and_gles(self):
        compiler = shutil.which('clang++') or shutil.which('c++')
        if compiler is None:
            self.fail('A C++ compiler is required to verify the PSP option boundary')
        source = package.REPOSITORY / 'native/retroarch/psp/profile_test.cpp'
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / 'profile-test'
            subprocess.run([compiler, '-std=c++17', '-Wall', '-Wextra', '-Werror',
                            str(source), '-o', str(executable)], check=True)
            subprocess.run([str(executable)], check=True)


if __name__ == '__main__':
    unittest.main()
