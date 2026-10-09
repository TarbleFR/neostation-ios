#import "LibretroFrontendStore.h"

NSString *const LibretroSettingSkinPortrait = @"skin.portrait";
NSString *const LibretroSettingSkinLandscape = @"skin.landscape";
NSString *const LibretroSettingScreenFormat = @"screenFormat";
NSString *const LibretroSettingArrangementPortrait = @"screenArrangement.portrait";
NSString *const LibretroSettingArrangementLandscape = @"screenArrangement.landscape";
NSString *const LibretroSettingScreensSwapped = @"screensSwapped";
NSString *const LibretroSettingShaderEnabled = @"shader.enabled";
NSString *const LibretroSettingShaderPreset = @"shader.preset";
NSString *const LibretroSettingShaderParameters = @"shader.parameters";
NSString *const LibretroSettingGamepad = @"controls.gamepad";
NSString *const LibretroSettingOpacity = @"controls.opacity";

static NSString *const kTouchRemapPrefix = @"controls.touch.";
static NSString *const kLayoutPrefix = @"controls.layout.";
static NSString *const kConsoleScope = @"console";
static NSString *const kGamesScope = @"games";
static NSString *const kVersionKey = @"version";
static const NSInteger kFileVersion = 1;

NSString *LibretroSettingTouchRemapKey(NSString *skinId) {
  return [kTouchRemapPrefix stringByAppendingString:skinId];
}

NSString *LibretroSettingLayoutKey(NSString *skinId, NSString *orientation) {
  return [NSString stringWithFormat:@"%@%@.%@", kLayoutPrefix, skinId, orientation];
}

/// Console ids name files: letters, digits, '-' and '_' only.
static BOOL IsConsoleIdentifier(NSString *console) {
  if (![console isKindOfClass:[NSString class]] || console.length == 0 || console.length > 64) return NO;
  static NSCharacterSet *forbidden;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSString *allowed = @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_";
    forbidden = [NSCharacterSet characterSetWithCharactersInString:allowed].invertedSet;
  });
  return [console rangeOfCharacterFromSet:forbidden].location == NSNotFound;
}

static BOOL IsSettingKey(NSString *key) {
  return [key isKindOfClass:[NSString class]] && key.length > 0;
}

/// nil (console scope) for a missing or empty game key.
static NSString *GameScopeKey(NSString *gameKey) {
  return [gameKey isKindOfClass:[NSString class]] && gameKey.length > 0 ? gameKey : nil;
}

static NSDictionary<NSString *, id> *StringKeyedDictionary(id object) {
  if (![object isKindOfClass:[NSDictionary class]]) return @{};
  NSMutableDictionary<NSString *, id> *result = [NSMutableDictionary dictionary];
  NSDictionary *source = object;
  for (id key in source) {
    if ([key isKindOfClass:[NSString class]]) result[key] = source[key];
  }
  return [result copy];
}

/// JSON round trip: refuses anything that is not a JSON type and keeps
/// exactly what the file will hold (immutable containers).
static id NormalizedValue(id value) {
  NSArray *wrapper = @[ value ];
  if (![NSJSONSerialization isValidJSONObject:wrapper]) return nil;
  NSData *data = [NSJSONSerialization dataWithJSONObject:wrapper options:0 error:nil];
  if (data == nil) return nil;
  id decoded = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (![decoded isKindOfClass:[NSArray class]] || [(NSArray *)decoded count] != 1) return nil;
  return [(NSArray *)decoded firstObject];
}

/// Values of one scope of a console document; never nil.
static NSDictionary<NSString *, id> *ScopeValues(NSDictionary *document, NSString *game) {
  if (game == nil) return document[kConsoleScope];
  NSDictionary *games = document[kGamesScope];
  NSDictionary *values = games[game];
  return values ?: @{};
}

static NSDictionary *DocumentReplacingScope(NSDictionary *document, NSString *game, NSDictionary *values) {
  if (game == nil) return @{kConsoleScope : [values copy], kGamesScope : document[kGamesScope]};
  NSMutableDictionary *games = [document[kGamesScope] mutableCopy];
  if (values.count > 0) {
    games[game] = [values copy];
  } else {
    [games removeObjectForKey:game];
  }
  return @{kConsoleScope : document[kConsoleScope], kGamesScope : [games copy]};
}

static BOOL KeyHasPrefix(NSString *key, NSArray<NSString *> *prefixes) {
  if (prefixes == nil) return YES;
  for (id prefix in prefixes) {
    if ([prefix isKindOfClass:[NSString class]] && [key hasPrefix:prefix]) return YES;
  }
  return NO;
}

/// Drops the selections, touch remaps and layouts of `skinId` from one scope.
static NSDictionary *ValuesForgettingSkin(NSDictionary *values, NSString *skinId) {
  NSString *touchKey = LibretroSettingTouchRemapKey(skinId);
  NSString *layoutPrefix = [NSString stringWithFormat:@"%@%@.", kLayoutPrefix, skinId];
  NSMutableDictionary *kept = [NSMutableDictionary dictionary];
  for (NSString *key in values) {
    id value = values[key];
    BOOL selection = ([key isEqualToString:LibretroSettingSkinPortrait] ||
                      [key isEqualToString:LibretroSettingSkinLandscape]) &&
                     [value isEqual:skinId];
    // Only "<prefix><orientation>": the layouts of a skin "a.b" are not those of "a".
    BOOL layout = [key hasPrefix:layoutPrefix] && key.length > layoutPrefix.length &&
                  [[key substringFromIndex:layoutPrefix.length] rangeOfString:@"."].location == NSNotFound;
    if (!selection && !layout && ![key isEqualToString:touchKey]) kept[key] = value;
  }
  return [kept copy];
}

@interface LibretroFrontendStore ()
- (instancetype)initWithDirectoryPath:(NSString *)directory;
@end

@implementation LibretroFrontendStore {
  /// console -> {"console": {key: value}, "games": {gameKey: {key: value}}}
  NSMutableDictionary<NSString *, NSDictionary *> *_documents;
}

+ (instancetype)storeWithDirectory:(NSString *)directory {
  static NSMutableDictionary<NSString *, LibretroFrontendStore *> *stores;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    stores = [NSMutableDictionary dictionary];
  });
  NSString *path = [directory isKindOfClass:[NSString class]] ? directory.stringByStandardizingPath : @"";
  @synchronized(stores) {
    LibretroFrontendStore *store = stores[path];
    if (store == nil) {
      store = [[LibretroFrontendStore alloc] initWithDirectoryPath:path];
      stores[path] = store;
    }
    return store;
  }
}

- (instancetype)initWithDirectoryPath:(NSString *)directory {
  self = [super init];
  if (self) {
    _directory = [directory copy];
    _documents = [NSMutableDictionary dictionary];
  }
  return self;
}

- (NSString *)pathForConsole:(NSString *)console {
  return [_directory stringByAppendingPathComponent:[console stringByAppendingString:@".json"]];
}

- (NSDictionary *)documentForConsoleLocked:(NSString *)console {
  NSDictionary *document = _documents[console];
  if (document != nil) return document;
  NSDictionary *consoleValues = @{};
  NSMutableDictionary *games = [NSMutableDictionary dictionary];
  NSData *data = [NSData dataWithContentsOfFile:[self pathForConsole:console]];
  id json = data != nil ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  if ([json isKindOfClass:[NSDictionary class]]) {
    NSDictionary *root = json;
    consoleValues = StringKeyedDictionary(root[kConsoleScope]);
    NSDictionary *storedGames = StringKeyedDictionary(root[kGamesScope]);
    for (NSString *game in storedGames) {
      NSDictionary *values = StringKeyedDictionary(storedGames[game]);
      if (game.length > 0 && values.count > 0) games[game] = values;
    }
  }
  document = @{kConsoleScope : consoleValues, kGamesScope : [games copy]};
  _documents[console] = document;
  return document;
}

/// Writes the whole console file atomically, then makes `document` current.
- (BOOL)writeDocumentLocked:(NSDictionary *)document console:(NSString *)console {
  NSDictionary *root = @{
    kVersionKey : @(kFileVersion),
    kConsoleScope : document[kConsoleScope],
    kGamesScope : document[kGamesScope],
  };
  if (![NSJSONSerialization isValidJSONObject:root]) return NO;
  NSData *data = [NSJSONSerialization dataWithJSONObject:root
                                                 options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                   error:nil];
  if (data == nil) return NO;
  NSFileManager *files = [NSFileManager defaultManager];
  if (![files createDirectoryAtPath:_directory withIntermediateDirectories:YES attributes:nil error:nil]) return NO;
  if (![data writeToFile:[self pathForConsole:console] options:NSDataWritingAtomic error:nil]) return NO;
  _documents[console] = document;
  return YES;
}

- (id)valueForKey:(NSString *)key
         console:(NSString *)console
            game:(NSString *)gameKey
           scope:(LibretroSettingScope *)scope {
  if (scope != NULL) *scope = LibretroSettingScopeDefault;
  if (!IsConsoleIdentifier(console) || !IsSettingKey(key)) return nil;
  NSString *game = GameScopeKey(gameKey);
  @synchronized(self) {
    NSDictionary *document = [self documentForConsoleLocked:console];
    if (game != nil) {
      id value = ScopeValues(document, game)[key];
      if (value != nil) {
        if (scope != NULL) *scope = LibretroSettingScopeGame;
        return value;
      }
    }
    id value = ScopeValues(document, nil)[key];
    if (value != nil && scope != NULL) *scope = LibretroSettingScopeConsole;
    return value;
  }
}

- (id)storedValueForKey:(NSString *)key console:(NSString *)console game:(NSString *)gameKey {
  if (!IsConsoleIdentifier(console) || !IsSettingKey(key)) return nil;
  @synchronized(self) {
    return ScopeValues([self documentForConsoleLocked:console], GameScopeKey(gameKey))[key];
  }
}

- (BOOL)setValue:(id)value forKey:(NSString *)key console:(NSString *)console game:(NSString *)gameKey {
  if (!IsConsoleIdentifier(console) || !IsSettingKey(key)) return NO;
  // NSNull is what a Dart null becomes on the method channel: a removal.
  id stored = nil;
  if (value != nil && value != [NSNull null]) {
    stored = NormalizedValue(value);
    if (stored == nil) return NO;
  }
  NSString *game = GameScopeKey(gameKey);
  @synchronized(self) {
    NSDictionary *document = [self documentForConsoleLocked:console];
    NSMutableDictionary *values = [ScopeValues(document, game) mutableCopy];
    if (stored != nil) {
      values[key] = stored;
    } else {
      [values removeObjectForKey:key];
    }
    NSDictionary *updated = DocumentReplacingScope(document, game, values);
    // The cached document only changes after a successful write: equal means already on disk.
    if ([updated isEqualToDictionary:document]) return YES;
    return [self writeDocumentLocked:updated console:console];
  }
}

- (void)resetConsole:(NSString *)console game:(NSString *)gameKey prefixes:(NSArray<NSString *> *)prefixes {
  if (!IsConsoleIdentifier(console)) return;
  NSString *game = GameScopeKey(gameKey);
  @synchronized(self) {
    NSDictionary *document = [self documentForConsoleLocked:console];
    NSDictionary *values = ScopeValues(document, game);
    NSMutableDictionary *kept = [NSMutableDictionary dictionary];
    for (NSString *key in values) {
      if (!KeyHasPrefix(key, prefixes)) kept[key] = values[key];
    }
    if (kept.count == values.count) return;
    [self writeDocumentLocked:DocumentReplacingScope(document, game, kept) console:console];
  }
}

- (void)forgetSkin:(NSString *)skinId {
  if (![skinId isKindOfClass:[NSString class]] || skinId.length == 0) return;
  @synchronized(self) {
    NSMutableSet<NSString *> *consoles = [NSMutableSet setWithArray:_documents.allKeys];
    NSArray<NSString *> *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:_directory error:nil];
    for (NSString *file in files) {
      if (![file.pathExtension isEqualToString:@"json"]) continue;
      NSString *console = file.stringByDeletingPathExtension;
      if (IsConsoleIdentifier(console)) [consoles addObject:console];
    }
    for (NSString *console in consoles) {
      NSDictionary *document = [self documentForConsoleLocked:console];
      NSDictionary *storedGames = document[kGamesScope];
      NSMutableDictionary *games = [NSMutableDictionary dictionary];
      for (NSString *game in storedGames) {
        NSDictionary *values = ValuesForgettingSkin(storedGames[game], skinId);
        if (values.count > 0) games[game] = values;
      }
      NSDictionary *updated = @{
        kConsoleScope : ValuesForgettingSkin(document[kConsoleScope], skinId),
        kGamesScope : [games copy],
      };
      if (![updated isEqualToDictionary:document]) [self writeDocumentLocked:updated console:console];
    }
  }
}

- (NSDictionary<NSString *, id> *)snapshotForConsole:(NSString *)console {
  if (!IsConsoleIdentifier(console)) return @{kConsoleScope : @{}, kGamesScope : @{}};
  @synchronized(self) {
    NSDictionary *document = [self documentForConsoleLocked:console];
    return @{kConsoleScope : document[kConsoleScope], kGamesScope : document[kGamesScope]};
  }
}

@end
