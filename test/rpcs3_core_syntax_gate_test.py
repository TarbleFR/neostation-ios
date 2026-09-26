"""Test compile-command preservation and dependency ordering, not device JIT."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
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
            for name in sorted(gate.UNITS):
                entries.append({'file': name, 'directory': temp, 'arguments': [
                    'clang++', '--target=arm64-apple-ios16.3', '-std=c++23',
                    '-fexceptions', '-DREQUIRED=1', '-c', name, '-o', name+'.o',
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
                    self.assertIn('-fexceptions', args)
                    self.assertIn('-fsyntax-only', args)
                    self.assertNotIn('-o', args)
                    self.assertNotIn('-c', args)
            with patch.object(gate.subprocess, 'run', side_effect=run):
                gate.main(database)
            self.assertEqual(calls[0][0], 'cmake')
            self.assertEqual(len(calls), len(gate.UNITS) + 1)

    def test_missing_translation_units_are_an_error(self):
        with tempfile.TemporaryDirectory() as temp:
            database = Path(temp)/'compile_commands.json'
            database.write_text('[]')
            with self.assertRaisesRegex(RuntimeError, 'Missing startup units'):
                gate.main(database)

if __name__ == '__main__':
    unittest.main()
