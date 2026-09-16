#!/usr/bin/env python3
"""Regression tests for the final Build 266 embedded-core marker contract."""
from __future__ import annotations

import importlib.util
import struct
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUILD_UTILS = ROOT / 'build-utils'
sys.path.insert(0, str(BUILD_UTILS))

spec = importlib.util.spec_from_file_location(
    'validate_rpcs3_embedded_core', BUILD_UTILS / 'validate_rpcs3_embedded_core.py'
)
validator = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(validator)


class EmbeddedCoreValidatorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.minimum_size = validator.MINIMUM_CORE_SIZE
        validator.MINIMUM_CORE_SIZE = 64
        self.addCleanup(setattr, validator, 'MINIMUM_CORE_SIZE', self.minimum_size)

    @staticmethod
    def core(*, jit_marker: bytes = b'NEOSTATION_DYNAMIC_JIT_V5') -> bytes:
        header = bytearray(64)
        header[:4] = b'\xcf\xfa\xed\xfe'
        struct.pack_into('<I', header, 4, 0x0100000C)
        struct.pack_into('<I', header, 12, 6)
        markers = [marker for _, marker in validator.REQUIRED_MARKERS]
        markers[0] = jit_marker
        return bytes(header) + b'\0'.join(markers)

    def test_accepts_final_build266_v5_contract(self) -> None:
        validator.validate_core(self.core())

    def test_rejects_stale_v4_jit_marker_with_explicit_reason(self) -> None:
        with self.assertRaisesRegex(ValueError, 'Build 266 JIT.*NEOSTATION_DYNAMIC_JIT_V5'):
            validator.validate_core(self.core(jit_marker=b'NEOSTATION_DYNAMIC_JIT_V4'))


if __name__ == '__main__':
    unittest.main()
