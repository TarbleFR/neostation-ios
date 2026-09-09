#import "Rpcs3DocumentPickerPlugin.h"

static NSString* const kRpcs3DocumentsChannel = @"neostation/rpcs3_documents";

@interface Rpcs3DocumentPickerPlugin ()
@property(nonatomic, strong) FlutterMethodChannel* channel;
@property(nonatomic, copy) FlutterResult pendingResult;
@property(nonatomic, assign) BOOL pickingFolder;
@property(nonatomic, strong) NSMutableArray<NSURL*>* activeURLs;
@property(nonatomic, strong) NSMutableSet<NSString*>* scopedPaths;
@end

@implementation Rpcs3DocumentPickerPlugin

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  FlutterMethodChannel* channel = [FlutterMethodChannel
      methodChannelWithName:kRpcs3DocumentsChannel
            binaryMessenger:registrar.messenger];
  Rpcs3DocumentPickerPlugin* instance = [Rpcs3DocumentPickerPlugin new];
  instance.channel = channel;
  instance.activeURLs = [NSMutableArray new];
  instance.scopedPaths = [NSMutableSet new];
  [registrar addMethodCallDelegate:instance channel:channel];
}

static UIViewController* RPCS3DocumentsRootController(void) {
  UIWindow* keyWindow = nil;
  for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:UIWindowScene.class] ||
        scene.activationState != UISceneActivationStateForegroundActive) {
      continue;
    }
    for (UIWindow* window in ((UIWindowScene*)scene).windows) {
      if (window.isKeyWindow) {
        keyWindow = window;
        break;
      }
    }
    if (keyWindow) break;
  }
  UIViewController* controller = keyWindow.rootViewController;
  while (controller.presentedViewController) {
    controller = controller.presentedViewController;
  }
  return controller;
}

- (void)releaseScopedResources {
  for (NSURL* url in self.activeURLs) {
    if ([self.scopedPaths containsObject:url.path]) {
      [url stopAccessingSecurityScopedResource];
    }
  }
  [self.activeURLs removeAllObjects];
  [self.scopedPaths removeAllObjects];
}

- (void)presentPickerForFolder:(BOOL)folder result:(FlutterResult)result {
  if (self.pendingResult != nil) {
    result([FlutterError errorWithCode:@"PICKER_BUSY"
                               message:@"Another RPCS3 document picker is already open."
                               details:nil]);
    return;
  }
  UIViewController* root = RPCS3DocumentsRootController();
  if (!root) {
    result([FlutterError errorWithCode:@"NO_ROOT_VC"
                               message:@"No view controller is available for the RPCS3 picker."
                               details:nil]);
    return;
  }

  [self releaseScopedResources];
  self.pendingResult = result;
  self.pickingFolder = folder;

  NSArray<NSString*>* types = folder ? @[@"public.folder"] : @[@"public.data"];
  UIDocumentPickerViewController* picker =
      [[UIDocumentPickerViewController alloc] initWithDocumentTypes:types
                                                             inMode:UIDocumentPickerModeOpen];
  picker.delegate = self;
  picker.allowsMultipleSelection = !folder;
  [root presentViewController:picker animated:YES completion:nil];
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  if ([call.method isEqualToString:@"pickGameFiles"]) {
    [self presentPickerForFolder:NO result:result];
    return;
  }
  if ([call.method isEqualToString:@"pickGameFolder"]) {
    [self presentPickerForFolder:YES result:result];
    return;
  }
  if ([call.method isEqualToString:@"releaseScopedResources"]) {
    [self releaseScopedResources];
    result(@YES);
    return;
  }
  result(FlutterMethodNotImplemented);
}

- (void)documentPicker:(UIDocumentPickerViewController*)controller
 didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls {
  FlutterResult callback = self.pendingResult;
  self.pendingResult = nil;
  if (!callback) return;
  if (urls.count == 0) {
    callback(nil);
    return;
  }

  NSMutableArray<NSString*>* paths = [NSMutableArray new];
  for (NSURL* url in urls) {
    BOOL scoped = [url startAccessingSecurityScopedResource];
    [self.activeURLs addObject:url];
    if (scoped) [self.scopedPaths addObject:url.path];
    if (url.path.length > 0) [paths addObject:url.path];
  }

  if (self.pickingFolder) {
    callback(paths.firstObject);
  } else {
    callback(paths);
  }
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController*)controller {
  FlutterResult callback = self.pendingResult;
  self.pendingResult = nil;
  if (callback) callback(nil);
}

- (void)dealloc {
  [self releaseScopedResources];
}

@end
