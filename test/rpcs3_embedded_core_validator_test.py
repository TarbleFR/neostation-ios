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
    def core(
        *,
        jit_marker: bytes = b'NEOSTATION_DYNAMIC_JIT_V5',
        undefined_symbol: str | None = None,
    ) -> bytes:
        header = bytearray(32)
        header[:4] = b'\xcf\xfa\xed\xfe'
        struct.pack_into('<I', header, 4, 0x0100000C)
        struct.pack_into('<I', header, 12, 6)
        image = header
        if undefined_symbol is not None:
            strings = b'\0' + undefined_symbol.encode('utf-8') + b'\0'
            symbol_offset = 32 + 24
            string_offset = symbol_offset + 16
            struct.pack_into('<II', image, 16, 1, 24)
            image.extend(struct.pack('<IIIIII', 0x2, 24, symbol_offset, 1,
                                     string_offset, len(strings)))
            image.extend(struct.pack('<IBBHQ', 1, 0x01, 0, 0, 0))
            image.extend(strings)
        markers = [jit_marker if label == 'Build 266 JIT' else marker
                   for label, marker in validator.REQUIRED_MARKERS]
        return bytes(image) + b'\0'.join(markers)

    def test_accepts_final_build266_v5_contract(self) -> None:
        validator.validate_core(self.core())

    def test_rejects_stale_v4_jit_marker_with_explicit_reason(self) -> None:
        with self.assertRaisesRegex(ValueError, 'Build 266 JIT.*NEOSTATION_DYNAMIC_JIT_V5'):
            validator.validate_core(self.core(jit_marker=b'NEOSTATION_DYNAMIC_JIT_V4'))

    def test_rejects_reintroduced_host_memory_reservation(self) -> None:
        with self.assertRaisesRegex(ValueError, 'retired startup marker'):
            validator.validate_core(self.core() + b'NEOSTATION_BUILD302_RESERVED_STARTUP_V1')

    def test_rejects_load_time_vm_map_import(self) -> None:
        with self.assertRaisesRegex(ValueError, 'forbidden load-time imports: _vm_map'):
            validator.validate_core(self.core(undefined_symbol='_vm_map'))

    def test_rejects_load_time_os_log_import(self) -> None:
        with self.assertRaisesRegex(ValueError, 'forbidden load-time imports: __os_log_error_impl'):
            validator.validate_core(
                self.core(undefined_symbol='__os_log_error_impl')
            )


if __name__ == '__main__':
    unittest.main()
