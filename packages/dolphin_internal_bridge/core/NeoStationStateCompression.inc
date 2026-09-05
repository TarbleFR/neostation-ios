// Bounded workspace for Dolphin's existing LZ4 state format.
// SPDX-License-Identifier: GPL-2.0-or-later
static bool CompressBufferToFile(const u8* raw_buffer, u64 size, File::IOFile& f)
{
  if (size == 0)
    return false;

  // The native reader already handles multiple independent LZ4 blocks. A whole
  // Wii state can exceed 100 MiB; allocating a second state-sized buffer while
  // its raw snapshot and Metal textures are resident creates avoidable pressure.
  constexpr u64 block_size = 1024 * 1024;
  const int capacity = LZ4_compressBound(static_cast<int>(std::min(size, block_size)));
  std::unique_ptr<char[]> compressed_buffer(new (std::nothrow) char[capacity]);
  if (!compressed_buffer)
    return false;

  u64 total_bytes_compressed = 0;
  while (total_bytes_compressed < size)
  {
    const int bytes_to_compress =
        static_cast<int>(std::min(block_size, size - total_bytes_compressed));
    const int compressed_len = LZ4_compress_default(
        reinterpret_cast<const char*>(raw_buffer) + total_bytes_compressed,
        compressed_buffer.get(), bytes_to_compress, capacity);
    if (compressed_len <= 0 || !f.WriteArray(&compressed_len, 1) ||
        !f.WriteBytes(compressed_buffer.get(), compressed_len))
      return false;

    total_bytes_compressed += bytes_to_compress;
  }
  return true;
}
