#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Canonical NeoStation in-game locale. The supported set exactly mirrors the
/// 12 locales declared by NeoStation's Flutter root.
FOUNDATION_EXPORT NSString* ARMSX2CanonicalLocale(NSString* _Nullable identifier);

/// Localizes an ARMSX2 in-game string from NeoStation's selected app locale.
/// [english] is the stable key. [french] is retained as a fail-safe for legacy
/// call sites while the translation table remains authoritative for all locales.
FOUNDATION_EXPORT NSString* ARMSX2LocalizedText(
    NSString* english,
    NSString* french,
    NSString* _Nullable localeIdentifier);

NS_ASSUME_NONNULL_END
