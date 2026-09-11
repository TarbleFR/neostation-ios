// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Normalizes Flutter/BCP-47 locale identifiers to NeoStation's 12 UI locales.
FOUNDATION_EXPORT NSString* RPCS3CanonicalLocale(NSString* _Nullable identifier);

/// Returns one translated RPCS3 in-game UI string, falling back to English.
FOUNDATION_EXPORT NSString* RPCS3LocalizedString(NSString* key,
                                                 NSString* _Nullable localeIdentifier);

NS_ASSUME_NONNULL_END
