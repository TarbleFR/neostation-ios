"""Execute the shipped state compressor against the real LZ4 codec and write failures."""
from __future__ import annotations

import ctypes
import ctypes.util
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
BLOCK = 1024 * 1024


class DolphinSavestateCompressionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        compiler = shutil.which('c++') or shutil.which('g++') or shutil.which('clang++')
        codec = ctypes.util.find_library('lz4')
        if not compiler or not codec:
            raise unittest.SkipTest('A C++ compiler and the LZ4 runtime are required')
        cls.lz4 = ctypes.CDLL(codec)
        cls.lz4.LZ4_compressBound.argtypes = [ctypes.c_int]
        cls.lz4.LZ4_compressBound.restype = ctypes.c_int
        cls.lz4.LZ4_compress_default.argtypes = [ctypes.c_void_p, ctypes.c_void_p,
                                              ctypes.c_int, ctypes.c_int]
        cls.lz4.LZ4_compress_default.restype = ctypes.c_int
        cls.lz4.LZ4_decompress_safe.argtypes = cls.lz4.LZ4_compress_default.argtypes
        cls.lz4.LZ4_decompress_safe.restype = ctypes.c_int
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        directory = Path(cls.temp.name)
        helper = (ROOT / 'packages/dolphin_internal_bridge/core/NeoStationStateCompression.inc').read_text()
        harness = r'''
#include <algorithm>
#include <cstdint>
#include <cstring>
#include <memory>
#include <new>
#include <vector>
using u8 = uint8_t;
using u64 = uint64_t;
using Bound = int (*)(int);
using Compress = int (*)(const char*, char*, int, int);
static Bound bound_fn;
static Compress compress_fn;
static bool fail_compression;
static int largest_workspace;
static int LZ4_compressBound(int size) { return bound_fn(size); }
static int LZ4_compress_default(const char* src, char* dst, int size, int capacity)
{
  largest_workspace = std::max(largest_workspace, capacity);
  return fail_compression ? 0 : compress_fn(src, dst, size, capacity);
}
namespace File {
struct IOFile {
  std::vector<u8> bytes;
  size_t fail_after = 0;
  size_t writes = 0;
  bool WriteBytes(const void* data, size_t size) {
    if (writes++ == fail_after) return false;
    const auto* begin = static_cast<const u8*>(data);
    bytes.insert(bytes.end(), begin, begin + size);
    return true;
  }
  template <typename T> bool WriteArray(const T* data, size_t count) {
    return WriteBytes(data, count * sizeof(T));
  }
};
}
'''
        harness += helper
        harness += r'''
static File::IOFile result;
extern "C" bool run(const u8* raw, u64 size, size_t fail_after, bool fail,
                    Bound bound, Compress compress) {
  result = {};
  result.fail_after = fail_after;
  fail_compression = fail;
  largest_workspace = 0;
  bound_fn = bound;
  compress_fn = compress;
  return CompressBufferToFile(raw, size, result);
}
extern "C" const u8* data() { return result.bytes.data(); }
extern "C" size_t size() { return result.bytes.size(); }
extern "C" int workspace() { return largest_workspace; }
'''
        source = directory / 'state_compressor.cpp'
        source.write_text(harness)
        library = directory / 'state_compressor.so'
        subprocess.run([compiler, '-std=c++17', '-shared', '-fPIC', '-O2',
                        str(source), '-o', str(library)], check=True,
                       capture_output=True, text=True, timeout=60)
        cls.native = ctypes.CDLL(str(library))
        cls.native.run.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_size_t,
                                   ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p]
        cls.native.run.restype = ctypes.c_bool
        cls.native.data.restype = ctypes.c_void_p
        cls.native.size.restype = ctypes.c_size_t
        cls.native.workspace.restype = ctypes.c_int

    def compress(self, payload, *, fail_after=(1 << 63), fail=False):
        successful = self.native.run(payload, len(payload), fail_after, fail,
                                     self.lz4.LZ4_compressBound, self.lz4.LZ4_compress_default)
        return successful, ctypes.string_at(self.native.data(), self.native.size())

    def decode_native_blocks(self, encoded, size):
        # State.cpp's DecompressLZ4 accepts independent blocks, using each decoded
        # length to advance through its one raw state buffer (no fixed chunk size).
        restored = ctypes.create_string_buffer(size)
        consumed = written = blocks = 0
        while written < size:
            length, = struct.unpack_from('<i', encoded, consumed)
            consumed += 4
            self.assertGreater(length, 0)
            block = encoded[consumed:consumed + length]
            self.assertEqual(len(block), length)
            count = self.lz4.LZ4_decompress_safe(
                block, ctypes.byref(restored, written), length, size - written)
            self.assertGreater(count, 0)
            written += count
            consumed += length
            blocks += 1
        self.assertEqual(written, size)
        self.assertEqual(consumed, len(encoded))
        return restored.raw, blocks

    def test_native_round_trip_at_block_boundaries_has_bounded_workspace(self):
        for size in (1, BLOCK - 1, BLOCK, BLOCK + 1, BLOCK * 5 + 123):
            with self.subTest(size=size):
                payload = (bytes(range(256)) * ((size + 255) // 256))[:size]
                successful, encoded = self.compress(payload)
                self.assertTrue(successful)
                restored, blocks = self.decode_native_blocks(encoded, size)
                self.assertEqual(restored, payload)
                self.assertEqual(blocks, (size + BLOCK - 1) // BLOCK)
                self.assertLessEqual(self.native.workspace(), self.lz4.LZ4_compressBound(BLOCK))

    def test_old_single_block_state_payload_is_still_readable(self):
        payload = b'Wii/GameCube native state compatibility\x00' * 80000
        buffer = ctypes.create_string_buffer(self.lz4.LZ4_compressBound(len(payload)))
        length = self.lz4.LZ4_compress_default(payload, buffer, len(payload), len(buffer))
        self.assertGreater(length, 0)
        encoded = struct.pack('<i', length) + buffer.raw[:length]
        restored, blocks = self.decode_native_blocks(encoded, len(payload))
        self.assertEqual(restored, payload)
        self.assertEqual(blocks, 1)

    def test_disk_and_codec_failures_are_reported_before_publication(self):
        payload = b'x' * (BLOCK + 32)
        for failed_write in range(4):
            with self.subTest(failed_write=failed_write):
                successful, _ = self.compress(payload, fail_after=failed_write)
                self.assertFalse(successful)
        successful, encoded = self.compress(payload, fail=True)
        self.assertFalse(successful)
        self.assertEqual(encoded, b'')
        successful, encoded = self.compress(b'')
        self.assertFalse(successful)
        self.assertEqual(encoded, b'')


if __name__ == '__main__':
    unittest.main()
