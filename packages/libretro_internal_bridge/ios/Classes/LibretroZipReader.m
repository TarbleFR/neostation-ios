#import "LibretroZipReader.h"

#include <zlib.h>

NSErrorDomain const LibretroZipErrorDomain = @"org.neostation.libretro.zip";

static NSError *ZipError(LibretroZipError code, NSString *detail) {
  return [NSError errorWithDomain:LibretroZipErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey : detail}];
}

static uint16_t ReadLE16(const uint8_t *bytes) { return (uint16_t)(bytes[0] | (bytes[1] << 8)); }

static uint32_t ReadLE32(const uint8_t *bytes) {
  return (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8) | ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[3] << 24);
}

@interface LibretroZipEntry : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic) uint16_t method;
@property(nonatomic) uint16_t flags;
@property(nonatomic) uint32_t crc;
@property(nonatomic) uint32_t compressedSize;
@property(nonatomic) uint32_t uncompressedSize;
@property(nonatomic) uint32_t localHeaderOffset;
@end

@implementation LibretroZipEntry
@end

@implementation LibretroZipReader

+ (NSArray<LibretroZipEntry *> *)entriesInArchive:(NSData *)archive error:(NSError **)error {
  const uint8_t *bytes = archive.bytes;
  NSUInteger length = archive.length;
  if (length < 22) {
    if (error) *error = ZipError(LibretroZipErrorNotAnArchive, @"too small");
    return nil;
  }
  NSUInteger searchStart = length > 22 + 65535 ? length - 22 - 65535 : 0;
  NSInteger eocd = -1;
  for (NSUInteger index = length - 22 + 1; index-- > searchStart;) {
    if (ReadLE32(bytes + index) == 0x06054b50) {
      eocd = (NSInteger)index;
      break;
    }
  }
  if (eocd < 0) {
    if (error) *error = ZipError(LibretroZipErrorNotAnArchive, @"no end of central directory");
    return nil;
  }
  const uint8_t *end = bytes + eocd;
  uint16_t total = ReadLE16(end + 10);
  uint32_t directorySize = ReadLE32(end + 12);
  uint32_t directoryOffset = ReadLE32(end + 16);
  if (total == 0xFFFF || directoryOffset == 0xFFFFFFFFu || directorySize == 0xFFFFFFFFu) {
    if (error) *error = ZipError(LibretroZipErrorUnsupported, @"zip64");
    return nil;
  }
  if ((NSUInteger)directoryOffset + directorySize > length) {
    if (error) *error = ZipError(LibretroZipErrorCorrupt, @"central directory bounds");
    return nil;
  }
  NSMutableArray<LibretroZipEntry *> *entries = [NSMutableArray arrayWithCapacity:total];
  NSUInteger offset = directoryOffset;
  for (uint16_t index = 0; index < total; index++) {
    if (offset + 46 > length || ReadLE32(bytes + offset) != 0x02014b50) {
      if (error) *error = ZipError(LibretroZipErrorCorrupt, @"central directory entry");
      return nil;
    }
    const uint8_t *header = bytes + offset;
    uint16_t nameLength = ReadLE16(header + 28);
    uint16_t extraLength = ReadLE16(header + 30);
    uint16_t commentLength = ReadLE16(header + 32);
    if (offset + 46 + nameLength > length) {
      if (error) *error = ZipError(LibretroZipErrorCorrupt, @"entry name");
      return nil;
    }
    LibretroZipEntry *entry = [LibretroZipEntry new];
    entry.flags = ReadLE16(header + 8);
    entry.method = ReadLE16(header + 10);
    entry.crc = ReadLE32(header + 16);
    entry.compressedSize = ReadLE32(header + 20);
    entry.uncompressedSize = ReadLE32(header + 24);
    entry.localHeaderOffset = ReadLE32(header + 42);
    NSString *name = [[NSString alloc] initWithBytes:header + 46 length:nameLength encoding:NSUTF8StringEncoding];
    if (name == nil) {
      name = [[NSString alloc] initWithBytes:header + 46 length:nameLength encoding:NSISOLatin1StringEncoding];
    }
    entry.name = name ?: @"";
    if (entry.compressedSize == 0xFFFFFFFFu || entry.uncompressedSize == 0xFFFFFFFFu ||
        entry.localHeaderOffset == 0xFFFFFFFFu) {
      if (error) *error = ZipError(LibretroZipErrorUnsupported, @"zip64 entry");
      return nil;
    }
    [entries addObject:entry];
    offset += 46 + nameLength + extraLength + commentLength;
  }
  return entries;
}

+ (nullable NSString *)safeRelativePath:(NSString *)name {
  NSMutableArray<NSString *> *parts = [NSMutableArray array];
  for (NSString *component in [name componentsSeparatedByString:@"/"]) {
    if (component.length == 0 || [component isEqualToString:@"."]) continue;
    if ([component isEqualToString:@".."] || [component containsString:@"\\"]) return nil;
    [parts addObject:component];
  }
  return parts.count > 0 ? [parts componentsJoinedByString:@"/"] : nil;
}

+ (BOOL)extractEntry:(LibretroZipEntry *)entry
           fromArchive:(NSData *)archive
                toPath:(NSString *)path
                 error:(NSError **)error {
  const uint8_t *bytes = archive.bytes;
  NSUInteger length = archive.length;
  NSUInteger local = entry.localHeaderOffset;
  if (local + 30 > length || ReadLE32(bytes + local) != 0x04034b50) {
    if (error) *error = ZipError(LibretroZipErrorCorrupt, @"local header");
    return NO;
  }
  NSUInteger dataOffset = local + 30 + ReadLE16(bytes + local + 26) + ReadLE16(bytes + local + 28);
  if (dataOffset + entry.compressedSize > length) {
    if (error) *error = ZipError(LibretroZipErrorCorrupt, @"entry data bounds");
    return NO;
  }
  if ((entry.flags & 0x1) != 0 || (entry.method != 0 && entry.method != 8)) {
    if (error) *error = ZipError(LibretroZipErrorUnsupported, @"encrypted or unsupported method");
    return NO;
  }
  NSFileManager *files = [NSFileManager defaultManager];
  [files createDirectoryAtPath:[path stringByDeletingLastPathComponent]
      withIntermediateDirectories:YES
                       attributes:nil
                            error:nil];
  [files removeItemAtPath:path error:nil];
  if (![files createFileAtPath:path contents:nil attributes:nil]) {
    if (error) *error = ZipError(LibretroZipErrorWriteFailed, path);
    return NO;
  }
  NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
  if (handle == nil) {
    if (error) *error = ZipError(LibretroZipErrorWriteFailed, path);
    return NO;
  }
  uLong crc = crc32(0L, Z_NULL, 0);
  uint64_t written = 0;
  BOOL ok = YES;
  if (entry.method == 0) {
    NSData *payload = [archive subdataWithRange:NSMakeRange(dataOffset, entry.compressedSize)];
    crc = crc32(crc, payload.bytes, (uInt)payload.length);
    ok = [handle writeData:payload error:error];
    written = payload.length;
  } else {
    z_stream stream;
    memset(&stream, 0, sizeof(stream));
    if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) {
      [handle closeAndReturnError:nil];
      if (error) *error = ZipError(LibretroZipErrorCorrupt, @"inflate init");
      return NO;
    }
    const NSUInteger bufferSize = 1 << 20;
    NSMutableData *buffer = [NSMutableData dataWithLength:bufferSize];
    stream.next_in = (Bytef *)(bytes + dataOffset);
    stream.avail_in = entry.compressedSize;
    int result = Z_OK;
    while (result != Z_STREAM_END) {
      stream.next_out = buffer.mutableBytes;
      stream.avail_out = (uInt)bufferSize;
      result = inflate(&stream, Z_NO_FLUSH);
      if (result != Z_OK && result != Z_STREAM_END) {
        ok = NO;
        if (error) *error = ZipError(LibretroZipErrorCorrupt, @"inflate");
        break;
      }
      NSUInteger produced = bufferSize - stream.avail_out;
      if (produced > 0) {
        crc = crc32(crc, buffer.bytes, (uInt)produced);
        if (![handle writeData:[NSData dataWithBytesNoCopy:buffer.mutableBytes length:produced freeWhenDone:NO]
                         error:error]) {
          ok = NO;
          break;
        }
        written += produced;
      } else if (result == Z_OK && stream.avail_in == 0) {
        ok = NO;
        if (error) *error = ZipError(LibretroZipErrorCorrupt, @"truncated deflate stream");
        break;
      }
    }
    inflateEnd(&stream);
  }
  [handle closeAndReturnError:nil];
  if (ok && (written != entry.uncompressedSize || crc != entry.crc)) {
    ok = NO;
    if (error) *error = ZipError(LibretroZipErrorCorrupt, @"crc or size mismatch");
  }
  if (!ok) [files removeItemAtPath:path error:nil];
  return ok;
}

+ (nullable NSString *)extractContentFromArchive:(NSString *)archivePath
                                     extensions:(NSSet<NSString *> *)extensions
                                    toDirectory:(NSString *)directory
                                          error:(NSError **)error {
  NSError *readError = nil;
  NSData *archive = [NSData dataWithContentsOfFile:archivePath options:NSDataReadingMappedIfSafe error:&readError];
  if (archive == nil) {
    if (error) *error = ZipError(LibretroZipErrorUnreadable, readError.localizedDescription ?: archivePath);
    return nil;
  }
  NSArray<LibretroZipEntry *> *entries = [self entriesInArchive:archive error:error];
  if (entries == nil) return nil;
  LibretroZipEntry *selected = nil;
  for (LibretroZipEntry *entry in entries) {
    if ([entry.name hasSuffix:@"/"]) continue;
    NSString *extension = entry.name.pathExtension.lowercaseString;
    if (extensions.count == 0 || [extensions containsObject:extension]) {
      selected = entry;
      break;
    }
  }
  if (selected == nil) {
    if (error) *error = ZipError(LibretroZipErrorNoMatchingEntry, archivePath.lastPathComponent);
    return nil;
  }
  NSString *selectedRelative = [self safeRelativePath:selected.name];
  if (selectedRelative == nil) {
    if (error) *error = ZipError(LibretroZipErrorCorrupt, @"unsafe entry name");
    return nil;
  }
  static NSSet<NSString *> *descriptors;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    descriptors = [NSSet setWithArray:@[ @"cue", @"m3u", @"gdi", @"ccd", @"toc" ]];
  });
  BOOL extractAll = [descriptors containsObject:selected.name.pathExtension.lowercaseString];
  for (LibretroZipEntry *entry in entries) {
    if ([entry.name hasSuffix:@"/"]) continue;
    if (!extractAll && entry != selected) continue;
    NSString *relative = [self safeRelativePath:entry.name];
    if (relative == nil) continue;
    NSString *target = [directory stringByAppendingPathComponent:relative];
    if (![self extractEntry:entry fromArchive:archive toPath:target error:error]) return nil;
  }
  return [directory stringByAppendingPathComponent:selectedRelative];
}

@end
