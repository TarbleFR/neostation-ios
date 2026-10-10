#import "LibretroOrientation.h"

#import <objc/runtime.h>

typedef UIInterfaceOrientationMask (*LibretroOrientationIMP)(id, SEL, UIApplication *, UIWindow *);

/// Mask requested by the libretro game on screen (0: the app's own). Main
/// thread only, like every UIKit orientation query.
static UIInterfaceOrientationMask gGameMask = 0;
/// Classes that already carry NeoStation's implementation (by name).
static NSMutableSet<NSString *> *gInstalledClasses;
/// Implementations installed by this file, to recognise them later.
static NSMutableSet<NSValue *> *gInstalledImplementations;
/// The application delegate kept alive while it is re-assigned.
static id gRetainedDelegate;
static BOOL gInstalled = NO;

static SEL LibretroOrientationSelector(void) {
  return @selector(application:supportedInterfaceOrientationsForWindow:);
}

static UIInterfaceOrientationMask LibretroMaskFromNames(id names) {
  if (![names isKindOfClass:[NSArray class]]) return 0;
  UIInterfaceOrientationMask mask = 0;
  for (id name in (NSArray *)names) {
    if (![name isKindOfClass:[NSString class]]) continue;
    if ([name isEqualToString:@"UIInterfaceOrientationPortrait"]) {
      mask |= UIInterfaceOrientationMaskPortrait;
    } else if ([name isEqualToString:@"UIInterfaceOrientationPortraitUpsideDown"]) {
      mask |= UIInterfaceOrientationMaskPortraitUpsideDown;
    } else if ([name isEqualToString:@"UIInterfaceOrientationLandscapeLeft"]) {
      mask |= UIInterfaceOrientationMaskLandscapeLeft;
    } else if ([name isEqualToString:@"UIInterfaceOrientationLandscapeRight"]) {
      mask |= UIInterfaceOrientationMaskLandscapeRight;
    }
  }
  return mask;
}

/// What the app supported before NeoStation's method existed: the
/// Info.plist orientations (the ~ipad key first on iPad), as UIKit reads
/// them when the delegate does not answer.
static UIInterfaceOrientationMask LibretroInfoPlistMask(void) {
  static UIInterfaceOrientationMask mask = 0;
  static BOOL resolved = NO;
  if (resolved) return mask;
  NSDictionary<NSString *, id> *info = NSBundle.mainBundle.infoDictionary;
  BOOL iPad = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad;
  UIInterfaceOrientationMask value = 0;
  if (iPad) value = LibretroMaskFromNames(info[@"UISupportedInterfaceOrientations~ipad"]);
  if (value == 0) value = LibretroMaskFromNames(info[@"UISupportedInterfaceOrientations"]);
  if (value == 0) value = iPad ? UIInterfaceOrientationMaskAll : UIInterfaceOrientationMaskAllButUpsideDown;
  mask = value;
  resolved = YES;
  return mask;
}

static void LibretroRememberImplementation(IMP implementation) {
  if (implementation == NULL) return;
  if (gInstalledImplementations == nil) gInstalledImplementations = [NSMutableSet set];
  [gInstalledImplementations addObject:[NSValue valueWithPointer:(const void *)implementation]];
}

static BOOL LibretroIsOurImplementation(IMP implementation) {
  if (implementation == NULL || gInstalledImplementations == nil) return NO;
  return [gInstalledImplementations containsObject:[NSValue valueWithPointer:(const void *)implementation]];
}

/// Gives `cls` NeoStation's application:supportedInterfaceOrientationsForWindow:.
/// - `cls` implements it itself: its implementation is wrapped (the game
///   mask wins, else the original answers);
/// - a superclass implements it: a method added to `cls` asks the
///   superclass's implementation when no game asks for more;
/// - nobody implements it: the added method answers the Info.plist mask.
/// Each wrapper captures its own original, so implementations that call
/// super never loop.
static BOOL LibretroInstallOnClass(Class cls) {
  if (cls == Nil) return NO;
  NSString *name = NSStringFromClass(cls);
  if (gInstalledClasses == nil) gInstalledClasses = [NSMutableSet set];
  if ([gInstalledClasses containsObject:name]) return YES;
  SEL selector = LibretroOrientationSelector();
  // "-[UIApplicationDelegate application:supportedInterfaceOrientationsForWindow:]":
  // returns NSUInteger, takes id self, SEL, id application, id window.
  const char *types = "Q@:@@";
  Method own = NULL;
  unsigned int count = 0;
  Method *methods = class_copyMethodList(cls, &count);
  for (unsigned int index = 0; index < count; index++) {
    if (method_getName(methods[index]) == selector) {
      own = methods[index];
      break;
    }
  }
  free(methods);

  IMP replacement = NULL;
  if (own != NULL) {
    LibretroOrientationIMP original = (LibretroOrientationIMP)method_getImplementation(own);
    if (LibretroIsOurImplementation((IMP)original)) {
      [gInstalledClasses addObject:name];
      return YES;
    }
    replacement = imp_implementationWithBlock(^UIInterfaceOrientationMask(id receiver, UIApplication *application,
                                                                          UIWindow *window) {
      UIInterfaceOrientationMask game = gGameMask;
      if (game != 0) return game;
      return original(receiver, selector, application, window);
    });
    method_setImplementation(own, replacement);
  } else {
    Method inherited = class_getInstanceMethod(cls, selector);
    LibretroOrientationIMP superImplementation =
        inherited != NULL ? (LibretroOrientationIMP)method_getImplementation(inherited) : NULL;
    if (superImplementation != NULL && LibretroIsOurImplementation((IMP)superImplementation)) {
      // A superclass already carries NeoStation's method.
      [gInstalledClasses addObject:name];
      return YES;
    }
    if (inherited != NULL && method_getTypeEncoding(inherited) != NULL) types = method_getTypeEncoding(inherited);
    replacement = imp_implementationWithBlock(^UIInterfaceOrientationMask(id receiver, UIApplication *application,
                                                                          UIWindow *window) {
      UIInterfaceOrientationMask game = gGameMask;
      if (game != 0) return game;
      if (superImplementation != NULL) return superImplementation(receiver, selector, application, window);
      return LibretroInfoPlistMask();
    });
    if (!class_addMethod(cls, selector, replacement, types)) {
      imp_removeBlock(replacement);
      return NO;
    }
  }
  LibretroRememberImplementation(replacement);
  [gInstalledClasses addObject:name];
  return YES;
}

/// Installed while the bridge framework loads, before UIApplicationMain
/// creates and assigns the application delegate (UIKit caches what the
/// delegate responds to at that moment). Flutter.framework is a dependency
/// of the bridge, so it is already loaded here.
@interface LibretroOrientationLoader : NSObject
@end

@implementation LibretroOrientationLoader

+ (void)load {
  Class flutterDelegate = NSClassFromString(@"FlutterAppDelegate");
  if (flutterDelegate != Nil && LibretroInstallOnClass(flutterDelegate)) gInstalled = YES;
}

@end

void LibretroOrientationInstall(void) {
  if (!NSThread.isMainThread) {
    dispatch_async(dispatch_get_main_queue(), ^{
      LibretroOrientationInstall();
    });
    return;
  }
  UIApplication *application = UIApplication.sharedApplication;
  id<UIApplicationDelegate> delegate = application.delegate;
  if (delegate == nil) return;
  Class cls = [(NSObject *)delegate class];
  SEL selector = LibretroOrientationSelector();
  IMP current = class_getMethodImplementation(cls, selector);
  BOOL answers = [(NSObject *)delegate respondsToSelector:selector];
  if (answers && LibretroIsOurImplementation(current)) {
    // Installed at +load on FlutterAppDelegate (or earlier here).
    gInstalled = YES;
    return;
  }
  if (!LibretroInstallOnClass(cls)) return;
  gInstalled = YES;
  // UIKit read the delegate's capabilities when it was assigned: assign it
  // again so the new method is seen. The strong reference keeps it alive
  // while the property is briefly nil.
  gRetainedDelegate = delegate;
  application.delegate = nil;
  application.delegate = gRetainedDelegate;
}

static void LibretroRefreshSupportedOrientations(void) {
  if (@available(iOS 16.0, *)) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
      if (![scene isKindOfClass:[UIWindowScene class]]) continue;
      for (UIWindow *window in ((UIWindowScene *)scene).windows) {
        UIViewController *root = window.rootViewController;
        if (root == nil) continue;
        [root setNeedsUpdateOfSupportedInterfaceOrientations];
        UIViewController *presented = root.presentedViewController;
        while (presented != nil) {
          [presented setNeedsUpdateOfSupportedInterfaceOrientations];
          presented = presented.presentedViewController;
        }
      }
    }
  }
}

void LibretroOrientationSetGameMask(UIInterfaceOrientationMask mask) {
  if (!NSThread.isMainThread) {
    dispatch_async(dispatch_get_main_queue(), ^{
      LibretroOrientationSetGameMask(mask);
    });
    return;
  }
  if (gGameMask == mask) return;
  gGameMask = mask;
  LibretroRefreshSupportedOrientations();
}

UIInterfaceOrientationMask LibretroOrientationGameMask(void) {
  return gGameMask;
}

BOOL LibretroOrientationIsInstalled(void) {
  return gInstalled;
}
