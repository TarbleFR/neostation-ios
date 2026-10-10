// Behavioural test of LibretroFrontendStore: game > console > NeoStation
// default resolution with the scope reported, persistence read back by a
// separate instance, value validation, "restore defaults" by prefix,
// forgetting a deleted skin everywhere, and the JSON file written on disk.
//
// The store keeps one shared instance per directory path, so a second
// instance reading the same files is obtained through a symbolic link (a
// different path to the same directory).
#import <Foundation/Foundation.h>

#import "LibretroFrontendStore.h"

#include <math.h>
#include <stdio.h>

static int failures = 0;

static void Report(BOOL passed, NSString *message, int line) {
  if (passed) {
    printf("PASS %s\n", message.UTF8String);
  } else {
    printf("FAIL %s (%s:%d)\n", message.UTF8String, __FILE__, line);
    failures++;
  }
}

#define CHECK(condition, ...) Report((condition) ? YES : NO, [NSString stringWithFormat:__VA_ARGS__], __LINE__)

static NSString *gWork;
static NSString *gDirectory;
static unsigned gLinks = 0;

/// A fresh store instance on the same directory, which reads the files again.
static LibretroFrontendStore *FreshStore(void) {
  NSString *link = [gWork stringByAppendingPathComponent:[NSString stringWithFormat:@"Link%u", ++gLinks]];
  [[NSFileManager defaultManager] createSymbolicLinkAtPath:link withDestinationPath:gDirectory error:nil];
  return [LibretroFrontendStore storeWithDirectory:link];
}

static NSDictionary *FileJSON(NSString *console) {
  NSString *path = [gDirectory stringByAppendingPathComponent:[console stringByAppendingString:@".json"]];
  NSData *data = [NSData dataWithContentsOfFile:path];
  if (data == nil) return nil;
  id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  return [json isKindOfClass:[NSDictionary class]] ? json : nil;
}

static void TestKeys(void) {
  CHECK([LibretroSettingSkinPortrait isEqualToString:@"skin.portrait"] &&
            [LibretroSettingSkinLandscape isEqualToString:@"skin.landscape"] &&
            [LibretroSettingScreenFormat isEqualToString:@"screenFormat"] &&
            [LibretroSettingArrangementPortrait isEqualToString:@"screenArrangement.portrait"] &&
            [LibretroSettingArrangementLandscape isEqualToString:@"screenArrangement.landscape"] &&
            [LibretroSettingScreensSwapped isEqualToString:@"screensSwapped"] &&
            [LibretroSettingShaderEnabled isEqualToString:@"shader.enabled"] &&
            [LibretroSettingShaderPreset isEqualToString:@"shader.preset"] &&
            [LibretroSettingShaderParameters isEqualToString:@"shader.parameters"] &&
            [LibretroSettingGamepad isEqualToString:@"controls.gamepad"] &&
            [LibretroSettingOpacity isEqualToString:@"controls.opacity"],
        @"setting keys documented in the header");
  CHECK([LibretroSettingTouchRemapKey(@"0123abcd") isEqualToString:@"controls.touch.0123abcd"] &&
            [LibretroSettingLayoutKey(@"0123abcd", @"portrait") isEqualToString:@"controls.layout.0123abcd.portrait"],
        @"per-skin keys");
}

static void TestResolution(LibretroFrontendStore *store) {
  LibretroSettingScope scope = LibretroSettingScopeGame;
  CHECK([store valueForKey:LibretroSettingScreenFormat console:@"psp" game:@"game-1" scope:&scope] == nil &&
            scope == LibretroSettingScopeDefault,
        @"nothing stored: NeoStation default (nil)");
  CHECK([store setValue:@"16:9" forKey:LibretroSettingScreenFormat console:@"psp" game:nil], @"console value stored");
  id value = [store valueForKey:LibretroSettingScreenFormat console:@"psp" game:nil scope:&scope];
  CHECK([value isEqual:@"16:9"] && scope == LibretroSettingScopeConsole, @"console value read for the console");
  value = [store valueForKey:LibretroSettingScreenFormat console:@"psp" game:@"game-1" scope:&scope];
  CHECK([value isEqual:@"16:9"] && scope == LibretroSettingScopeConsole,
        @"a game without its own value uses the console's");
  CHECK([store setValue:@"stretch" forKey:LibretroSettingScreenFormat console:@"psp" game:@"game-1"],
        @"game value stored");
  value = [store valueForKey:LibretroSettingScreenFormat console:@"psp" game:@"game-1" scope:&scope];
  CHECK([value isEqual:@"stretch"] && scope == LibretroSettingScopeGame, @"the game value wins over the console value");
  value = [store valueForKey:LibretroSettingScreenFormat console:@"psp" game:@"game-2" scope:&scope];
  CHECK([value isEqual:@"16:9"] && scope == LibretroSettingScopeConsole, @"another game keeps the console value");
  CHECK([store valueForKey:LibretroSettingScreenFormat console:@"psp" game:@"game-1" scope:NULL] != nil,
        @"the scope is optional");
  value = [store valueForKey:LibretroSettingScreenFormat console:@"nds" game:@"game-1" scope:&scope];
  CHECK(value == nil && scope == LibretroSettingScopeDefault, @"consoles do not share values");
  CHECK([[store storedValueForKey:LibretroSettingScreenFormat console:@"psp" game:nil] isEqual:@"16:9"] &&
            [[store storedValueForKey:LibretroSettingScreenFormat console:@"psp" game:@"game-1"] isEqual:@"stretch"] &&
            [store storedValueForKey:LibretroSettingScreenFormat console:@"psp" game:@"game-2"] == nil,
        @"stored values are read without fallback");

  CHECK([store setValue:nil forKey:LibretroSettingScreenFormat console:@"psp" game:@"game-1"], @"game value removed");
  value = [store valueForKey:LibretroSettingScreenFormat console:@"psp" game:@"game-1" scope:&scope];
  CHECK([value isEqual:@"16:9"] && scope == LibretroSettingScopeConsole, @"after removal the game falls back");
  NSDictionary *file = FileJSON(@"psp");
  CHECK(file != nil && [file[@"games"] count] == 0, @"an emptied game disappears from the file");

  // Literals with commas stay out of CHECK: macro arguments split on them.
  NSDictionary *parameters = @{@"CURVATURE" : @0.25, @"SCANLINES" : @1};
  NSArray *remap = @[ @"a", @"b" ];
  BOOL accepted = [store setValue:@YES forKey:LibretroSettingShaderEnabled console:@"psp" game:nil];
  accepted = [store setValue:@0.5 forKey:LibretroSettingOpacity console:@"psp" game:nil] && accepted;
  accepted = [store setValue:parameters forKey:LibretroSettingShaderParameters console:@"psp" game:nil] && accepted;
  accepted = [store setValue:@{@"buttonY" : @"menu"} forKey:LibretroSettingGamepad console:@"psp" game:nil] && accepted;
  accepted = [store setValue:remap forKey:LibretroSettingTouchRemapKey(@"abc") console:@"psp" game:nil] && accepted;
  CHECK(accepted, @"JSON values (BOOL, number, dictionary, array) are accepted");
  id enabled = [store valueForKey:LibretroSettingShaderEnabled console:@"psp" game:nil scope:NULL];
  id storedParameters = [store valueForKey:LibretroSettingShaderParameters console:@"psp" game:nil scope:NULL];
  id storedRemap = [store valueForKey:LibretroSettingTouchRemapKey(@"abc") console:@"psp" game:nil scope:NULL];
  CHECK([enabled isEqual:@YES] && [storedParameters isEqual:parameters] && [storedRemap isEqual:remap],
        @"JSON values read back unchanged");

  NSData *before = [NSData dataWithContentsOfFile:[gDirectory stringByAppendingPathComponent:@"psp.json"]];
  CHECK(![store setValue:[NSDate date] forKey:@"bad" console:@"psp" game:nil], @"a date is refused");
  CHECK(![store setValue:[NSData data] forKey:@"bad" console:@"psp" game:nil], @"raw data is refused");
  CHECK(![store setValue:@(NAN) forKey:@"bad" console:@"psp" game:nil], @"NaN is refused");
  NSDictionary *numericKeys = @{@1 : @"x"};
  CHECK(![store setValue:numericKeys forKey:@"bad" console:@"psp" game:nil],
        @"a dictionary with non-string keys is refused");
  CHECK(![store setValue:@[ [NSDate date] ] forKey:@"bad" console:@"psp" game:nil],
        @"a nested non-JSON value is refused");
  CHECK(![store setValue:@"x" forKey:@"" console:@"psp" game:nil], @"an empty key is refused");
  CHECK(![store setValue:@"x" forKey:@"key" console:@"../escape" game:nil] &&
            ![[NSFileManager defaultManager] fileExistsAtPath:[gWork stringByAppendingPathComponent:@"escape.json"]],
        @"a console id that is not a plain name is refused");
  NSData *after = [NSData dataWithContentsOfFile:[gDirectory stringByAppendingPathComponent:@"psp.json"]];
  CHECK([store valueForKey:@"bad" console:@"psp" game:nil scope:NULL] == nil && [before isEqualToData:after],
        @"refused values leave the store and the file unchanged");

  CHECK([store setValue:[NSNull null] forKey:LibretroSettingOpacity console:@"psp" game:nil] &&
            [store valueForKey:LibretroSettingOpacity console:@"psp" game:nil scope:NULL] == nil,
        @"NSNull (Dart null) removes the value");
  CHECK([store setValue:@"x" forKey:@"empty-game" console:@"psp" game:@""] &&
            [[store storedValueForKey:@"empty-game" console:@"psp" game:nil] isEqual:@"x"],
        @"an empty game key means the console scope");
  [store setValue:nil forKey:@"empty-game" console:@"psp" game:nil];
}

static void TestPersistence(LibretroFrontendStore *store) {
  [store setValue:@"original" forKey:LibretroSettingScreenFormat console:@"gba" game:nil];
  [store setValue:@"4:3" forKey:LibretroSettingScreenFormat console:@"gba" game:@"Golden Sun (Europe)"];
  LibretroFrontendStore *other = FreshStore();
  CHECK(other != store, @"a different path gives a separate instance");
  LibretroSettingScope scope = LibretroSettingScopeDefault;
  id value = [other valueForKey:LibretroSettingScreenFormat console:@"gba" game:@"Golden Sun (Europe)" scope:&scope];
  CHECK([value isEqual:@"4:3"] && scope == LibretroSettingScopeGame, @"game value persisted across instances");
  value = [other valueForKey:LibretroSettingScreenFormat console:@"gba" game:@"Other" scope:&scope];
  CHECK([value isEqual:@"original"] && scope == LibretroSettingScopeConsole,
        @"console value persisted across instances");
  NSDictionary *parameters = @{@"CURVATURE" : @0.25, @"SCANLINES" : @1};
  CHECK([[other valueForKey:LibretroSettingShaderParameters console:@"psp" game:nil scope:NULL] isEqual:parameters],
        @"structured values persisted across instances");
  CHECK([[other snapshotForConsole:@"gba"] isEqual:[store snapshotForConsole:@"gba"]],
        @"both instances see the same file");
  NSDictionary *snapshot = [store snapshotForConsole:@"gba"];
  CHECK([snapshot[@"console"] isEqual:@{@"screenFormat" : @"original"}] &&
            [snapshot[@"games"] isEqual:@{@"Golden Sun (Europe)" : @{@"screenFormat" : @"4:3"}}] &&
            snapshot.count == 2,
        @"snapshot is {console, games} as stored");
  NSDictionary *empty = [store snapshotForConsole:@"sg1000"];
  CHECK([empty[@"console"] count] == 0 && [empty[@"games"] count] == 0, @"snapshot of an unused console is empty");
  CHECK([LibretroFrontendStore storeWithDirectory:[gDirectory stringByAppendingString:@"/"]] == store &&
            [LibretroFrontendStore storeWithDirectory:gDirectory] == store,
        @"one shared instance per directory path");
  CHECK([store.directory isEqualToString:gDirectory.stringByStandardizingPath], @"directory property");
}

static void TestReset(LibretroFrontendStore *store) {
  NSString *console = @"snes";
  [store setValue:@YES forKey:LibretroSettingShaderEnabled console:console game:nil];
  [store setValue:@"crt-lottes-fast" forKey:LibretroSettingShaderPreset console:console game:nil];
  [store setValue:@{@"MASK" : @2} forKey:LibretroSettingShaderParameters console:console game:nil];
  [store setValue:@"16:9" forKey:LibretroSettingScreenFormat console:console game:nil];
  [store setValue:@"sharp-bilinear" forKey:LibretroSettingShaderPreset console:console game:@"g"];
  [store setValue:@"stretch" forKey:LibretroSettingScreenFormat console:console game:@"g"];
  [store resetConsole:console game:nil prefixes:@[ @"shader." ]];
  CHECK([store storedValueForKey:LibretroSettingShaderEnabled console:console game:nil] == nil &&
            [store storedValueForKey:LibretroSettingShaderPreset console:console game:nil] == nil &&
            [store storedValueForKey:LibretroSettingShaderParameters console:console game:nil] == nil,
        @"reset removes the keys with the prefix at the console scope");
  CHECK([[store storedValueForKey:LibretroSettingScreenFormat console:console game:nil] isEqual:@"16:9"],
        @"reset keeps the other console keys");
  CHECK([[store storedValueForKey:LibretroSettingShaderPreset console:console game:@"g"] isEqual:@"sharp-bilinear"],
        @"a console reset does not touch the games");
  [store resetConsole:console game:@"g" prefixes:nil];
  CHECK([store storedValueForKey:LibretroSettingShaderPreset console:console game:@"g"] == nil &&
            [store storedValueForKey:LibretroSettingScreenFormat console:console game:@"g"] == nil &&
            [[store storedValueForKey:LibretroSettingScreenFormat console:console game:nil] isEqual:@"16:9"],
        @"a game reset without prefixes removes every value of that game only");
  [store resetConsole:console game:nil prefixes:@[]];
  CHECK([[store storedValueForKey:LibretroSettingScreenFormat console:console game:nil] isEqual:@"16:9"],
        @"an empty prefix list removes nothing");
  LibretroFrontendStore *other = FreshStore();
  NSDictionary *snapshot = [other snapshotForConsole:console];
  CHECK([snapshot[@"console"] isEqual:@{@"screenFormat" : @"16:9"}] && [snapshot[@"games"] count] == 0,
        @"resets are written to the file");
}

static void TestForgetSkin(LibretroFrontendStore *store) {
  NSString *gone = @"abc";
  NSDictionary *layout = @{@"item0" : @{@"dx" : @0.125, @"dy" : @0, @"scale" : @1.5}};
  [store setValue:gone forKey:LibretroSettingSkinPortrait console:@"psx" game:nil];
  [store setValue:@"other" forKey:LibretroSettingSkinLandscape console:@"psx" game:nil];
  [store setValue:@{@"item1" : @[ @"a" ]} forKey:LibretroSettingTouchRemapKey(gone) console:@"psx" game:nil];
  [store setValue:layout forKey:LibretroSettingLayoutKey(gone, @"portrait") console:@"psx" game:nil];
  [store setValue:layout forKey:LibretroSettingLayoutKey(gone, @"landscape") console:@"psx" game:nil];
  [store setValue:layout forKey:LibretroSettingLayoutKey(@"abc-2", @"portrait") console:@"psx" game:nil];
  [store setValue:@{@"item1" : @[ @"b" ]} forKey:LibretroSettingTouchRemapKey(@"abc-2") console:@"psx" game:nil];
  [store setValue:layout forKey:LibretroSettingLayoutKey(@"abc.x", @"portrait") console:@"psx" game:nil];
  [store setValue:@"abc" forKey:@"note" console:@"psx" game:nil];
  [store setValue:gone forKey:LibretroSettingSkinLandscape console:@"psx" game:@"Crash"];
  [store setValue:@"16:9" forKey:LibretroSettingScreenFormat console:@"psx" game:@"Crash"];
  [store setValue:gone forKey:LibretroSettingSkinPortrait console:@"psx" game:@"Spyro"];
  // A console file this instance has never read: forgetSkin must find it on disk.
  LibretroFrontendStore *writer = FreshStore();
  [writer setValue:gone forKey:LibretroSettingSkinLandscape console:@"n64" game:nil];
  [writer setValue:@"keep" forKey:LibretroSettingSkinPortrait console:@"n64" game:nil];

  [store forgetSkin:gone];

  LibretroFrontendStore *reader = FreshStore();
  NSDictionary *psx = [reader snapshotForConsole:@"psx"];
  NSDictionary *console = psx[@"console"];
  CHECK(console[LibretroSettingSkinPortrait] == nil && [console[LibretroSettingSkinLandscape] isEqual:@"other"],
        @"forgetSkin removes the selections naming the skin only");
  CHECK(console[LibretroSettingTouchRemapKey(gone)] == nil &&
            console[LibretroSettingLayoutKey(gone, @"portrait")] == nil &&
            console[LibretroSettingLayoutKey(gone, @"landscape")] == nil,
        @"forgetSkin removes the skin's touch remaps and layouts");
  CHECK(console[LibretroSettingLayoutKey(@"abc-2", @"portrait")] != nil &&
            console[LibretroSettingTouchRemapKey(@"abc-2")] != nil &&
            console[LibretroSettingLayoutKey(@"abc.x", @"portrait")] != nil && [console[@"note"] isEqual:@"abc"],
        @"forgetSkin keeps other skins whose id starts with the same characters, and unrelated values");
  NSDictionary *games = psx[@"games"];
  CHECK([games[@"Crash"] isEqual:@{@"screenFormat" : @"16:9"}] && games[@"Spyro"] == nil,
        @"forgetSkin cleans every game and drops games left empty");
  NSDictionary *n64 = [reader snapshotForConsole:@"n64"][@"console"];
  CHECK(n64[LibretroSettingSkinLandscape] == nil && [n64[LibretroSettingSkinPortrait] isEqual:@"keep"],
        @"forgetSkin also cleans console files the instance had not loaded");
  CHECK([store valueForKey:LibretroSettingSkinLandscape console:@"psx" game:@"Crash" scope:NULL] != nil &&
            [[store valueForKey:LibretroSettingSkinLandscape console:@"psx" game:@"Crash" scope:NULL]
                isEqual:@"other"],
        @"after forgetSkin the game falls back to the console selection");
}

static void TestFileContent(LibretroFrontendStore *store) {
  [store setValue:@"stacked" forKey:LibretroSettingArrangementPortrait console:@"nds" game:nil];
  [store setValue:@YES forKey:LibretroSettingScreensSwapped console:@"nds" game:@"Mario Kart DS"];
  NSDictionary *file = FileJSON(@"nds");
  CHECK([file[@"version"] isEqual:@1], @"file carries version 1");
  CHECK([file[@"console"] isEqual:@{@"screenArrangement.portrait" : @"stacked"}], @"console values in the file");
  CHECK([file[@"games"] isEqual:@{@"Mario Kart DS" : @{@"screensSwapped" : @YES}}], @"game values in the file");
  NSArray<NSString *> *entries = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:gDirectory error:nil];
  BOOL onlyJSON = entries.count > 0;
  for (NSString *entry in entries) onlyJSON = onlyJSON && [entry.pathExtension isEqualToString:@"json"];
  CHECK(onlyJSON, @"atomic writes leave no temporary file next to the console files (%@)",
        [entries componentsJoinedByString:@", "]);

  dispatch_apply(32, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^(size_t index) {
    [store setValue:@(index) forKey:[NSString stringWithFormat:@"thread.%zu", index] console:@"gg" game:nil];
  });
  NSDictionary *gg = FileJSON(@"gg")[@"console"];
  BOOL all = gg.count == 32;
  for (size_t index = 0; index < 32; index++) {
    all = all && [gg[[NSString stringWithFormat:@"thread.%zu", index]] isEqual:@(index)];
  }
  CHECK(all, @"concurrent writers all reach the file");
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    NSString *base = argc > 1 ? @(argv[1]) : NSTemporaryDirectory();
    NSString *name = [NSString stringWithFormat:@"frontend-store-%@", [NSUUID UUID].UUIDString];
    gWork = [base stringByAppendingPathComponent:name];
    gDirectory = [gWork stringByAppendingPathComponent:@"Frontend"];
    [[NSFileManager defaultManager] createDirectoryAtPath:gWork
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    LibretroFrontendStore *store = [LibretroFrontendStore storeWithDirectory:gDirectory];
    TestKeys();
    TestResolution(store);
    TestPersistence(store);
    TestReset(store);
    TestForgetSkin(store);
    TestFileContent(store);
  }
  if (failures > 0) {
    printf("%d frontend store check(s) failed\n", failures);
    return 1;
  }
  printf("All frontend store checks passed\n");
  return 0;
}
