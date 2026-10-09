// Behavioural test of the skin parser (LibretroSkin): synthetic Delta,
// Manic and Provenance info.json files with tiny PNG / PDF images written
// into temporary skin directories. Covers DS two screens, a 3DS skin with
// a bogus bottom inputFrame and a HOME button, a portrait-only Manic PSP
// skin with per-button PDFs, impossible inputFrames, gameScreenFrame
// precedence, input shapes (array, single string, D-pad, thumbstick, touch
// screen), representation fallbacks, image fallbacks and every import error.
#import <Foundation/Foundation.h>

#import "LibretroInputMap.h"
#import "LibretroSkin.h"

#include <stdio.h>

static int failures = 0;
static NSString *workDirectory = nil;

static void Report(BOOL passed, NSString *message, int line) {
  if (passed) {
    printf("PASS %s\n", message.UTF8String);
  } else {
    printf("FAIL %s (%s:%d)\n", message.UTF8String, __FILE__, line);
    failures++;
  }
}

#define CHECK(condition, ...) Report((condition) ? YES : NO, [NSString stringWithFormat:__VA_ARGS__], __LINE__)

static BOOL RectNear(LibretroRect a, LibretroRect b) { return LibretroRectEqualToRect(a, b, 1e-6); }

static NSDictionary *Frame(double x, double y, double width, double height) {
  return @{@"x" : @(x), @"y" : @(y), @"width" : @(width), @"height" : @(height)};
}

static NSDictionary *Mapping(double width, double height) { return @{@"width" : @(width), @"height" : @(height)}; }

static NSDictionary *Edges(double top, double bottom, double left, double right) {
  return @{@"top" : @(top), @"bottom" : @(bottom), @"left" : @(left), @"right" : @(right)};
}

static NSData *PNGData(void) {
  static const uint8_t bytes[] = {0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49,
                                  0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06,
                                  0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89};
  return [NSData dataWithBytes:bytes length:sizeof(bytes)];
}

static NSData *PDFData(void) {
  return [@"%PDF-1.4\n1 0 obj\n<< /Type /Catalog >>\nendobj\ntrailer\n<< /Root 1 0 R >>\n%%EOF\n"
      dataUsingEncoding:NSUTF8StringEncoding];
}

static NSData *TextData(void) { return [@"not an image" dataUsingEncoding:NSUTF8StringEncoding]; }

/// Console geometry as the Dart catalog sends it.
static NSDictionary<NSString *, NSDictionary *> *Geometry(void) {
  return @{
    @"nds" : @{@"size" : @[ @256, @384 ], @"regions" : @{@"top" : @[ @0, @0, @1, @0.5 ], @"bottom" : @[ @0, @0.5, @1, @0.5 ]}},
    @"3ds" :
        @{@"size" : @[ @400, @480 ], @"regions" : @{@"top" : @[ @0, @0, @1, @0.5 ], @"bottom" : @[ @0.1, @0.5, @0.8, @0.5 ]}},
    @"psp" : @{@"size" : @[ @480, @272 ]},
    @"gba" : @{@"size" : @[ @240, @160 ]},
    @"snes" : @{@"size" : @[ @256, @224 ]},
    @"n64" : @{@"size" : @[ @320, @240 ]},
  };
}

/// Writes <work>/<name>/info.json (JSON object, or raw bytes) and `files`.
static NSString *WriteSkin(NSString *name, id info, NSDictionary<NSString *, NSData *> *files) {
  NSFileManager *manager = [NSFileManager defaultManager];
  NSString *directory = [workDirectory stringByAppendingPathComponent:name];
  [manager removeItemAtPath:directory error:nil];
  [manager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
  if (info != nil) {
    NSData *data = [info isKindOfClass:[NSData class]] ? info : [NSJSONSerialization dataWithJSONObject:info
                                                                                                options:0
                                                                                                  error:nil];
    [data writeToFile:[directory stringByAppendingPathComponent:@"info.json"] atomically:YES];
  }
  for (NSString *file in files) {
    NSString *path = [directory stringByAppendingPathComponent:file];
    [manager createDirectoryAtPath:path.stringByDeletingLastPathComponent
        withIntermediateDirectories:YES
                         attributes:nil
                              error:nil];
    [files[file] writeToFile:path atomically:YES];
  }
  return directory;
}

static NSMutableDictionary *Info(NSString *gameType, NSDictionary *representations) {
  return [@{
    @"name" : @"Test skin",
    @"identifier" : @"com.neostation.test",
    @"gameTypeIdentifier" : gameType,
    @"debug" : @NO,
    @"representations" : representations,
  } mutableCopy];
}

static NSDictionary *Phone(NSString *displayType, NSString *orientation, NSDictionary *representation) {
  return @{@"iphone" : @{displayType : @{orientation : representation}}};
}

static NSDictionary *Plain(double width, double height) { return @{@"mappingSize" : Mapping(width, height)}; }

static LibretroSkin *Parse(NSString *directory, NSString **code) {
  return [LibretroSkin skinWithDirectory:directory consoleGeometry:Geometry() errorCode:code];
}

/// Error code for a skin directory, "(parsed)" when it was accepted.
static NSString *ErrorFor(NSString *name, id info) {
  NSString *code = nil;
  LibretroSkin *skin = Parse(WriteSkin(name, info, @{}), &code);
  return skin == nil ? (code ?: @"(nil code)") : @"(parsed)";
}

static LibretroSkinItem *ItemNamed(LibretroSkinRepresentation *representation, NSString *identifier) {
  for (LibretroSkinItem *item in representation.items) {
    if ([item.identifier isEqualToString:identifier]) return item;
  }
  return nil;
}

static void TestIdentifiers(void) {
  CHECK(LibretroSkinIdentifierIsValid(@"0123456789abcdef") && LibretroSkinIdentifierIsValid(@"my-skin-2"),
        @"hex and dashed identifiers are valid");
  CHECK(!LibretroSkinIdentifierIsValid(@"") && !LibretroSkinIdentifierIsValid(@"Skin") &&
            !LibretroSkinIdentifierIsValid(@"a.b") && !LibretroSkinIdentifierIsValid(@"a/b") &&
            !LibretroSkinIdentifierIsValid(@"a_b") && !LibretroSkinIdentifierIsValid(@".."),
        @"empty, uppercase, dots, slashes and underscores are refused");
  CHECK(!LibretroSkinIdentifierIsValid([@"" stringByPaddingToLength:65 withString:@"a" startingAtIndex:0]),
        @"identifiers longer than 64 characters are refused");
  CHECK([LibretroSkinOrientationName(LibretroSkinOrientationPortrait) isEqualToString:@"portrait"] &&
            [LibretroSkinOrientationName(LibretroSkinOrientationLandscape) isEqualToString:@"landscape"],
        @"orientation names");
  CHECK([LibretroDefaultSkinIdentifier isEqualToString:@"default"], @"default skin identifier");
  CHECK([LibretroSkinErrorInfoMissing isEqualToString:@"SKIN_INFO_MISSING"] &&
            [LibretroSkinErrorNoPhoneOrTablet isEqualToString:@"SKIN_NO_DEVICE"] &&
            [LibretroSkinWarningNoTouchScreen isEqualToString:@"SKIN_WARN_TOUCHSCREEN_UNSUPPORTED"],
        @"error and warning codes match the header");
}

static void TestGameTypes(void) {
  NSDictionary<NSString *, NSArray<NSString *> *> *expected = @{
    @"com.rileytestut.delta.game.ds" : @[ @"nds" ],
    @"public.aoshuang.game.nds" : @[ @"nds" ],
    @"com.rileytestut.delta.game.gbc" : @[ @"gb", @"gbc" ],
    @"public.aoshuang.game.gb" : @[ @"gb", @"gbc" ],
    @"com.rileytestut.delta.game.gba" : @[ @"gba" ],
    @"com.rileytestut.delta.game.nes" : @[ @"nes" ],
    @"com.rileytestut.delta.game.snes" : @[ @"snes" ],
    @"com.rileytestut.delta.game.n64" : @[ @"n64" ],
    @"com.rileytestut.delta.game.genesis" : @[ @"md", @"mcd", @"32x" ],
    @"public.aoshuang.game.md" : @[ @"md", @"mcd", @"32x" ],
    @"public.aoshuang.game.32x" : @[ @"md", @"mcd", @"32x" ],
    @"org.provenance.Mega_Drive" : @[ @"md", @"mcd", @"32x" ],
    @"public.aoshuang.game.ms" : @[ @"sms" ],
    @"org.provenance.master-system" : @[ @"sms" ],
    @"public.aoshuang.game.gg" : @[ @"gg" ],
    @"public.aoshuang.game.sg1000" : @[ @"sg1000" ],
    @"org.provenance.SG-1000" : @[ @"sg1000" ],
    @"public.aoshuang.game.ps1" : @[ @"psx" ],
    @"com.rileytestut.delta.game.psx" : @[ @"psx" ],
    @"public.aoshuang.game.psp" : @[ @"psp" ],
    @"public.aoshuang.game.3ds" : @[ @"3ds" ],
    @"org.provenance.ThreeDS" : @[ @"3ds" ],
    @"public.aoshuang.game.arcade" : @[ @"arcade" ],
    @"org.provenance.fbneo" : @[ @"arcade" ],
    @"org.provenance.mame" : @[ @"arcade" ],
  };
  for (NSString *gameType in expected) {
    NSArray<NSString *> *consoles = [LibretroSkin consolesForGameTypeIdentifier:gameType];
    CHECK([consoles isEqualToArray:expected[gameType]], @"%@ -> %@ (got %@)", gameType,
          [expected[gameType] componentsJoinedByString:@","], [consoles componentsJoinedByString:@","]);
  }
  for (NSString *gameType in @[ @"public.aoshuang.game.dc", @"com.rileytestut.delta.game.wii", @"", @"..." ]) {
    CHECK([LibretroSkin consolesForGameTypeIdentifier:gameType].count == 0, @"'%@' is not supported", gameType);
  }
}

static void TestDualScreenDS(void) {
  NSDictionary *portrait = @{
    @"assets" : @{@"resizable" : @"bg.pdf"},
    @"mappingSize" : Mapping(414, 896),
    @"extendedEdges" : Edges(10, 10, 10, 10),
    @"items" : @[
      @{
        @"inputs" : @{@"up" : @"up", @"down" : @"down", @"left" : @"left", @"right" : @"right"},
        @"frame" : Frame(17, 651, 168, 168)
      },
      @{@"inputs" : @[ @"a" ], @"frame" : Frame(339, 706, 58, 58), @"extendedEdges" : @{@"left" : @0}},
      @{@"inputs" : @[ @"menu" ], @"frame" : Frame(186, 837, 42, 34)},
      @{@"inputs" : @[ @"toggleFastForward" ], @"frame" : Frame(31, 44, 352, 264), @"extendedEdges" : Edges(0, 0, 0, 0)},
      @{
        @"inputs" : @{@"x" : @"touchScreenX", @"y" : @"touchScreenY"},
        @"frame" : Frame(31, 325, 352, 264),
        @"extendedEdges" : @{@"top" : @10}
      },
    ],
    @"screens" : @[
      @{@"inputFrame" : Frame(0, 0, 256, 192), @"outputFrame" : Frame(31, 44, 352, 264)},
      @{@"inputFrame" : Frame(0, 192, 256, 192), @"outputFrame" : Frame(31, 325, 352, 264)},
    ],
  };
  NSDictionary *landscape = @{
    @"assets" : @{@"large" : @"landscape.png"},
    @"mappingSize" : Mapping(896, 414),
    @"translucent" : @YES,
    @"items" : @[],
    @"screens" : @[
      @{@"inputFrame" : Frame(0, 0, 256, 192), @"outputFrame" : Frame(40, 30, 400, 300)},
      @{@"inputFrame" : Frame(0, 192, 256, 192), @"outputFrame" : Frame(456, 30, 400, 300)},
    ],
  };
  NSDictionary *representations =
      @{@"iphone" : @{@"edgeToEdge" : @{@"portrait" : portrait}, @"standard" : @{@"landscape" : landscape}}};
  NSMutableDictionary *info = Info(@"com.rileytestut.delta.game.ds", representations);
  info[@"name"] = @"DS Test";
  info[@"identifier"] = @"com.test.ds";
  NSString *code = nil;
  LibretroSkin *skin =
      Parse(WriteSkin(@"ds-two-screens", info, @{@"bg.pdf" : PDFData(), @"landscape.png" : PNGData()}), &code);
  CHECK(skin != nil && code == nil, @"DS skin parsed (error %@)", code);
  if (skin == nil) return;
  CHECK([skin.installedIdentifier isEqualToString:@"ds-two-screens"], @"installed identifier is the directory name");
  CHECK([skin.identifier isEqualToString:@"com.test.ds"] && [skin.name isEqualToString:@"DS Test"],
        @"identifier and name from info.json");
  CHECK([skin.consoles isEqualToArray:@[ @"nds" ]] &&
            [skin.gameTypeIdentifier isEqualToString:@"com.rileytestut.delta.game.ds"],
        @"DS console and raw game type");
  CHECK(skin.warnings.count == 0, @"a complete DS skin has no warning (%@)", [skin.warnings componentsJoinedByString:@","]);
  CHECK(!skin.debug && skin.author == nil, @"debug off, no author");

  LibretroSkinRepresentation *rep = [skin representationForOrientation:LibretroSkinOrientationPortrait
                                                                  iPad:NO
                                                            edgeToEdge:YES];
  CHECK(rep != nil && [rep.device isEqualToString:@"iphone"] && [rep.displayType isEqualToString:@"edgeToEdge"],
        @"portrait iPhone edge-to-edge representation");
  CHECK(rep.mappingSize.w == 414 && rep.mappingSize.h == 896 && !rep.generated && !rep.translucent,
        @"mapping size, imported, opaque");
  CHECK([rep.backgroundPath hasSuffix:@"/ds-two-screens/bg.pdf"] && rep.backgroundPath.isAbsolutePath,
        @"background is the absolute path of the PDF");
  CHECK(rep.items.count == 5, @"five items (got %lu)", (unsigned long)rep.items.count);
  if (rep.items.count == 5) {
    LibretroSkinItem *dpad = rep.items[0];
    CHECK([dpad.identifier isEqualToString:@"item0"] && dpad.kind == LibretroSkinItemKindDPad &&
              [dpad.inputs isEqualToArray:(@[ @"up", @"down", @"left", @"right" ])],
          @"D-pad item with up, down, left, right");
    CHECK(RectNear(dpad.hitFrame, LibretroRectMake(7, 641, 188, 188)), @"D-pad hit frame grown by the default edges");
    LibretroSkinItem *a = rep.items[1];
    CHECK([a.identifier isEqualToString:@"item1"] && [a.inputs isEqualToArray:@[ @"a" ]], @"A button");
    CHECK(RectNear(a.hitFrame, LibretroRectMake(339, 696, 68, 78)), @"per-edge extendedEdges override only the left edge");
    CHECK([rep.items[2].inputs isEqualToArray:@[ @"menu" ]] && [rep.items[3].inputs isEqualToArray:@[ @"toggleFastForward" ]],
          @"menu and fast-forward actions kept");
    LibretroSkinItem *touch = rep.items[4];
    CHECK(touch.kind == LibretroSkinItemKindTouchScreen && [touch.inputs isEqualToArray:@[ @"touchScreen" ]],
          @"x / y object is the touch screen");
    CHECK(RectNear(touch.hitFrame, touch.frame), @"touch screen ignores extended edges");
    BOOL anyMovable = NO;
    for (LibretroSkinItem *item in rep.items) anyMovable = anyMovable || item.movable;
    CHECK(!anyMovable, @"controls painted in the background cannot move");
  }
  CHECK(rep.screens.count == 2, @"two DS screens");
  if (rep.screens.count == 2) {
    LibretroSkinScreen *top = rep.screens[0], *bottom = rep.screens[1];
    CHECK([top.role isEqualToString:@"top"] && RectNear(top.source, LibretroRectMake(0, 0, 1, 0.5)) && !top.touchScreen,
          @"DS top screen from the 256x384 inputFrame");
    CHECK([bottom.role isEqualToString:@"bottom"] && RectNear(bottom.source, LibretroRectMake(0, 0.5, 1, 0.5)) &&
              bottom.touchScreen,
          @"DS bottom screen is the touch screen");
    CHECK(top.hasOutputFrame && RectNear(top.outputFrame, LibretroRectMake(31, 44, 352, 264)) && !top.appPlacement,
          @"output frame in mapping units");
  }

  LibretroSkinRepresentation *wide = [skin representationForOrientation:LibretroSkinOrientationLandscape
                                                                   iPad:NO
                                                             edgeToEdge:YES];
  CHECK(wide != nil && [wide.displayType isEqualToString:@"standard"] && wide.translucent,
        @"landscape edge-to-edge falls back to standard");
  CHECK([wide.backgroundPath hasSuffix:@"/landscape.png"], @"landscape PNG background");
  LibretroSkinRepresentation *tablet = [skin representationForOrientation:LibretroSkinOrientationPortrait
                                                                     iPad:YES
                                                               edgeToEdge:NO];
  CHECK(tablet == rep, @"iPad without iPad layout uses the iPhone edge-to-edge one");
  NSDictionary *summary = [skin summary];
  CHECK([summary[@"identifier"] isEqual:@"com.test.ds"] && [summary[@"installedIdentifier"] isEqual:@"ds-two-screens"] &&
            [summary[@"name"] isEqual:@"DS Test"] && [summary[@"consoles"] isEqual:@[ @"nds" ]] &&
            [summary[@"debug"] isEqual:@NO] && summary[@"author"] == nil,
        @"summary fields");
  CHECK([summary[@"orientations"] isEqual:(@{@"iphone" : @[ @"portrait", @"landscape" ], @"ipad" : @[ @"portrait", @"landscape" ]})],
        @"summary orientations");
  CHECK([summary[@"gameTypeIdentifier"] isEqual:@"com.rileytestut.delta.game.ds"] &&
            [summary[@"warnings"] isEqual:@[]],
        @"summary game type and warnings");
}

static void TestThreeDS(void) {
  NSDictionary *stickInputs = @{
    @"up" : @"rightThumbstickUp",
    @"down" : @"rightThumbstickDown",
    @"left" : @"rightThumbstickLeft",
    @"right" : @"rightThumbstickRight"
  };
  NSDictionary *circlePad = @{
    @"up" : @"leftThumbstickUp",
    @"down" : @"leftThumbstickDown",
    @"left" : @"leftThumbstickLeft",
    @"right" : @"leftThumbstickRight"
  };
  NSDictionary *portrait = @{
    @"assets" : @{@"small" : @"bg.png", @"medium" : @"bg.png", @"large" : @"bg.png"},
    @"mappingSize" : Mapping(414, 896),
    @"extendedEdges" : Edges(7, 7, 7, 7),
    @"items" : @[
      @{
        @"thumbstick" : @{@"name" : @"thumbstick.pdf", @"width" : @70, @"height" : @70},
        @"frame" : Frame(235, 742, 82, 81),
        @"inputs" : stickInputs
      },
      @{@"asset" : @{@"normal" : @"Y.pdf"}, @"frame" : Frame(246, 614, 49, 49), @"inputs" : @[ @"y" ],
        @"extendedEdges" : Edges(10, 10, 10, 10)},
      @{@"asset" : @{@"normal" : @"home.pdf"}, @"frame" : Frame(165, 831, 85, 41), @"inputs" : @[ @"homeMenu" ]},
      @{@"frame" : Frame(47, 308, 320, 240), @"inputs" : @{@"x" : @"touchScreenX", @"y" : @"touchScreenY"},
        @"extendedEdges" : Edges(0, 0, 0, 0)},
      @{@"asset" : @{@"normal" : @"L.pdf"}, @"frame" : Frame(10, 600, 60, 30), @"inputs" : @[ @"l1" ]},
      @{@"frame" : Frame(344, 600, 60, 30), @"inputs" : @[ @"r2" ]},
      @{@"frame" : Frame(20, 700, 60, 60), @"inputs" : circlePad, @"thumbstick" : @{@"name" : @"thumbstick.pdf", @"width" : @60}},
    ],
    @"screens" : @[
      @{@"inputFrame" : Frame(0, 0, 400, 240), @"outputFrame" : Frame(3, 56, 408, 245)},
      @{@"inputFrame" : Frame(0, 192, 320, 240), @"outputFrame" : Frame(47, 308, 320, 240)},
    ],
  };
  // Landscape lists the touch screen first: roles follow the touch item,
  // never the order.
  NSDictionary *landscape = @{
    @"mappingSize" : Mapping(896, 414),
    @"items" : @[ @{@"frame" : Frame(641, 0, 209, 157), @"inputs" : @{@"x" : @"touchScreenX", @"y" : @"touchScreenY"}} ],
    @"screens" : @[
      @{@"inputFrame" : Frame(0, 192, 320, 240), @"outputFrame" : Frame(641, 0, 209, 157)},
      @{@"inputFrame" : Frame(0, 0, 400, 240), @"outputFrame" : Frame(52, 0, 589, 353)},
    ],
  };
  NSMutableDictionary *info =
      Info(@"com.rileytestut.delta.game.3ds",
           @{@"iphone" : @{@"edgeToEdge" : @{@"portrait" : portrait, @"landscape" : landscape}}});
  [info removeObjectForKey:@"debug"];
  info[@"hiddenLoadedFileName"] = @"ModernBlack.deltaskin";
  NSDictionary *files = @{
    @"bg.png" : PNGData(),
    @"thumbstick.pdf" : PDFData(),
    @"Y.pdf" : PDFData(),
    @"home.pdf" : PDFData(),
    @"L.pdf" : PDFData()
  };
  NSString *code = nil;
  LibretroSkin *skin = Parse(WriteSkin(@"modern-black", info, files), &code);
  CHECK(skin != nil, @"3DS skin parsed (error %@)", code);
  if (skin == nil) return;
  CHECK([skin.consoles isEqualToArray:@[ @"3ds" ]], @"3DS console");
  CHECK([skin.warnings containsObject:LibretroSkinWarningDebugMissing], @"missing debug is reported");
  CHECK([skin.warnings containsObject:LibretroSkinWarningUnknownInputs], @"HOME button reported as unsupported");
  CHECK([skin.warnings containsObject:LibretroSkinWarningInputFrameIgnored], @"bogus 3DS bottom inputFrame reported");
  CHECK(![skin.warnings containsObject:LibretroSkinWarningOrientationMissing] &&
            ![skin.warnings containsObject:LibretroSkinWarningAssetMissing],
        @"both orientations and every image present");

  LibretroSkinRepresentation *rep = [skin representationForOrientation:LibretroSkinOrientationPortrait
                                                                  iPad:NO
                                                            edgeToEdge:YES];
  CHECK([rep.backgroundPath hasSuffix:@"/bg.png"], @"bitmap background");
  CHECK(rep.screens.count == 2, @"two 3DS screens");
  if (rep.screens.count == 2) {
    CHECK([rep.screens[0].role isEqualToString:@"top"] && RectNear(rep.screens[0].source, LibretroRectMake(0, 0, 1, 0.5)) &&
              !rep.screens[0].touchScreen,
          @"3DS top screen from NeoStation's region");
    CHECK([rep.screens[1].role isEqualToString:@"bottom"] &&
              RectNear(rep.screens[1].source, LibretroRectMake(0.1, 0.5, 0.8, 0.5)) && rep.screens[1].touchScreen,
          @"3DS bottom screen: region of the catalog, not the bogus inputFrame");
  }
  LibretroSkinItem *stick = ItemNamed(rep, @"item0");
  CHECK(stick.kind == LibretroSkinItemKindThumbstick &&
            [stick.inputs isEqualToArray:(@[ @"rightStickUp", @"rightStickDown", @"rightStickLeft", @"rightStickRight" ])],
        @"C-stick thumbstick with canonical inputs");
  CHECK([stick.thumbstickAssetPath hasSuffix:@"/thumbstick.pdf"] && stick.thumbstickSize.w == 70 &&
            stick.thumbstickSize.h == 70 && !stick.movable,
        @"thumbstick knob image and size");
  CHECK(RectNear(stick.hitFrame, LibretroRectMake(228, 735, 96, 95)), @"thumbstick uses the representation edges");
  LibretroSkinItem *y = ItemNamed(rep, @"item1");
  CHECK([y.inputs isEqualToArray:@[ @"y" ]] && [y.assetPath hasSuffix:@"/Y.pdf"] && y.movable &&
            RectNear(y.assetFrame, y.frame) && RectNear(y.hitFrame, LibretroRectMake(236, 604, 69, 69)),
        @"Y button with its own PDF can move");
  LibretroSkinItem *home = ItemNamed(rep, @"item2");
  CHECK(home != nil && home.inputs.count == 0 && [home.unsupportedInputs isEqualToArray:@[ @"homeMenu" ]] &&
            home.assetPath != nil,
        @"HOME stays drawn but inert");
  LibretroSkinItem *touch = ItemNamed(rep, @"item3");
  CHECK(touch.kind == LibretroSkinItemKindTouchScreen && !touch.movable, @"3DS touch screen item");
  CHECK([ItemNamed(rep, @"item4").inputs isEqualToArray:@[ @"l" ]] && [ItemNamed(rep, @"item5").inputs isEqualToArray:@[ @"r2" ]],
        @"l1 -> l, r2 kept (ZR)");
  CHECK(!ItemNamed(rep, @"item5").movable, @"a control without its own image cannot move");
  LibretroSkinItem *pad = ItemNamed(rep, @"item6");
  CHECK(pad.kind == LibretroSkinItemKindDPad &&
            [pad.inputs isEqualToArray:(@[ @"leftStickUp", @"leftStickDown", @"leftStickLeft", @"leftStickRight" ])],
        @"thumbstick object without height is a D-pad");

  LibretroSkinRepresentation *wide = [skin representationForOrientation:LibretroSkinOrientationLandscape
                                                                   iPad:NO
                                                             edgeToEdge:YES];
  CHECK(wide.screens.count == 2, @"two landscape screens");
  if (wide.screens.count == 2) {
    CHECK([wide.screens[0].role isEqualToString:@"bottom"] && wide.screens[0].touchScreen &&
              RectNear(wide.screens[0].source, LibretroRectMake(0.1, 0.5, 0.8, 0.5)),
          @"the screen under the touch item is the bottom one, even listed first");
    CHECK([wide.screens[1].role isEqualToString:@"top"] && !wide.screens[1].touchScreen, @"the other is the top one");
  }
}

static void TestManicPSP(void) {
  NSDictionary *stick = @{
    @"up" : @"leftThumbstickUp",
    @"down" : @"leftThumbstickDown",
    @"left" : @"leftThumbstickLeft",
    @"right" : @"leftThumbstickRight"
  };
  NSDictionary *portrait = @{
    @"assets" : @{@"resizable" : @"iphone_edgetoedge_portrait.pdf"},
    @"items" : @[
      @{
        @"thumbstick" : @{@"name" : @"thumbstick.pdf", @"width" : @60, @"height" : @60},
        @"inputs" : stick,
        @"frame" : Frame(61, 715, 60, 60),
        @"extendedEdges" : Edges(0, 0, 0, 0)
      },
      @{@"asset" : @{@"normal" : @"up_button.pdf"}, @"extendedEdges" : Edges(10, 0, 20, 20),
        @"frame" : Frame(67, 537, 48, 60), @"inputs" : @[ @"up" ]},
      @{@"asset" : @{@"normal" : @"circle_button.pdf"}, @"frame" : Frame(305, 584, 56, 56), @"inputs" : @[ @"a" ]},
      @{@"asset" : @{@"normal" : @"cross_button.pdf"}, @"frame" : Frame(249, 640, 56, 56), @"inputs" : @[ @"cross" ]},
      @{@"asset" : @{@"normal" : @"l_button.pdf"}, @"frame" : Frame(9, 473, 96, 26), @"inputs" : @[ @"l1" ]},
      @{@"asset" : @{@"normal" : @"menu_button.pdf"}, @"frame" : Frame(174, 743, 24, 24), @"inputs" : @"menu"},
      @{@"asset" : @{@"name" : @"start.pdf", @"width" : @20, @"height" : @10}, @"frame" : Frame(300, 760, 40, 20),
        @"inputs" : @[ @"start", @"flex" ]},
    ],
    @"mappingSize" : Mapping(375, 812),
    @"screens" : @[ @{@"outputFrame" : Frame(8, 133, 359, 203)} ],
    @"translucent" : @NO,
  };
  NSMutableDictionary *info = Info(@"public.aoshuang.game.psp", Phone(@"edgeToEdge", @"portrait", portrait));
  NSMutableDictionary<NSString *, NSData *> *files = [NSMutableDictionary dictionary];
  for (NSString *name in @[ @"iphone_edgetoedge_portrait.pdf", @"thumbstick.pdf", @"up_button.pdf", @"circle_button.pdf",
                            @"cross_button.pdf", @"l_button.pdf", @"menu_button.pdf", @"start.pdf" ]) {
    files[name] = PDFData();
  }
  NSString *code = nil;
  LibretroSkin *skin = Parse(WriteSkin(@"manic-psp", info, files), &code);
  CHECK(skin != nil, @"Manic PSP skin parsed (error %@)", code);
  if (skin == nil) return;
  CHECK([skin.consoles isEqualToArray:@[ @"psp" ]], @"PSP console");
  NSSet *warnings = [NSSet setWithArray:skin.warnings];
  CHECK([warnings isEqualToSet:([NSSet setWithArray:@[ LibretroSkinWarningOrientationMissing, LibretroSkinWarningUnknownInputs ]])],
        @"portrait-only and Manic flex reported, nothing else (%@)", [skin.warnings componentsJoinedByString:@","]);
  CHECK([[skin orientationsForIPad:NO] isEqualToArray:@[ @"portrait" ]] &&
            [[skin orientationsForIPad:YES] isEqualToArray:@[ @"portrait" ]],
        @"portrait only, on iPhone and iPad");
  CHECK([skin representationForOrientation:LibretroSkinOrientationLandscape iPad:NO edgeToEdge:YES] == nil &&
            [skin representationForOrientation:LibretroSkinOrientationLandscape iPad:YES edgeToEdge:NO] == nil,
        @"no orientation fallback");
  LibretroSkinRepresentation *rep = [skin representationForOrientation:LibretroSkinOrientationPortrait
                                                                  iPad:NO
                                                            edgeToEdge:NO];
  CHECK([rep.displayType isEqualToString:@"edgeToEdge"], @"standard falls back to edge-to-edge");
  CHECK([rep.backgroundPath hasSuffix:@"/iphone_edgetoedge_portrait.pdf"], @"resizable PDF background");
  CHECK(rep.items.count == 7, @"seven items (got %lu)", (unsigned long)rep.items.count);
  LibretroSkinItem *thumbstick = ItemNamed(rep, @"item0");
  CHECK(thumbstick.kind == LibretroSkinItemKindThumbstick &&
            [thumbstick.inputs isEqualToArray:(@[ @"leftStickUp", @"leftStickDown", @"leftStickLeft", @"leftStickRight" ])] &&
            thumbstick.thumbstickSize.w == 60 && RectNear(thumbstick.hitFrame, thumbstick.frame),
        @"Manic thumbstick -> left stick");
  LibretroSkinItem *up = ItemNamed(rep, @"item1");
  CHECK([up.inputs isEqualToArray:@[ @"up" ]] && up.kind == LibretroSkinItemKindButton &&
            RectNear(up.hitFrame, LibretroRectMake(47, 527, 88, 70)),
        @"separate D-pad button with its own edges");
  CHECK([ItemNamed(rep, @"item2").inputs isEqualToArray:@[ @"a" ]] && [ItemNamed(rep, @"item3").inputs isEqualToArray:@[ @"b" ]],
        @"circle = a, cross = b");
  CHECK([ItemNamed(rep, @"item4").inputs isEqualToArray:@[ @"l" ]], @"l1 = l");
  LibretroSkinItem *menu = ItemNamed(rep, @"item5");
  CHECK([menu.inputs isEqualToArray:@[ @"menu" ]] && [menu.assetPath hasSuffix:@"/menu_button.pdf"] && menu.movable &&
            RectNear(menu.assetFrame, menu.frame),
        @"single-string input (Manic) and asset.normal PDF");
  LibretroSkinItem *start = ItemNamed(rep, @"item6");
  CHECK([start.inputs isEqualToArray:@[ @"start" ]] && [start.unsupportedInputs isEqualToArray:@[ @"flex" ]],
        @"unknown input kept in the report, item still works");
  CHECK([start.assetPath hasSuffix:@"/start.pdf"] && RectNear(start.assetFrame, LibretroRectMake(310, 765, 20, 10)),
        @"asset.name with its own size is centred on the frame");
  CHECK(rep.screens.count == 1 && [rep.screens[0].role isEqualToString:@"full"] &&
            RectNear(rep.screens[0].source, LibretroRectMake(0, 0, 1, 1)) && rep.screens[0].hasOutputFrame &&
            !rep.screens[0].touchScreen,
        @"one full screen without inputFrame");
}

static void TestInputFrames(void) {
  NSDictionary *psp = @{
    @"mappingSize" : Mapping(1179, 2556),
    @"screens" : @[ @{@"inputFrame" : Frame(0, 0, 1192, 887), @"outputFrame" : Frame(0, 300, 1179, 700)} ]
  };
  LibretroSkin *skin = Parse(
      WriteSkin(@"psp-impossible", Info(@"public.aoshuang.game.psp", Phone(@"edgeToEdge", @"portrait", psp)), @{}), NULL);
  LibretroSkinScreen *screen =
      [skin representationForOrientation:LibretroSkinOrientationPortrait iPad:NO edgeToEdge:YES].screens.firstObject;
  CHECK(screen != nil && RectNear(screen.source, LibretroRectMake(0, 0, 1, 1)) &&
            [skin.warnings containsObject:LibretroSkinWarningInputFrameIgnored],
        @"PSP inputFrame larger than 480x272 ignored with a warning");

  NSDictionary *gba = @{
    @"mappingSize" : Mapping(414, 896),
    @"screens" : @[ @{@"inputFrame" : Frame(0, 0, 120, 80), @"outputFrame" : Frame(0, 0, 414, 276)} ]
  };
  skin = Parse(WriteSkin(@"gba-crop", Info(@"com.rileytestut.delta.game.gba", Phone(@"edgeToEdge", @"portrait", gba)),
                         @{}),
               NULL);
  screen = [skin representationForOrientation:LibretroSkinOrientationPortrait iPad:NO edgeToEdge:YES].screens.firstObject;
  CHECK(RectNear(screen.source, LibretroRectMake(0, 0, 0.5, 0.5)) &&
            ![skin.warnings containsObject:LibretroSkinWarningInputFrameIgnored],
        @"inputFrame inside the GBA picture is normalized");

  NSDictionary *nes = @{
    @"mappingSize" : Mapping(414, 896),
    @"screens" : @[ @{@"inputFrame" : Frame(0, 8, 256, 224), @"outputFrame" : Frame(0, 0, 414, 300)} ]
  };
  skin = Parse(WriteSkin(@"nes-no-geometry",
                         Info(@"com.rileytestut.delta.game.nes", Phone(@"edgeToEdge", @"portrait", nes)), @{}),
               NULL);
  screen = [skin representationForOrientation:LibretroSkinOrientationPortrait iPad:NO edgeToEdge:YES].screens.firstObject;
  CHECK(RectNear(screen.source, LibretroRectMake(0, 0, 1, 1)) &&
            [skin.warnings containsObject:LibretroSkinWarningInputFrameIgnored],
        @"inputFrame of a console without known size is ignored");

  NSDictionary *legacy = @{
    @"mappingSize" : Mapping(414, 896),
    @"gameScreenFrame" : Frame(10, 20, 300, 200),
    @"screens" : @[
      @{@"inputFrame" : Frame(0, 0, 120, 80), @"outputFrame" : Frame(0, 0, 100, 100)},
      @{@"outputFrame" : Frame(0, 500, 100, 100)}
    ]
  };
  skin = Parse(WriteSkin(@"game-screen-frame",
                         Info(@"com.rileytestut.delta.game.gba", Phone(@"standard", @"portrait", legacy)), @{}),
               NULL);
  LibretroSkinRepresentation *rep = [skin representationForOrientation:LibretroSkinOrientationPortrait
                                                                  iPad:NO
                                                            edgeToEdge:NO];
  CHECK(rep.screens.count == 1 && RectNear(rep.screens[0].outputFrame, LibretroRectMake(10, 20, 300, 200)) &&
            RectNear(rep.screens[0].source, LibretroRectMake(0, 0, 1, 1)),
        @"gameScreenFrame wins over screens and shows the whole picture");

  NSDictionary *app = @{
    @"mappingSize" : Mapping(1024, 472),
    @"screens" : @[
      @{@"placement" : @"app", @"outputFrame" : Frame(0, 0, 1, 0.5), @"filters" : @[ @{@"name" : @"CIColorControls"} ]},
      @{@"placement" : @"app"}
    ]
  };
  skin = Parse(WriteSkin(@"app-placement",
                         Info(@"com.rileytestut.delta.game.snes", Phone(@"standard", @"landscape", app)), @{}),
               NULL);
  rep = [skin representationForOrientation:LibretroSkinOrientationLandscape iPad:NO edgeToEdge:NO];
  CHECK(rep.screens.count == 2 && rep.screens[0].appPlacement && rep.screens[0].hasOutputFrame &&
            RectNear(rep.screens[0].outputFrame, LibretroRectMake(0, 0, 1, 0.5)),
        @"placement app keeps a normalized output frame");
  CHECK(rep.screens.count == 2 && !rep.screens[1].hasOutputFrame && !rep.screens[1].appPlacement,
        @"a screen without outputFrame fits automatically");
  CHECK([skin.warnings containsObject:LibretroSkinWarningFiltersIgnored], @"screen filters reported");

  NSDictionary *bare = @{@"mappingSize" : Mapping(414, 896), @"items" : @[]};
  skin = Parse(WriteSkin(@"ds-no-screens", Info(@"com.rileytestut.delta.game.ds", Phone(@"edgeToEdge", @"portrait", bare)),
                         @{}),
               NULL);
  rep = [skin representationForOrientation:LibretroSkinOrientationPortrait iPad:NO edgeToEdge:YES];
  CHECK(rep.screens.count == 1 && [rep.screens[0].role isEqualToString:@"full"] && rep.screens[0].touchScreen &&
            !rep.screens[0].hasOutputFrame,
        @"DS skin without screens: the whole picture stays touchable");
  skin = Parse(WriteSkin(@"gba-no-screens",
                         Info(@"com.rileytestut.delta.game.gba", Phone(@"edgeToEdge", @"portrait", bare)), @{}),
               NULL);
  CHECK([skin representationForOrientation:LibretroSkinOrientationPortrait iPad:NO edgeToEdge:YES].screens.count == 0,
        @"other skins without screens leave the full screen to the layout");
}

static void TestItemsAndTouch(void) {
  NSDictionary *gba = @{
    @"mappingSize" : Mapping(320, 240),
    @"extendedEdges" : Edges(5, 5, 5, 5),
    @"items" : @[
      @{@"frame" : Frame(10, 10, 40, 40), @"inputs" : @{@"x" : @"touchScreenX", @"y" : @"touchScreenY"}},
      @{@"inputs" : @[ @"a" ]},
      @{@"frame" : Frame(500, 500, 40, 40), @"inputs" : @[ @"b" ]},
      @{@"frame" : Frame(300, 10, 40, 40), @"inputs" : @[ @"a", @"b", @"start", @"select", @"a" ]},
      @{@"frame" : Frame(10, 100, 40, 40), @"inputs" : @42},
      @{@"frame" : Frame(10, 150, 40, 40), @"inputs" : @[ @"x", @"cross" ]},
      @{@"frame" : Frame(60, 150, 40, 40), @"inputs" : @[ @"b" ], @"placement" : @"app"},
      @{@"frame" : Frame(100, 150, 40, 40), @"inputs" : @[ @"b" ], @"asset" : @{@"normal" : @"missing.pdf"}},
    ]
  };
  NSString *code = nil;
  LibretroSkin *skin = Parse(
      WriteSkin(@"gba-items", Info(@"com.rileytestut.delta.game.gba", Phone(@"standard", @"portrait", gba)), @{}), &code);
  CHECK(skin != nil, @"GBA items skin parsed (error %@)", code);
  LibretroSkinRepresentation *rep = [skin representationForOrientation:LibretroSkinOrientationPortrait
                                                                  iPad:NO
                                                            edgeToEdge:NO];
  CHECK([skin.warnings containsObject:LibretroSkinWarningNoTouchScreen] && ItemNamed(rep, @"item0") == nil,
        @"touch screen on a console without one: dropped with a warning");
  CHECK([skin.warnings containsObject:LibretroSkinWarningItemsDropped] && ItemNamed(rep, @"item1") == nil &&
            ItemNamed(rep, @"item2") == nil && ItemNamed(rep, @"item4") == nil && ItemNamed(rep, @"item6") == nil,
        @"items without frame, outside the mapping, with invalid inputs or app placement are dropped");
  LibretroSkinItem *combo = ItemNamed(rep, @"item3");
  CHECK([combo.inputs isEqualToArray:(@[ @"a", @"b", @"start", @"select" ])] && combo.unsupportedInputs.count == 0,
        @"combination button keeps every input once");
  LibretroSkinItem *refused = ItemNamed(rep, @"item5");
  CHECK(refused != nil && refused.inputs.count == 0 &&
            [refused.unsupportedInputs isEqualToArray:(@[ @"x", @"cross" ])],
        @"inputs the GBA does not have (x, PlayStation cross) are unsupported");
  LibretroSkinItem *broken = ItemNamed(rep, @"item7");
  CHECK(broken != nil && broken.assetPath == nil && !broken.movable &&
            [skin.warnings containsObject:LibretroSkinWarningAssetMissing],
        @"missing item image: drawn by the background only, warning");
  CHECK(rep.items.count == 3, @"three items kept (got %lu)", (unsigned long)rep.items.count);
}

static void TestRepresentationFallbacks(void) {
  NSDictionary *ipadOnly = @{@"ipad" : @{@"standard" : @{@"portrait" : Plain(1024, 1366)}}};
  LibretroSkin *skin = Parse(WriteSkin(@"ipad-only", Info(@"com.rileytestut.delta.game.gba", ipadOnly), @{}), NULL);
  CHECK(skin != nil && [skin orientationsForIPad:NO].count == 0 &&
            [[skin orientationsForIPad:YES] isEqualToArray:@[ @"portrait" ]],
        @"iPad-only skin: nothing on iPhone, portrait on iPad");
  CHECK([skin representationForOrientation:LibretroSkinOrientationPortrait iPad:NO edgeToEdge:YES] == nil &&
            [[skin representationForOrientation:LibretroSkinOrientationPortrait iPad:YES edgeToEdge:NO].device
                isEqualToString:@"ipad"],
        @"iPad layout never used on iPhone");

  NSDictionary *all = @{
    @"ipad" : @{@"standard" : @{@"portrait" : Plain(1024, 1366)}},
    @"iphone" : @{@"edgeToEdge" : @{@"portrait" : Plain(414, 896)}, @"standard" : @{@"portrait" : Plain(375, 667)}}
  };
  skin = Parse(WriteSkin(@"all-devices", Info(@"com.rileytestut.delta.game.gba", all), @{}), NULL);
  CHECK([skin representationForOrientation:LibretroSkinOrientationPortrait iPad:YES edgeToEdge:YES].mappingSize.w == 1024,
        @"iPad prefers ipad.standard, edge-to-edge ignored");
  CHECK([skin representationForOrientation:LibretroSkinOrientationPortrait iPad:NO edgeToEdge:YES].mappingSize.w == 414 &&
            [skin representationForOrientation:LibretroSkinOrientationPortrait iPad:NO edgeToEdge:NO].mappingSize.w == 375,
        @"iPhone picks its own display type first");

  NSDictionary *phones = @{
    @"iphone" : @{@"edgeToEdge" : @{@"portrait" : Plain(414, 896)}, @"standard" : @{@"portrait" : Plain(375, 667)}}
  };
  skin = Parse(WriteSkin(@"phones-on-ipad", Info(@"com.rileytestut.delta.game.gba", phones), @{}), NULL);
  CHECK([skin representationForOrientation:LibretroSkinOrientationPortrait iPad:YES edgeToEdge:NO].mappingSize.w == 414,
        @"iPad falls back to iPhone edge-to-edge, then standard");
  skin = Parse(WriteSkin(@"phone-standard", Info(@"com.rileytestut.delta.game.gba",
                                                 Phone(@"standard", @"portrait", Plain(375, 667))),
                         @{}),
               NULL);
  CHECK([skin representationForOrientation:LibretroSkinOrientationPortrait iPad:YES edgeToEdge:NO].mappingSize.w == 375 &&
            [skin representationForOrientation:LibretroSkinOrientationPortrait iPad:NO edgeToEdge:YES].mappingSize.w == 375,
        @"standard-only skin used on edge-to-edge iPhones and on iPad");

  NSDictionary *flat = @{@"iphone" : @{@"portrait" : Plain(375, 667), @"landscape" : Plain(667, 375)}};
  skin = Parse(WriteSkin(@"no-display-type", Info(@"com.rileytestut.delta.game.gba", flat), @{}), NULL);
  LibretroSkinRepresentation *rep = [skin representationForOrientation:LibretroSkinOrientationLandscape
                                                                  iPad:NO
                                                            edgeToEdge:YES];
  CHECK([rep.displayType isEqualToString:@"standard"] && rep.mappingSize.w == 667,
        @"a device without display-type level is standard");

  NSDictionary *extra = @{
    @"iphone" : @{@"splitView" : @{@"portrait" : Plain(320, 240)}, @"edgeToEdge" : @{@"landscape" : Plain(896, 414)}},
    @"tv" : @{@"standard" : @{@"landscape" : Plain(1920, 1080)}}
  };
  skin = Parse(WriteSkin(@"ignored-types", Info(@"com.rileytestut.delta.game.gba", extra), @{}), NULL);
  CHECK(skin.representations.count == 1 && [[skin orientationsForIPad:NO] isEqualToArray:@[ @"landscape" ]] &&
            [skin.warnings containsObject:LibretroSkinWarningOrientationMissing],
        @"splitView and tv ignored, missing portrait reported");
}

static void TestImages(void) {
  NSDictionary *files = @{@"s.png" : PNGData(), @"l.png" : PNGData(), @"pdf-named.png" : PDFData(),
                          @"garbage.png" : TextData(), @"sub/deep.png" : PNGData()};
  NSDictionary *(^assets)(NSDictionary *) = ^NSDictionary *(NSDictionary *names) {
    return @{@"assets" : names, @"mappingSize" : Mapping(375, 667)};
  };
  NSString *(^background)(NSString *, NSDictionary *, BOOL *) = ^NSString *(NSString *name, NSDictionary *names,
                                                                            BOOL *warned) {
    LibretroSkin *skin = Parse(WriteSkin(name, Info(@"com.rileytestut.delta.game.gba",
                                                    Phone(@"standard", @"portrait", assets(names))),
                                         files),
                               NULL);
    *warned = [skin.warnings containsObject:LibretroSkinWarningAssetMissing];
    return [skin representationForOrientation:LibretroSkinOrientationPortrait iPad:NO edgeToEdge:NO].backgroundPath;
  };
  BOOL warned = NO;
  NSString *path = background(@"typo-medium", @{@"small" : @"s.png", @"medium" : @"missing.png", @"large" : @"l.png"},
                              &warned);
  CHECK([path hasSuffix:@"/l.png"] && warned, @"missing medium: large used, warning");
  path = background(@"missing-pdf", @{@"resizable" : @"missing.pdf", @"small" : @"s.png"}, &warned);
  CHECK([path hasSuffix:@"/s.png"] && warned, @"missing resizable PDF: small PNG used, warning");
  path = background(@"pdf-content", @{@"large" : @"pdf-named.png"}, &warned);
  CHECK([path hasSuffix:@"/pdf-named.png"] && !warned, @"image type comes from the content, not the name");
  path = background(@"not-an-image", @{@"large" : @"garbage.png"}, &warned);
  CHECK(path == nil && warned, @"a file that is no image is missing");
  path = background(@"subfolder", @{@"large" : @"sub/deep.png"}, &warned);
  CHECK([path hasSuffix:@"/sub/deep.png"] && !warned, @"images in a sub-folder of the skin");

  [PNGData() writeToFile:[workDirectory stringByAppendingPathComponent:@"outside.png"] atomically:YES];
  path = background(@"traversal", @{@"large" : @"../outside.png"}, &warned);
  CHECK(path == nil && warned, @"'..' never leaves the skin directory");
  path = background(@"absolute", @{@"large" : [workDirectory stringByAppendingPathComponent:@"outside.png"]}, &warned);
  CHECK(path == nil && warned, @"absolute image paths are refused");
  path = background(@"macosx", @{@"large" : @"__MACOSX/._l.png"}, &warned);
  CHECK(path == nil && warned, @"__MACOSX entries are ignored");
  path = background(@"no-assets", @{}, &warned);
  CHECK(path == nil && !warned, @"a skin without images is valid (transparent controller)");
}

static void TestErrors(void) {
  NSDictionary *valid = Phone(@"edgeToEdge", @"portrait", Plain(414, 896));
  CHECK([ErrorFor(@"missing-info", nil) isEqualToString:LibretroSkinErrorInfoMissing], @"no info.json");
  CHECK([ErrorFor(@"broken-json", [@"{\"name\": " dataUsingEncoding:NSUTF8StringEncoding])
            isEqualToString:LibretroSkinErrorInfoInvalid],
        @"invalid JSON");
  CHECK([ErrorFor(@"array-json", [@"[1, 2]" dataUsingEncoding:NSUTF8StringEncoding]) isEqualToString:LibretroSkinErrorInfoInvalid],
        @"JSON that is not an object");

  NSMutableData *bom = [NSMutableData dataWithBytes:"\xEF\xBB\xBF" length:3];
  [bom appendData:[NSJSONSerialization dataWithJSONObject:Info(@"com.rileytestut.delta.game.gba", valid) options:0 error:nil]];
  CHECK([ErrorFor(@"with-bom", bom) isEqualToString:@"(parsed)"], @"UTF-8 BOM tolerated");
  NSString *crlf = @"{\r\n\"name\": \"CRLF\",\r\n\"identifier\": \"a.b\",\r\n\"gameTypeIdentifier\": "
                   @"\"com.rileytestut.delta.game.3ds\",\r\n\"debug\": false,\r\n\"representations\": {\"iphone\": "
                   @"{\"edgeToEdge\": {\"portrait\": {\"mappingSize\": {\"width\": 414, \"height\": 896}}}}}\r\n}\r\n";
  CHECK([ErrorFor(@"crlf", [crlf dataUsingEncoding:NSUTF8StringEncoding]) isEqualToString:@"(parsed)"],
        @"CRLF line endings");

  CHECK([ErrorFor(@"Bad_Name", Info(@"com.rileytestut.delta.game.gba", valid)) isEqualToString:LibretroSkinErrorInfoInvalid],
        @"directory name outside [a-z0-9-] refused");
  CHECK([ErrorFor(@"default", Info(@"com.rileytestut.delta.game.gba", valid)) isEqualToString:LibretroSkinErrorInfoInvalid],
        @"an imported skin cannot take the default skin's identifier");

  for (NSString *field in @[ @"name", @"identifier", @"gameTypeIdentifier", @"representations" ]) {
    NSMutableDictionary *info = Info(@"com.rileytestut.delta.game.gba", valid);
    [info removeObjectForKey:field];
    NSString *name = [@"missing-" stringByAppendingString:field.lowercaseString];
    CHECK([ErrorFor(name, info) isEqualToString:LibretroSkinErrorFieldMissing], @"missing %@", field);
  }
  NSMutableDictionary *info = Info(@"com.rileytestut.delta.game.gba", valid);
  info[@"name"] = @"   ";
  CHECK([ErrorFor(@"blank-name", info) isEqualToString:LibretroSkinErrorFieldMissing], @"blank name");
  info = Info(@"com.rileytestut.delta.game.gba", valid);
  info[@"representations"] = @[ valid ];
  CHECK([ErrorFor(@"array-representations", info) isEqualToString:LibretroSkinErrorFieldMissing],
        @"representations must be an object");
  info = Info(@"com.rileytestut.delta.game.gba", valid);
  info[@"identifier"] = @42;
  CHECK([ErrorFor(@"number-identifier", info) isEqualToString:LibretroSkinErrorFieldMissing], @"identifier must be text");

  CHECK([ErrorFor(@"dreamcast", Info(@"public.aoshuang.game.dc", valid)) isEqualToString:LibretroSkinErrorConsoleUnsupported],
        @"unknown console");
  CHECK([ErrorFor(@"no-representation", Info(@"com.rileytestut.delta.game.gba", @{})) isEqualToString:LibretroSkinErrorNoRepresentation],
        @"empty representations");
  CHECK([ErrorFor(@"no-mapping", Info(@"com.rileytestut.delta.game.gba",
                                      Phone(@"edgeToEdge", @"portrait", @{@"items" : @[]})))
            isEqualToString:LibretroSkinErrorNoRepresentation],
        @"representation without mappingSize is unusable");
  CHECK([ErrorFor(@"zero-mapping", Info(@"com.rileytestut.delta.game.gba",
                                        Phone(@"edgeToEdge", @"portrait", Plain(0, 896))))
            isEqualToString:LibretroSkinErrorNoRepresentation],
        @"zero mapping size is unusable");
  CHECK([ErrorFor(@"tv-only", Info(@"com.rileytestut.delta.game.gba", @{@"tv" : @{@"standard" : @{@"landscape" : Plain(1920, 1080)}}}))
            isEqualToString:LibretroSkinErrorNoPhoneOrTablet],
        @"a skin for Apple TV only has no iPhone or iPad layout");

  info = Info(@"com.rileytestut.delta.game.gba", valid);
  [info removeObjectForKey:@"debug"];
  NSString *code = nil;
  LibretroSkin *skin = Parse(WriteSkin(@"no-debug", info, @{}), &code);
  CHECK(skin != nil && !skin.debug && [skin.warnings containsObject:LibretroSkinWarningDebugMissing],
        @"missing debug accepted as off with a warning");
  info[@"debug"] = @YES;
  skin = Parse(WriteSkin(@"debug-on", info, @{}), &code);
  CHECK(skin.debug && ![skin.warnings containsObject:LibretroSkinWarningDebugMissing], @"debug read");
}

static void TestAuthor(void) {
  NSData *metadata = [NSJSONSerialization dataWithJSONObject:@{@"author" : @"Jane Doe", @"license" : @"GPL-3.0"}
                                                     options:0
                                                       error:nil];
  LibretroSkin *skin = Parse(WriteSkin(@"with-author",
                                       Info(@"com.rileytestut.delta.game.gba",
                                            Phone(@"edgeToEdge", @"portrait", Plain(414, 896))),
                                       @{@"neostation-skin.json" : metadata}),
                             NULL);
  CHECK([skin.author isEqualToString:@"Jane Doe"] && [[skin summary][@"author"] isEqual:@"Jane Doe"],
        @"author recorded at import is shown");
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    workDirectory = argc > 1 ? @(argv[1]) : NSTemporaryDirectory();
    workDirectory = [workDirectory stringByAppendingPathComponent:@"skins"];
    [[NSFileManager defaultManager] createDirectoryAtPath:workDirectory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    TestIdentifiers();
    TestGameTypes();
    TestDualScreenDS();
    TestThreeDS();
    TestManicPSP();
    TestInputFrames();
    TestItemsAndTouch();
    TestRepresentationFallbacks();
    TestImages();
    TestErrors();
    TestAuthor();
    // The input map behind the canonical names (sanity: 3DS HOME refused).
    CHECK([[LibretroInputMap mapForConsole:@"3ds"] canonicalInput:@"homeMenu"] == nil, @"3DS HOME has no target");
  }
  printf("%s: %d failure(s)\n", failures == 0 ? "skin_test passed" : "skin_test FAILED", failures);
  return failures == 0 ? 0 : 1;
}
