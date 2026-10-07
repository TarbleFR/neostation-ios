"""Test compile-command preservation and dependency ordering, not device JIT."""
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
import subprocess
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('syntax_gate', ROOT / 'build-utils/rpcs3_core_syntax_gate.py')
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

class SyntaxGateTests(unittest.TestCase):
    def test_real_maps_are_generated_and_preserved_in_compiler_command(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            entries = []
            exception_flags = {}
            for name in sorted(gate.UNITS):
                exception_flags[name] = (['-fno-exceptions', '-fexceptions'] if name == 'SourceClient.cpp'
                    else ['-fno-exceptions'] if name in ('fsr_pass.cpp', 'VKProgramPipeline.cpp', 'cellVdec.cpp')
                    else ['-fexceptions'])
                entries.append({'file': name, 'directory': temp, 'arguments': [
                    'clang++', '--target=arm64-apple-ios16.3', '-std=c++23',
                    *exception_flags[name], '-DREQUIRED=1', '-c', name, '-o', name+'.o',
                    '-MD', '-MF', name+'.d', '@'+name+'.o.modmap']})
            database = root / 'compile_commands.json'
            database.write_text(json.dumps(entries))
            calls = []
            def run(args, **kwargs):
                calls.append(args)
                if args[0] == 'cmake':
                    for name in gate.UNITS:
                        (root / (name+'.o.modmap')).write_text('-DGENERATED_MODULE_MAP=1')
                else:
                    response = next(arg[1:] for arg in args if arg.startswith('@'))
                    self.assertEqual((root/response).read_text(), '-DGENERATED_MODULE_MAP=1')
                    self.assertIn('--target=arm64-apple-ios16.3', args)
                    self.assertIn('-DREQUIRED=1', args)
                    unit = next(name for name in gate.UNITS if name in args)
                    self.assertEqual([arg for arg in args if arg in ('-fno-exceptions', '-fexceptions')],
                                     exception_flags[unit])
                    self.assertIn('-fsyntax-only', args)
                    self.assertNotIn('-o', args)
                    self.assertNotIn('-c', args)
                return subprocess.CompletedProcess(args, 0)
            with patch.object(gate.subprocess, 'run', side_effect=run):
                gate.main(database)
            self.assertEqual(calls[0][0], 'cmake')
            self.assertEqual(len(calls), len(gate.UNITS) + 1)

    def test_modified_spu_performance_and_cold_consumers_are_required_early(self):
        self.assertTrue({'SPUCommonRecompiler.cpp', 'SPULLVMRecompiler.cpp',
                         'RPCS3IOSPerformance.cpp', 'VKProgramPipeline.cpp',
                         'fsr_pass.cpp', 'SourceClient.cpp', 'cellVdec.cpp'} <= gate.UNITS)

    def test_missing_translation_units_are_an_error(self):
        with tempfile.TemporaryDirectory() as temp:
            database = Path(temp)/'compile_commands.json'
            database.write_text('[]')
            with self.assertRaisesRegex(RuntimeError, 'Missing startup units'):
                gate.main(database)

    def test_reports_every_failing_translation_unit(self):
        with tempfile.TemporaryDirectory() as temp:
            database = Path(temp) / 'compile_commands.json'
            database.write_text(json.dumps([
                {'file': name, 'directory': temp, 'arguments': ['clang++', '-c', name]}
                for name in sorted(gate.UNITS)
            ]))
            calls = []
            def run(args, **kwargs):
                calls.append(args)
                return subprocess.CompletedProcess(args, int(args[1] in ('PPUTranslator.cpp', 'SPULLVMRecompiler.cpp')))
            with patch.object(gate.subprocess, 'run', side_effect=run):
                with self.assertRaisesRegex(RuntimeError, 'PPUTranslator.cpp.*SPULLVMRecompiler.cpp'):
                    gate.main(database)
            self.assertEqual(len(calls), len(gate.UNITS))

class VdecHostProofSdkTests(unittest.TestCase):
    """Command-contract simulation only; the workflow also runs real FFmpeg."""

    def run_helper(self, root, fail=0):
        tools = root / 'tools'
        tools.mkdir()
        capture = root / 'configure.json'
        final = root / 'native-proof-invoked'
        sdk = '/test/SelectedXcode/MacOSX.sdk'
        configure = root / 'configure-fixture'
        configure.write_text(f'''#!{sys.executable}
import json, os, pathlib, sys
args = dict(arg[2:].split('=', 1) for arg in sys.argv[1:] if arg.startswith('--') and '=' in arg)
pathlib.Path(os.environ['PROBE_CAPTURE']).write_text(json.dumps({{'args': args, 'sdkroot': os.environ.get('SDKROOT')}}))
pathlib.Path('ffbuild').mkdir()
pathlib.Path('ffbuild/config.log').write_text('host C11 compile probe: preserve actual failure details')
if int(os.environ['PROBE_FAIL']): sys.exit(int(os.environ['PROBE_FAIL']))
sdk = os.environ['PROBE_SDK']
assert args.get('host-cc') == '/test/SelectedXcode/clang'
for name in ('host-cflags', 'host-ldflags', 'extra-cflags', 'extra-ldflags'):
    if args.get(name) != '-isysroot ' + sdk:
        print('Host compiler lacks C11 support: host SDK not forwarded', file=sys.stderr)
        sys.exit(84)
assert 'SDKROOT' not in os.environ
''')
        scripts = {
            'xcrun': f'''if '--show-sdk-path' in sys.argv: print({sdk!r})
elif '--find' in sys.argv: print('/test/SelectedXcode/' + sys.argv[-1])
else: sys.exit(90)''',
            'curl': 'pass',
            'shasum': 'sys.stdin.read()',
            'tar': '''import shutil
p = pathlib.Path(sys.argv[sys.argv.index('-C') + 1]) / 'ffmpeg-8.1.1'
p.mkdir()
shutil.copyfile(os.environ['PROBE_CONFIGURE'], p / 'configure')
(p / 'configure').chmod(0o755)''',
            'make': 'pass',
            'python3': '''assert 'rpcs3_video_frame_archive_test.py' in sys.argv[1]
assert 'SDKROOT' not in os.environ
assert os.environ['HOST_MACOS_SDK'] == os.environ['PROBE_SDK']
pathlib.Path(os.environ['PROBE_FINAL']).write_text('real proof command retained')''',
        }
        for name, body in scripts.items():
            file = tools / name
            file.write_text(f'#!{sys.executable}\nimport os, pathlib, sys\n' + body + '\n')
            file.chmod(0o755)
        env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH'],
                   SDKROOT='/wrong/Inherited/iPhoneOS.sdk', RUNNER_TEMP=str(root),
                   CXX='/test/SelectedXcode/clang++', PROBE_SDK=sdk,
                   PROBE_CAPTURE=str(capture), PROBE_FINAL=str(final),
                   PROBE_CONFIGURE=str(configure), PROBE_FAIL=str(fail),
                   VDEC_PROOF_DIAGNOSTICS_DIR=str(root / 'diagnostics'))
        completed = subprocess.run(['bash', str(ROOT / 'build-utils/run_vdec_archive_validation.sh'), str(root)],
                                   env=env, capture_output=True, text=True)
        return completed, capture, final

    def test_host_and_target_get_selected_sdk_without_inherited_ios_sdk(self):
        with tempfile.TemporaryDirectory() as temp:
            result, capture, final = self.run_helper(Path(temp))
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIsNone(json.loads(capture.read_text())['sdkroot'])
            self.assertTrue(final.is_file(), 'Do not replace the native execution with a command check')

    def test_configure_failure_keeps_real_exit_code_and_detailed_log(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            result, _, final = self.run_helper(root, fail=29)
            self.assertEqual(result.returncode, 29, result.stdout + result.stderr)
            self.assertFalse(final.exists(), 'Failed dependency must block native execution')
            log = root / 'diagnostics/vdec-ffmpeg-config.log'
            self.assertTrue(log.is_file(), 'Preserve FFmpeg config.log even before the Core build')
            self.assertIn('host C11 compile probe', log.read_text())


if __name__ == '__main__':
    unittest.main()
