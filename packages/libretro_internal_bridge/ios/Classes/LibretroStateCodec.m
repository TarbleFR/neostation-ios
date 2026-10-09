#import "LibretroStateCodec.h"

#include <zlib.h>

NSErrorDomain const LibretroStateCodecErrorDomain = @"org.neostation.libretro.state";

static const NSUInteger kRzipHeaderSize = 20;
static const uint32_t kRzipMaxChunkSize = 64u * 1024u * 1024u;
static const uint64_t kMaxStateSize = 2ull * 1024ull * 1024ull * 1024ull;

static NSError *StateError(LibretroStateCodecError code, NSString *detail) {
  return [NSError errorWithDomain:LibretroStateCodecErrorDomain
                             code:code
                         userInfo:@{NSLocalizedDescriptionKey : detail}];
}

static uint32_t ReadLE32(const uint8_t *bytes) {
  return (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8) | ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[3] << 24);
}

static uint64_t ReadLE64(const uint8_t *bytes) {
  return (uint64_t)ReadLE32(bytes) | ((uint64_t)ReadLE32(bytes + 4) << 32);
}

static void WriteLE32(uint8_t *bytes, uint32_t value) {
  bytes[0] = (uint8_t)(value & 0xFF);
  bytes[1] = (uint8_t)((value >> 8) & 0xFF);
  bytes[2] = (uint8_t)((value >> 16) & 0xFF);
  bytes[3] = (uint8_t)((value >> 24) & 0xFF);
}

/// Inflates one rzip chunk. RetroArch writes zlib-framed chunks; raw
/// deflate is accepted as a fallback. Returns the produced byte count or
/// -1 on failure.
static long InflateChunk(const uint8_t *input, uint32_t inputSize, uint8_t *output, uint32_t outputSize) {
  const int windowBits[2] = {MAX_WBITS + 32, -MAX_WBITS};
  for (int attempt = 0; attempt < 2; attempt++) {
    z_stream stream;
    memset(&stream, 0, sizeof(stream));
    if (inflateInit2(&stream, windowBits[attempt]) != Z_OK) continue;
    stream.next_in = (Bytef *)input;
    stream.avail_in = inputSize;
    stream.next_out = output;
    stream.avail_out = outputSize;
    int result = inflate(&stream, Z_FINISH);
    uLong produced = stream.total_out;
    inflateEnd(&stream);
    if (result == Z_STREAM_END && produced > 0) return (long)produced;
  }
  return -1;
}

@implementation LibretroStateCodec

+ (nullable NSData *)decompressRzipIfNeeded:(NSData *)data error:(NSError **)error {
  const uint8_t *bytes = data.bytes;
  if (data.length < kRzipHeaderSize || memcmp(bytes, "#RZIPv", 6) != 0 || bytes[7] != '#') return data;
  if (bytes[6] == 2) {
    if (error) *error = StateError(LibretroStateCodecErrorUnsupportedCompression, @"rzip/zstd");
    return nil;
  }
  if (bytes[6] != 1) {
    if (error) *error = StateError(LibretroStateCodecErrorUnsupportedCompression, @"rzip version");
    return nil;
  }
  uint32_t chunkSize = ReadLE32(bytes + 8);
  uint64_t totalSize = ReadLE64(bytes + 12);
  if (chunkSize == 0 || chunkSize > kRzipMaxChunkSize || totalSize == 0 || totalSize > kMaxStateSize) {
    if (error) *error = StateError(LibretroStateCodecErrorCorruptCompression, @"rzip header");
    return nil;
  }
  NSMutableData *output = [NSMutableData dataWithCapacity:(NSUInteger)totalSize];
  NSMutableData *chunk = [NSMutableData dataWithLength:chunkSize];
  NSUInteger offset = kRzipHeaderSize;
  while (output.length < totalSize) {
    if (offset + 4 > data.length) {
      if (error) *error = StateError(LibretroStateCodecErrorTruncated, @"rzip chunk header");
      return nil;
    }
    uint32_t compressedSize = ReadLE32(bytes + offset);
    offset += 4;
    if (compressedSize == 0 || compressedSize > chunkSize * 2u || compressedSize > data.length - offset) {
      if (error) *error = StateError(LibretroStateCodecErrorCorruptCompression, @"rzip chunk size");
      return nil;
    }
    long produced = InflateChunk(bytes + offset, compressedSize, chunk.mutableBytes, chunkSize);
    if (produced < 0) {
      if (error) *error = StateError(LibretroStateCodecErrorCorruptCompression, @"rzip chunk data");
      return nil;
    }
    uint64_t remaining = totalSize - output.length;
    [output appendBytes:chunk.bytes length:(NSUInteger)MIN((uint64_t)produced, remaining)];
    offset += compressedSize;
  }
  return output;
}

+ (nullable NSData *)coreStateFromFileData:(NSData *)fileData error:(NSError **)error {
  NSData *data = [self decompressRzipIfNeeded:fileData error:error];
  if (data == nil) return nil;
  const uint8_t *bytes = data.bytes;
  NSUInteger length = data.length;
  if (length < 8 || memcmp(bytes, "RASTATE", 7) != 0) return data;
  NSUInteger offset = 8;
  while (offset + 8 <= length) {
    const uint8_t *identifier = bytes + offset;
    uint32_t size = ReadLE32(bytes + offset + 4);
    offset += 8;
    if (memcmp(identifier, "END ", 4) == 0) break;
    if (size > length - offset) {
      if (error) *error = StateError(LibretroStateCodecErrorTruncated, @"RASTATE block");
      return nil;
    }
    if (memcmp(identifier, "MEM ", 4) == 0) return [data subdataWithRange:NSMakeRange(offset, size)];
    NSUInteger aligned = ((NSUInteger)size + 7u) & ~(NSUInteger)7u;
    offset += MIN(aligned, length - offset);
  }
  if (error) *error = StateError(LibretroStateCodecErrorMissingCoreBlock, @"RASTATE MEM block");
  return nil;
}

+ (NSData *)containerForCoreState:(NSData *)state {
  NSUInteger aligned = (state.length + 7u) & ~(NSUInteger)7u;
  NSMutableData *container = [NSMutableData dataWithLength:8 + 8 + aligned + 8];
  uint8_t *bytes = container.mutableBytes;
  memcpy(bytes, "RASTATE", 7);
  bytes[7] = 1;
  memcpy(bytes + 8, "MEM ", 4);
  WriteLE32(bytes + 12, (uint32_t)state.length);
  if (state.length > 0) memcpy(bytes + 16, state.bytes, state.length);
  memcpy(bytes + 16 + aligned, "END ", 4);
  WriteLE32(bytes + 20 + aligned, 0);
  return container;
}

@end
