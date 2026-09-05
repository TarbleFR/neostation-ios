"""Executable checks for the per-Pod SDK fix; no device/JIT/cloud is simulated."""
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('device_info_sdk_compat',
    ROOT / 'packages/dolphin_internal_bridge/ci/device_info_sdk_compat.py')
COMPAT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(COMPAT)


class DeviceInfoSDKTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.ios = Path(self.temp.name)
        self.podfile = self.ios / 'Podfile'
        self.original = ('post_install do |installer|\n'
            '  installer.pods_project.targets.each do |target|\n'
            '    flutter_additional_ios_build_settings(target)\n  end\nend\n')
        self.podfile.write_text(self.original)

    def test_generated_hook_is_idempotent_and_preserves_existing_body(self):
        COMPAT.install(self.ios)
        first = self.podfile.read_text()
        COMPAT.install(self.ios)
        self.assertEqual(first, self.podfile.read_text())
        self.assertEqual(first.replace('\n' + COMPAT.HOOK, ''), self.original)
        self.assertIn('API_AVAILABLE(ios(26.1))', COMPAT.HEADER)
        self.assertNotIn('@implementation', COMPAT.HEADER)

    def test_ambiguous_or_altered_podfile_is_not_silently_replaced(self):
        for source in ['# no hook\n', self.original + self.original,
                       self.original + COMPAT.BEGIN]:
            self.podfile.write_text(source)
            with self.assertRaises(ValueError):
                COMPAT.install(self.ios)
            self.assertEqual(self.podfile.read_text(), source)

    @unittest.skipUnless(shutil.which('ruby'), 'Ruby is required')
    def test_only_device_info_target_receives_header_and_flags_are_retained(self):
        COMPAT.install(self.ios)
        ruby = self.ios / 'NeoStationBuildCompatibility/device_info_sdk_compat.rb'
        program = r'''
require 'json'
require ARGV.fetch(0)
Config = Struct.new(:build_settings)
Target = Struct.new(:name, :build_configurations)
Project = Struct.new(:targets)
Installer = Struct.new(:pods_project)
configs = [nil, '-DSTRING_FLAG=1', ['$(inherited)', '-DARRAY_FLAG=1']].map do |value|
  Config.new(value.nil? ? {} : {'OTHER_CFLAGS' => value})
end
other = ['Runner', 'DolphinJITHelper', 'dolphin_internal_bridge', 'stikjit_bridge', 'gamepads_ios'].map do |name|
  Target.new(name, [Config.new({'OTHER_CFLAGS' => ['$(inherited)', '-DPRESERVED=1']})])
end
before = Marshal.dump(other)
installer = Installer.new(Project.new([Target.new('device_info_plus', configs)] + other))
NeoStationDeviceInfoSDKCompatibility.apply(installer)
once = Marshal.dump(installer)
NeoStationDeviceInfoSDKCompatibility.apply(installer)
raise 'not idempotent' unless once == Marshal.dump(installer)
raise 'another target changed' unless before == Marshal.dump(other)
puts JSON.generate(configs.map(&:build_settings))
'''
        result = subprocess.run(['ruby', '-e', program, str(ruby)], text=True,
                                capture_output=True, check=True)
        settings = json.loads(result.stdout)
        for entry in settings:
            flags = entry['OTHER_CFLAGS']
            self.assertEqual(flags.count('-include'), 1)
            self.assertIn('NSProcessInfoVisionCompatibility.h', flags[-1])
        self.assertEqual(settings[0]['OTHER_CFLAGS'][0], '$(inherited)')
        self.assertEqual(settings[1]['OTHER_CFLAGS'][0], '-DSTRING_FLAG=1')
        self.assertEqual(settings[2]['OTHER_CFLAGS'][:2], ['$(inherited)', '-DARRAY_FLAG=1'])

    @unittest.skipUnless(shutil.which('clang'), 'Clang is required')
    def test_generated_c_and_cpp_sources_do_not_import_objective_c(self):
        header = self.ios / 'compat.h'
        header.write_text(COMPAT.HEADER)
        # The Pod's generated *_vers.c shares OTHER_CFLAGS with its .m files.
        # No Foundation stub is installed: importing it in C/C++ must fail.
        source = self.ios / 'version.c'
        source.write_text('double device_info_plusVersionNumber = 1.0;\n')
        for language in ['c', 'c++']:
            result = subprocess.run(
                ['clang', '-fsyntax-only', '-x', language,
                 '-target', 'arm64-apple-ios17.4',
                 '-D__IPHONE_OS_VERSION_MAX_ALLOWED=180500',
                 '-include', str(header), str(source)],
                text=True, capture_output=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)

    @unittest.skipUnless(shutil.which('clang'), 'Clang is required')
    def test_old_sdk_declaration_compiles_without_changing_new_sdk(self):
        foundation = self.ios / 'Foundation'
        foundation.mkdir()
        (self.ios / 'Availability.h').write_text('#define API_AVAILABLE(...)\n')
        stub = ('#pragma once\ntypedef signed char BOOL;\n'
                '__attribute__((objc_root_class)) @interface NSObject @end\n'
                '@interface NSProcessInfo : NSObject\n'
                '#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 260100\n'
                '- (BOOL)isiOSAppOnVision;\n#endif\n@end\n')
        (foundation / 'Foundation.h').write_text(stub)
        header = self.ios / 'compat.h'; header.write_text(COMPAT.HEADER)
        source = self.ios / 'caller.m'
        source.write_text('#import <Foundation/Foundation.h>\n'
                         'BOOL inspect(NSProcessInfo *info) {\n'
                         '  if (@available(iOS 26.1, *)) return [info isiOSAppOnVision];\n'
                         '  return 0;\n}\n')
        def compile_with(sdk, include):
            args = ['clang', '-fsyntax-only', '-x', 'objective-c',
                    '-target', 'arm64-apple-ios17.4', '-fobjc-arc',
                    '-Werror=objc-method-access', '-I', str(self.ios),
                    f'-D__IPHONE_OS_VERSION_MAX_ALLOWED={sdk}']
            if include: args += ['-include', str(header)]
            return subprocess.run(args + [str(source)], text=True, capture_output=True)
        broken = compile_with(180500, False)
        self.assertNotEqual(broken.returncode, 0)
        self.assertIn('isiOSAppOnVision', broken.stderr)
        for sdk in [180500, 260100]:
            fixed = compile_with(sdk, True)
            self.assertEqual(fixed.returncode, 0, fixed.stderr)


if __name__ == '__main__':
    unittest.main()
