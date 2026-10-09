#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const LibretroZipErrorDomain;

typedef NS_ERROR_ENUM(LibretroZipErrorDomain, LibretroZipError) {
  LibretroZipErrorUnreadable = 1,
  LibretroZipErrorNotAnArchive = 2,
  LibretroZipErrorUnsupported = 3,
  LibretroZipErrorNoMatchingEntry = 4,
  LibretroZipErrorCorrupt = 5,
  LibretroZipErrorWriteFailed = 6,
};

/// Minimal ZIP reader (stored and deflate entries) used to hand archived
/// content to cores that cannot open archives themselves, as RetroArch does.
@interface LibretroZipReader : NSObject

/// Extracts the first entry whose extension is in `extensions` (lowercase,
/// without dot) into `directory`. When that entry is a descriptor
/// (`cue`, `m3u`, `gdi`, `ccd`, `toc`), every file of the archive is
/// extracted so the referenced tracks sit next to it. Returns the path of
/// the selected entry.
+ (nullable NSString *)extractContentFromArchive:(NSString *)archivePath
                                     extensions:(NSSet<NSString *> *)extensions
                                    toDirectory:(NSString *)directory
                                          error:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
