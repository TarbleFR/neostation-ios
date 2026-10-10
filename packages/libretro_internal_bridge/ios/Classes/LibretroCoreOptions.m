#import "LibretroCoreOptions.h"

@interface LibretroCoreOption ()
@property(nonatomic, copy, readwrite) NSString *key;
@property(nonatomic, copy, readwrite) NSString *coreDescription;
@property(nonatomic, copy, readwrite) NSArray<NSString *> *values;
@property(nonatomic, copy, readwrite) NSArray<NSString *> *valueLabels;
@property(nonatomic, copy, readwrite) NSString *defaultValue;
@end

@implementation LibretroCoreOption
@end

static NSString *StringOrEmpty(const char *value) {
  if (value == NULL) return @"";
  NSString *string = [NSString stringWithUTF8String:value];
  return string ?: @"";
}

@implementation LibretroCoreOptions {
  NSString *_storePath;
  NSMutableArray<LibretroCoreOption *> *_options;
  NSMutableDictionary<NSString *, NSString *> *_stored;
  NSMutableDictionary<NSString *, NSString *> *_overrides;
  NSMutableDictionary<NSString *, NSString *> *_defaults;
  NSMutableSet<NSString *> *_locked;
  NSMutableDictionary<NSString *, NSData *> *_cStrings;
  BOOL _updatePending;
}

- (instancetype)initWithStorePath:(NSString *)storePath {
  self = [super init];
  if (self) {
    _storePath = [storePath copy];
    _options = [NSMutableArray array];
    _overrides = [NSMutableDictionary dictionary];
    _defaults = [NSMutableDictionary dictionary];
    _locked = [NSMutableSet set];
    _cStrings = [NSMutableDictionary dictionary];
    _stored = [NSMutableDictionary dictionary];
    NSData *data = [NSData dataWithContentsOfFile:storePath];
    if (data != nil) {
      id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
      NSDictionary *values = [json isKindOfClass:[NSDictionary class]] ? json[@"values"] : nil;
      if ([values isKindOfClass:[NSDictionary class]]) {
        for (id key in values) {
          id value = values[key];
          if ([key isKindOfClass:[NSString class]] && [value isKindOfClass:[NSString class]]) {
            _stored[key] = value;
          }
        }
      }
    }
  }
  return self;
}

- (NSArray<LibretroCoreOption *> *)options {
  @synchronized(self) {
    return [_options copy];
  }
}

- (BOOL)updatePending {
  @synchronized(self) {
    return _updatePending;
  }
}

/// Merges `values` into `target` (session overrides or NeoStation defaults).
/// Values given before the core declares its options are kept and resolved
/// once declared. Only keys whose effective value changes lose their cached
/// C string, and a change of a declared option is flagged for the core.
- (void)mergeValuesLocked:(NSDictionary<NSString *, NSString *> *)values
                     into:(NSMutableDictionary<NSString *, NSString *> *)target
                   locked:(BOOL)locked {
  for (id key in values) {
    id value = values[key];
    if (![key isKindOfClass:[NSString class]] || ![value isKindOfClass:[NSString class]]) continue;
    NSString *previous = [self effectiveValueLocked:key];
    target[key] = value;
    if (locked) [_locked addObject:key];
    NSString *current = [self effectiveValueLocked:key];
    if (current == previous || [current isEqualToString:previous]) continue;
    [_cStrings removeObjectForKey:key];
    if ([self optionForKeyLocked:key] != nil) _updatePending = YES;
  }
}

- (void)applySessionOverrides:(NSDictionary<NSString *, NSString *> *)overrides {
  @synchronized(self) {
    [self mergeValuesLocked:overrides into:_overrides locked:NO];
  }
}

- (void)lockSessionOverrides:(NSDictionary<NSString *, NSString *> *)overrides {
  @synchronized(self) {
    [self mergeValuesLocked:overrides into:_overrides locked:YES];
  }
}

- (void)applyDefaults:(NSDictionary<NSString *, NSString *> *)defaults {
  @synchronized(self) {
    [self mergeValuesLocked:defaults into:_defaults locked:NO];
  }
}

- (BOOL)isLockedKey:(NSString *)key {
  @synchronized(self) {
    return [_locked containsObject:key];
  }
}

- (LibretroCoreOption *)optionForKeyLocked:(NSString *)key {
  for (LibretroCoreOption *option in _options) {
    if ([option.key isEqualToString:key]) return option;
  }
  return nil;
}

- (void)addOptionLocked:(LibretroCoreOption *)option {
  LibretroCoreOption *existing = [self optionForKeyLocked:option.key];
  if (existing != nil) [_options removeObject:existing];
  [_options addObject:option];
  [_cStrings removeObjectForKey:option.key];
}

- (BOOL)declareVariables:(const struct retro_variable *)variables {
  if (variables == NULL) return NO;
  @synchronized(self) {
    for (const struct retro_variable *variable = variables; variable->key != NULL; variable++) {
      NSString *key = StringOrEmpty(variable->key);
      NSString *spec = StringOrEmpty(variable->value);
      NSRange separator = [spec rangeOfString:@"; "];
      NSString *description = separator.location == NSNotFound ? spec : [spec substringToIndex:separator.location];
      NSString *list = separator.location == NSNotFound ? @"" : [spec substringFromIndex:NSMaxRange(separator)];
      NSArray<NSString *> *values = list.length > 0 ? [list componentsSeparatedByString:@"|"] : @[];
      if (key.length == 0 || values.count == 0) continue;
      LibretroCoreOption *option = [LibretroCoreOption new];
      option.key = key;
      option.coreDescription = description;
      option.values = values;
      option.valueLabels = values;
      option.defaultValue = values.firstObject;
      option.visible = YES;
      [self addOptionLocked:option];
    }
  }
  return YES;
}

static LibretroCoreOption *OptionFromValues(NSString *key, const char *desc, const struct retro_core_option_value *values,
                                            const char *defaultValue, const struct retro_core_option_value *localValues,
                                            const char *localDesc) {
  NSMutableArray<NSString *> *names = [NSMutableArray array];
  NSMutableArray<NSString *> *labels = [NSMutableArray array];
  for (unsigned i = 0; i < RETRO_NUM_CORE_OPTION_VALUES_MAX && values[i].value != NULL; i++) {
    NSString *value = StringOrEmpty(values[i].value);
    NSString *label = values[i].label != NULL ? StringOrEmpty(values[i].label) : value;
    if (localValues != NULL) {
      for (unsigned j = 0; j < RETRO_NUM_CORE_OPTION_VALUES_MAX && localValues[j].value != NULL; j++) {
        if (strcmp(localValues[j].value, values[i].value) == 0 && localValues[j].label != NULL) {
          label = StringOrEmpty(localValues[j].label);
          break;
        }
      }
    }
    [names addObject:value];
    [labels addObject:label];
  }
  if (names.count == 0) return nil;
  LibretroCoreOption *option = [LibretroCoreOption new];
  option.key = key;
  option.coreDescription = StringOrEmpty(localDesc != NULL ? localDesc : desc);
  option.values = names;
  option.valueLabels = labels;
  NSString *fallback = defaultValue != NULL ? StringOrEmpty(defaultValue) : names.firstObject;
  option.defaultValue = [names containsObject:fallback] ? fallback : names.firstObject;
  option.visible = YES;
  return option;
}

- (BOOL)declareDefinitions:(const struct retro_core_option_definition *)definitions
                     local:(const struct retro_core_option_definition *)local {
  if (definitions == NULL) return NO;
  @synchronized(self) {
    for (const struct retro_core_option_definition *definition = definitions; definition->key != NULL; definition++) {
      const struct retro_core_option_definition *translated = NULL;
      for (const struct retro_core_option_definition *candidate = local; candidate != NULL && candidate->key != NULL;
           candidate++) {
        if (strcmp(candidate->key, definition->key) == 0) {
          translated = candidate;
          break;
        }
      }
      LibretroCoreOption *option =
          OptionFromValues(StringOrEmpty(definition->key), definition->desc, definition->values,
                           definition->default_value, translated ? translated->values : NULL,
                           translated ? translated->desc : NULL);
      if (option != nil) [self addOptionLocked:option];
    }
  }
  return YES;
}

- (BOOL)declareV2:(const struct retro_core_options_v2 *)options local:(const struct retro_core_options_v2 *)local {
  if (options == NULL || options->definitions == NULL) return NO;
  @synchronized(self) {
    for (const struct retro_core_option_v2_definition *definition = options->definitions; definition->key != NULL;
         definition++) {
      const struct retro_core_option_v2_definition *translated = NULL;
      if (local != NULL && local->definitions != NULL) {
        for (const struct retro_core_option_v2_definition *candidate = local->definitions; candidate->key != NULL;
             candidate++) {
          if (strcmp(candidate->key, definition->key) == 0) {
            translated = candidate;
            break;
          }
        }
      }
      LibretroCoreOption *option =
          OptionFromValues(StringOrEmpty(definition->key), definition->desc, definition->values,
                           definition->default_value, translated ? translated->values : NULL,
                           translated ? translated->desc : NULL);
      if (option != nil) [self addOptionLocked:option];
    }
  }
  return YES;
}

- (void)setDisplay:(const struct retro_core_option_display *)display {
  if (display == NULL || display->key == NULL) return;
  @synchronized(self) {
    LibretroCoreOption *option = [self optionForKeyLocked:StringOrEmpty(display->key)];
    option.visible = display->visible;
  }
}

- (NSString *)effectiveValueLocked:(NSString *)key {
  LibretroCoreOption *option = [self optionForKeyLocked:key];
  NSString *override = _overrides[key];
  NSString *stored = _stored[key];
  NSString *fallback = _defaults[key];
  if (option == nil) return override ?: (stored ?: fallback);
  if (override != nil && [option.values containsObject:override]) return override;
  if (stored != nil && [option.values containsObject:stored]) return stored;
  if (fallback != nil && [option.values containsObject:fallback]) return fallback;
  return option.defaultValue;
}

- (const char *)valueForKey:(const char *)key {
  if (key == NULL) return NULL;
  @synchronized(self) {
    NSString *name = StringOrEmpty(key);
    NSData *cached = _cStrings[name];
    if (cached != nil) return cached.bytes;
    NSString *value = [self effectiveValueLocked:name];
    if (value == nil) return NULL;
    const char *utf8 = value.UTF8String;
    NSData *storage = [NSData dataWithBytes:utf8 length:strlen(utf8) + 1];
    _cStrings[name] = storage;
    return storage.bytes;
  }
}

- (BOOL)setValue:(NSString *)value forKey:(NSString *)key persist:(BOOL)persist {
  @synchronized(self) {
    // NeoStation needs these values for the whole session (DS / 3DS screens).
    if ([_locked containsObject:key]) return NO;
    LibretroCoreOption *option = [self optionForKeyLocked:key];
    if (option != nil && ![option.values containsObject:value]) return NO;
    NSString *previous = [self effectiveValueLocked:key];
    [_overrides removeObjectForKey:key];
    _stored[key] = value;
    [_cStrings removeObjectForKey:key];
    if (![previous isEqualToString:value]) _updatePending = YES;
  }
  if (persist) [self save];
  return YES;
}

- (BOOL)consumeUpdate {
  @synchronized(self) {
    BOOL pending = _updatePending;
    _updatePending = NO;
    return pending;
  }
}

- (void)save {
  NSDictionary *snapshot;
  @synchronized(self) {
    snapshot = @{@"values" : [_stored copy]};
  }
  NSData *data = [NSJSONSerialization dataWithJSONObject:snapshot options:NSJSONWritingPrettyPrinted error:nil];
  if (data == nil) return;
  [[NSFileManager defaultManager] createDirectoryAtPath:[_storePath stringByDeletingLastPathComponent]
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
  [data writeToFile:_storePath atomically:YES];
}

@end
