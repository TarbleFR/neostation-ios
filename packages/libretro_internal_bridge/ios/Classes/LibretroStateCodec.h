#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const LibretroStateCodecErrorDomain;

typedef NS_ERROR_ENUM(LibretroStateCodecErrorDomain, LibretroStateCodecError) {
  LibretroStateCodecErrorTruncated = 1,
  LibretroStateCodecErrorUnsupportedCompression = 2,
  LibretroStateCodecErrorCorruptCompression = 3,
  LibretroStateCodecErrorMissingCoreBlock = 4,
};

/// Reads and writes save-state files in the layouts RetroArch uses, so a
/// state written by RetroArch can be loaded here and the other way round.
///
/// Accepted inputs: a raw core serialization, a `RASTATE` container
/// (version 1: blocks `MEM `, `ACHV`, `RPLY`, `END `, each padded to 8
/// bytes) and either of those wrapped in an `#RZIPv1#` deflate stream.
/// `#RZIPv2#` (zstd) is reported as unsupported rather than guessed.
@interface LibretroStateCodec : NSObject

/// Returns the exact core serialization stored in `data`.
+ (nullable NSData *)coreStateFromFileData:(NSData *)data
                                     error:(NSError *_Nullable *_Nullable)error;

/// Wraps a core serialization in an uncompressed `RASTATE` v1 container
/// that RetroArch also reads.
+ (NSData *)containerForCoreState:(NSData *)state;

/// Decompresses an `#RZIPv1#` stream; returns `data` unchanged when it is
/// not rzip-compressed.
+ (nullable NSData *)decompressRzipIfNeeded:(NSData *)data
                                      error:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
