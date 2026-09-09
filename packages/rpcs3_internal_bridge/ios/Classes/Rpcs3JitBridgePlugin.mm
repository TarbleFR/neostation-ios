#import "Rpcs3JitBridgePlugin.h"

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <poll.h>
#import <stdio.h>
#import <arpa/inet.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <sys/types.h>
#import <unistd.h>

static NSString* const kRpcs3JitChannel = @"neostation/rpcs3_jit";
static NSString* const kRpcs3JitRequestType = @"com.neogamelab.neostation.rpcs3-jit-request";
static NSTimeInterval const kRpcs3HelperConnectTimeout = 30.0;
// First use may download and mount a DDI. Dart allows this native deadline
// (plus the connection deadline) to finish and report its actual error.
static NSTimeInterval const kRpcs3AttachTimeout = 600.0;
static NSTimeInterval const kRpcs3CompletionTimeout = 120.0;

extern "C" {
void* SecTaskCreateFromSelf(CFAllocatorRef allocator);
CFTypeRef SecTaskCopyValueForEntitlement(
    void* task,
    CFStringRef entitlement,
    CFErrorRef* error);
int csops(pid_t pid, unsigned int ops, void* useraddr, size_t usersize);
}

#ifndef CS_OPS_STATUS
#define CS_OPS_STATUS 0
#endif
#ifndef CS_DEBUGGED
#define CS_DEBUGGED 0x10000000
#endif

static BOOL RPCS3HostHasGetTaskAllow(void) {
  void* task = SecTaskCreateFromSelf(NULL);
  if (task == NULL) return NO;
  CFTypeRef value = SecTaskCopyValueForEntitlement(
      task,
      CFSTR("get-task-allow"),
      NULL);
  BOOL allowed = value == kCFBooleanTrue;
  if (value != NULL) CFRelease(value);
  CFRelease(task);
  return allowed;
}

static BOOL RPCS3HostIsDebugged(void) {
  uint32_t flags = 0;
  if (csops(getpid(), CS_OPS_STATUS, &flags, sizeof(flags)) != 0) return NO;
  return (flags & CS_DEBUGGED) != 0;
}

static BOOL RPCS3RequiresCoreHandshake(void) {
  if (@available(iOS 26.0, *)) return YES;
  return NO;
}

@interface RPCS3JitSession : NSObject
@property(nonatomic, readonly) uint16_t port;
@property(nonatomic, readonly) NSString* token;
@property(nonatomic, readonly) BOOL connected;
@property(nonatomic, readonly) BOOL attached;
@property(nonatomic, readonly) BOOL finished;
@property(nonatomic, readonly) BOOL success;
@property(nonatomic, readonly) NSString* finalMessage;
@property(nonatomic, readonly) NSArray<NSString*>* logs;
@property(nonatomic, readonly) BOOL closed;
@property(nonatomic, assign) BOOL requiresCoreHandshake;
@property(nonatomic, strong, nullable) id extensionObject;
@property(nonatomic, strong, nullable) id requestIdentifier;
- (nullable instancetype)initWithError:(NSError**)error;
- (void)startReader;
- (BOOL)waitUntilConnected:(NSTimeInterval)timeout;
- (BOOL)waitUntilAttached:(NSTimeInterval)timeout;
- (BOOL)waitUntilFinished:(NSTimeInterval)timeout;
- (void)close;
@end

@implementation RPCS3JitSession {
  int _listener;
  int _client;
  uint16_t _port;
  NSString* _token;
  NSCondition* _condition;
  BOOL _connected;
  BOOL _attached;
  BOOL _finished;
  BOOL _success;
  BOOL _closed;
  NSString* _finalMessage;
  NSMutableArray<NSString*>* _mutableLogs;
  dispatch_queue_t _readerQueue;
}

- (nullable instancetype)initWithError:(NSError**)error {
  self = [super init];
  if (!self) return nil;

  _listener = socket(AF_INET, SOCK_STREAM, 0);
  _client = -1;
  if (_listener < 0) {
    if (error != NULL) {
      *error = [NSError errorWithDomain:@"NeoStationRPCS3"
                                   code:2101
                               userInfo:@{NSLocalizedDescriptionKey : @"Could not create the RPCS3 JIT helper socket."}];
    }
    return nil;
  }

  int reuse = 1;
  setsockopt(_listener, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
  struct sockaddr_in address = {};
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  address.sin_port = 0;
  if (bind(_listener, (struct sockaddr*)&address, sizeof(address)) != 0 ||
      listen(_listener, 1) != 0) {
    close(_listener);
    _listener = -1;
    if (error != NULL) {
      *error = [NSError errorWithDomain:@"NeoStationRPCS3"
                                   code:2102
                               userInfo:@{NSLocalizedDescriptionKey : @"Could not bind the RPCS3 JIT helper socket."}];
    }
    return nil;
  }

  socklen_t length = sizeof(address);
  if (getsockname(_listener, (struct sockaddr*)&address, &length) != 0) {
    close(_listener);
    _listener = -1;
    if (error != NULL) {
      *error = [NSError errorWithDomain:@"NeoStationRPCS3"
                                   code:2103
                               userInfo:@{NSLocalizedDescriptionKey : @"Could not determine the RPCS3 JIT helper port."}];
    }
    return nil;
  }

  _port = ntohs(address.sin_port);
  _token = NSUUID.UUID.UUIDString;
  _condition = [NSCondition new];
  _mutableLogs = [NSMutableArray new];
  _finalMessage = @"";
  _readerQueue = dispatch_queue_create(
      "com.neogamelab.neostation.rpcs3.helper-reader",
      DISPATCH_QUEUE_SERIAL);
  return self;
}

- (uint16_t)port { return _port; }
- (NSString*)token { return _token; }

- (BOOL)closed {
  [_condition lock];
  BOOL value = _closed;
  [_condition unlock];
  return value;
}

- (void)cancelExtensionRequest {
  id extension = self.extensionObject;
  id identifier = self.requestIdentifier;
  if (!extension || !identifier) return;
  dispatch_async(dispatch_get_main_queue(), ^{
    SEL selector = NSSelectorFromString(@"cancelExtensionRequestWithIdentifier:");
    if ([extension respondsToSelector:selector]) {
      void (*cancelMessage)(id, SEL, id) =
          reinterpret_cast<void (*)(id, SEL, id)>(objc_msgSend);
      cancelMessage(extension, selector, identifier);
    }
  });
}

- (BOOL)connected {
  [_condition lock];
  BOOL value = _connected;
  [_condition unlock];
  return value;
}

- (BOOL)attached {
  [_condition lock];
  BOOL value = _attached;
  [_condition unlock];
  return value;
}

- (BOOL)finished {
  [_condition lock];
  BOOL value = _finished;
  [_condition unlock];
  return value;
}

- (BOOL)success {
  [_condition lock];
  BOOL value = _success;
  [_condition unlock];
  return value;
}

- (NSString*)finalMessage {
  [_condition lock];
  NSString* value = [_finalMessage copy];
  [_condition unlock];
  return value;
}

- (NSArray<NSString*>*)logs {
  [_condition lock];
  NSArray<NSString*>* value = [_mutableLogs copy];
  [_condition unlock];
  return value;
}

- (void)markFinished:(BOOL)success message:(NSString*)message {
  [_condition lock];
  _finished = YES;
  _success = success;
  _finalMessage = message ?: @"";
  [_condition broadcast];
  [_condition unlock];
}

- (void)startReader {
  __weak RPCS3JitSession* weakSelf = self;
  dispatch_async(_readerQueue, ^{
    RPCS3JitSession* strongSelf = weakSelf;
    if (strongSelf == nil) return;

    struct pollfd descriptor = {strongSelf->_listener, POLLIN, 0};
    int pollResult = poll(
        &descriptor,
        1,
        (int)(kRpcs3HelperConnectTimeout * 1000.0));
    if (pollResult <= 0) {
      [strongSelf markFinished:NO
                       message:@"The RPCS3 JIT helper did not connect to NeoStation."];
      return;
    }

    int accepted = accept(strongSelf->_listener, NULL, NULL);
    if (accepted < 0) {
      [strongSelf markFinished:NO
                       message:@"The RPCS3 JIT helper socket could not be accepted."];
      return;
    }

    FILE* stream = fdopen(accepted, "r");
    if (stream == NULL) {
      close(accepted);
      [strongSelf markFinished:NO
                       message:@"The RPCS3 JIT helper stream could not be opened."];
      return;
    }
    // Keep a duplicate solely for shutdown. fclose owns the original fd;
    // closing a timed-out session must also unblock its fgets reader.
    [strongSelf->_condition lock];
    if (strongSelf->_closed) {
      [strongSelf->_condition unlock];
      fclose(stream);
      return;
    }
    strongSelf->_client = dup(fileno(stream));
    [strongSelf->_condition unlock];

    char buffer[65536];
    while (fgets(buffer, sizeof(buffer), stream) != NULL) {
      @autoreleasepool {
        NSString* line = [[NSString alloc] initWithUTF8String:buffer];
        line = [line stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (line.length == 0) continue;
        NSData* data = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary* payload = [NSJSONSerialization JSONObjectWithData:data
                                                                 options:0
                                                                   error:nil];
        if (![payload isKindOfClass:NSDictionary.class] ||
            ![payload[@"token"] isEqualToString:strongSelf->_token]) {
          continue;
        }

        NSString* event = [payload[@"event"] isKindOfClass:NSString.class]
            ? payload[@"event"]
            : @"unknown";
        NSString* message = [payload[@"message"] isKindOfClass:NSString.class]
            ? payload[@"message"]
            : @"";

        [strongSelf->_condition lock];
        if ([event isEqualToString:@"helper_connected"]) {
          strongSelf->_connected = YES;
        } else if ([event isEqualToString:@"pid_attached"] &&
                   strongSelf->_connected) {
          NSNumber* targetPID = [payload[@"targetPID"] isKindOfClass:NSNumber.class]
              ? payload[@"targetPID"]
              : nil;
          if ([targetPID isEqualToNumber:@(getpid())]) {
            strongSelf->_attached = YES;
          }
        } else if ([event isEqualToString:@"log"]) {
          if (message.length > 0) [strongSelf->_mutableLogs addObject:message];
        } else if ([event isEqualToString:@"complete"]) {
          strongSelf->_finished = YES;
          strongSelf->_success = [payload[@"success"] boolValue];
          strongSelf->_finalMessage = message ?: @"";
        }
        [strongSelf->_condition broadcast];
        [strongSelf->_condition unlock];
      }
      if (strongSelf.finished) break;
    }
    fclose(stream);
    if (!strongSelf.finished) {
      [strongSelf markFinished:NO
                       message:@"The RPCS3 JIT helper disconnected before completing the transaction."];
    }
  });
}

- (BOOL)waitForPredicate:(BOOL (^)(void))predicate
                 timeout:(NSTimeInterval)timeout {
  NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  [_condition lock];
  while (!predicate()) {
    if (![_condition waitUntilDate:deadline]) break;
  }
  BOOL value = predicate();
  [_condition unlock];
  return value;
}

- (BOOL)waitUntilConnected:(NSTimeInterval)timeout {
  [self waitForPredicate:^BOOL {
    return self->_connected || self->_finished;
  } timeout:timeout];
  return self.connected;
}

- (BOOL)waitUntilAttached:(NSTimeInterval)timeout {
  [self waitForPredicate:^BOOL {
    return self->_attached || self->_finished;
  } timeout:timeout];
  // StikJIT's pre-TXM attach/detach path does not log a universal vAttach
  // reply. Its successful completion is sufficient only on the legacy Core.
  return self.attached ||
      (!self.requiresCoreHandshake && self.connected && self.finished && self.success);
}

- (BOOL)waitUntilFinished:(NSTimeInterval)timeout {
  return [self waitForPredicate:^BOOL {
    return self->_finished;
  } timeout:timeout];
}

- (void)close {
  [_condition lock];
  if (_closed) {
    [_condition unlock];
    return;
  }
  _closed = YES;
  if (_listener >= 0) {
    shutdown(_listener, SHUT_RDWR);
    close(_listener);
    _listener = -1;
  }
  if (_client >= 0) {
    shutdown(_client, SHUT_RDWR);
    close(_client);
    _client = -1;
  }
  [_condition broadcast];
  [_condition unlock];
  if (!self.finished) [self cancelExtensionRequest];
}

- (void)dealloc {
  [self close];
}

@end

static NSString* _Nullable RPCS3FindHelperBundleIdentifier(void) {
  NSURL* plugins = NSBundle.mainBundle.builtInPlugInsURL;
  if (plugins == nil) return nil;
  NSArray<NSURL*>* entries = [NSFileManager.defaultManager
      contentsOfDirectoryAtURL:plugins
    includingPropertiesForKeys:nil
                       options:0
                         error:nil];
  for (NSURL* entry in entries) {
    if (![entry.pathExtension.lowercaseString isEqualToString:@"appex"]) continue;
    NSBundle* bundle = [NSBundle bundleWithURL:entry];
    NSDictionary* extension = [bundle objectForInfoDictionaryKey:@"NSExtension"];
    NSString* point = [extension isKindOfClass:NSDictionary.class]
        ? extension[@"NSExtensionPointIdentifier"]
        : nil;
    NSString* marker = [bundle objectForInfoDictionaryKey:@"NeoStationRPCS3JITHelper"];
    if ([point isEqualToString:@"com.apple.share-services"] &&
        [marker isEqualToString:@"1"] &&
        bundle.bundleIdentifier.length > 0) {
      return bundle.bundleIdentifier;
    }
  }
  return nil;
}

static BOOL RPCS3LaunchJitHelper(
    RPCS3JitSession* session,
    NSData* pairingData,
    NSError** error) {
  NSString* helperIdentifier = RPCS3FindHelperBundleIdentifier();
  if (helperIdentifier.length == 0) {
    if (error != NULL) {
      *error = [NSError errorWithDomain:@"NeoStationRPCS3"
                                   code:2201
                               userInfo:@{NSLocalizedDescriptionKey : @"The embedded RPCS3 JIT helper extension is missing."}];
    }
    return NO;
  }

  NSDictionary* request = @{
    @"protocolVersion" : @1,
    @"targetPID" : @(getpid()),
    @"port" : @(session.port),
    @"token" : session.token,
    @"pairingData" : [pairingData base64EncodedStringWithOptions:0],
    @"requiresCoreHandshake" : @(session.requiresCoreHandshake),
  };
  NSData* requestData = [NSJSONSerialization dataWithJSONObject:request
                                                        options:0
                                                          error:error];
  if (requestData == nil) return NO;

  NSItemProvider* provider = [[NSItemProvider alloc]
      initWithItem:requestData
    typeIdentifier:kRpcs3JitRequestType];
  NSExtensionItem* item = [NSExtensionItem new];
  item.attachments = @[provider];

  Class extensionClass = NSClassFromString(@"NSExtension");
  SEL createSelector = NSSelectorFromString(@"extensionWithIdentifier:error:");
  SEL beginSelector = NSSelectorFromString(
      @"beginExtensionRequestWithInputItems:completion:");
  if (extensionClass == Nil ||
      ![extensionClass respondsToSelector:createSelector]) {
    if (error != NULL) {
      *error = [NSError errorWithDomain:@"NeoStationRPCS3"
                                   code:2202
                               userInfo:@{NSLocalizedDescriptionKey : @"This iOS build cannot start the embedded RPCS3 JIT helper."}];
    }
    return NO;
  }

  id (*createMessage)(id, SEL, NSString*, NSError**) =
      reinterpret_cast<id (*)(id, SEL, NSString*, NSError**)>(objc_msgSend);
  id extensionObject = createMessage(
      extensionClass,
      createSelector,
      helperIdentifier,
      error);
  if (extensionObject == nil ||
      ![extensionObject respondsToSelector:beginSelector]) {
    return NO;
  }
  session.extensionObject = extensionObject;

  // Retain until launch returns its request identifier, even if the connection
  // timed out first, so that a late extension can still be cancelled.
  void (^completion)(id) = ^(id requestIdentifier) {
    session.requestIdentifier = requestIdentifier;
    if (session.closed) [session cancelExtensionRequest];
  };
  void (*beginMessage)(id, SEL, NSArray*, id) =
      reinterpret_cast<void (*)(id, SEL, NSArray*, id)>(objc_msgSend);
  beginMessage(extensionObject, beginSelector, @[item], completion);
  return YES;
}

@interface Rpcs3JitBridgePlugin ()
@property(nonatomic, strong) FlutterMethodChannel* channel;
@property(atomic, strong, nullable) RPCS3JitSession* activeSession;
@property(nonatomic, assign) BOOL operationInProgress;
@property(nonatomic, assign) BOOL completionInProgress;
@end

static __weak Rpcs3JitBridgePlugin* gRpcs3JitBridge;

BOOL RPCS3JitHasActiveCoreHandshake(void) {
  RPCS3JitSession* session = gRpcs3JitBridge.activeSession;
  return session != nil && session.requiresCoreHandshake &&
      session.attached && !session.finished && !session.closed;
}

@implementation Rpcs3JitBridgePlugin {
  dispatch_queue_t _jitQueue;
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  FlutterMethodChannel* channel = [FlutterMethodChannel
      methodChannelWithName:kRpcs3JitChannel
            binaryMessenger:registrar.messenger];
  Rpcs3JitBridgePlugin* instance = [Rpcs3JitBridgePlugin new];
  gRpcs3JitBridge = instance;
  instance.channel = channel;
  [registrar addMethodCallDelegate:instance channel:channel];
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _jitQueue = dispatch_queue_create(
        "com.neogamelab.neostation.rpcs3.jit",
        DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  if ([call.method isEqualToString:@"status"]) {
    result(@{
      @"getTaskAllow" : @(RPCS3HostHasGetTaskAllow()),
      @"debugged" : @(RPCS3HostIsDebugged()),
      @"busy" : @(self.operationInProgress),
      @"requiresCoreHandshake" : @(RPCS3RequiresCoreHandshake()),
      @"message" : self.activeSession.logs.lastObject ?: @"",
    });
    return;
  }

  if ([call.method isEqualToString:@"completeJit"]) {
    RPCS3JitSession* session = self.activeSession;
    if (session == nil || self.completionInProgress) {
      result(@{@"success": @NO, @"message": @"No RPCS3 JIT transaction is ready to complete."});
      return;
    }
    self.completionInProgress = YES;
    dispatch_async(_jitQueue, ^{
      BOOL completed = [session waitUntilFinished:kRpcs3CompletionTimeout];
      BOOL success = completed && session.success && RPCS3HostIsDebugged();
      NSDictionary* response = @{
        @"success": @(success),
        @"logs": session.logs,
        @"message": success ? @"RPCS3 JIT arena prepared and helper detached." :
            (session.finalMessage.length ? session.finalMessage :
             @"RPCS3 JIT helper did not confirm completion. Relaunch NeoStation before retrying."),
      };
      // A failed/incomplete handshake may still own a debugger. Keep the
      // transaction locked in that case instead of starting another attach.
      if (completed) {
        [session close];
        self.activeSession = nil;
        self.operationInProgress = NO;
      }
      self.completionInProgress = NO;
      dispatch_async(dispatch_get_main_queue(), ^{ result(response); });
    });
    return;
  }

  if (![call.method isEqualToString:@"prepareJit"]) {
    result(FlutterMethodNotImplemented);
    return;
  }

  NSDictionary* args = [call.arguments isKindOfClass:NSDictionary.class]
      ? call.arguments
      : @{};
  NSString* pairingPath = [args[@"pairingFilePath"] isKindOfClass:NSString.class]
      ? args[@"pairingFilePath"]
      : @"";

  if (@available(iOS 17.4, *)) {
  } else {
    result(@{
      @"success" : @NO,
      @"message" : @"Embedded RPCS3 requires iOS 17.4 or newer.",
    });
    return;
  }
  if (!RPCS3HostHasGetTaskAllow()) {
    result(@{
      @"success" : @NO,
      @"message" : @"This NeoStation installation does not preserve get-task-allow.",
    });
    return;
  }
  if (pairingPath.length == 0 ||
      ![NSFileManager.defaultManager isReadableFileAtPath:pairingPath]) {
    result(@{
      @"success" : @NO,
      @"message" : @"Import a readable pairing file before enabling RPCS3 JIT.",
    });
    return;
  }

  @synchronized(self) {
    if (self.operationInProgress || self.activeSession != nil) {
      result(@{
        @"success" : @NO,
        @"message" : @"An RPCS3 JIT operation is already running.",
      });
      return;
    }
    self.operationInProgress = YES;
  }

  dispatch_async(_jitQueue, ^{
    NSMutableDictionary* response = [@{
      @"success" : @NO,
      @"pid" : @(getpid()),
      @"helperConnected" : @NO,
      @"pidAttached" : @NO,
      @"debugged" : @NO,
      @"logs" : @[],
    } mutableCopy];

    void (^finish)(void) = ^{
      @synchronized(self) {
        [self.activeSession close];
        self.activeSession = nil;
        self.operationInProgress = NO;
      }
      dispatch_async(dispatch_get_main_queue(), ^{
        result(response);
      });
    };

    NSData* pairingData = [[NSData alloc]
        initWithContentsOfFile:pairingPath
                       options:NSDataReadingMappedIfSafe
                         error:nil];
    if (pairingData.length == 0) {
      response[@"message"] = @"The stored pairing file could not be read.";
      finish();
      return;
    }

    NSError* sessionError = nil;
    RPCS3JitSession* session = [[RPCS3JitSession alloc]
        initWithError:&sessionError];
    if (session == nil) {
      response[@"message"] = sessionError.localizedDescription ?: @"Could not prepare the RPCS3 JIT helper.";
      finish();
      return;
    }
    self.activeSession = session;
    session.requiresCoreHandshake = RPCS3RequiresCoreHandshake();
    [session startReader];

    NSError* launchError = nil;
    if (!RPCS3LaunchJitHelper(session, pairingData, &launchError)) {
      response[@"message"] = launchError.localizedDescription ?: @"Could not launch the RPCS3 JIT helper.";
      finish();
      return;
    }
    if (![session waitUntilConnected:kRpcs3HelperConnectTimeout]) {
      response[@"message"] = session.finalMessage.length
          ? session.finalMessage
          : @"RPCS3 JIT helper did not connect.";
      response[@"logs"] = session.logs;
      finish();
      return;
    }
    response[@"helperConnected"] = @YES;

    if (![session waitUntilAttached:kRpcs3AttachTimeout]) {
      response[@"message"] = session.finalMessage.length
          ? session.finalMessage
          : @"StikJIT did not attach universal.js to NeoStation.";
      response[@"logs"] = session.logs;
      finish();
      return;
    }
    response[@"pidAttached"] = @YES;

    if (session.finished && !session.success) {
      response[@"message"] = session.finalMessage.length
          ? session.finalMessage
          : @"The RPCS3 JIT transaction did not complete successfully.";
      response[@"logs"] = session.logs;
      finish();
      return;
    }

    BOOL debugged = RPCS3HostIsDebugged();
    response[@"debugged"] = @(debugged);
    response[@"logs"] = session.logs;
    if (!debugged) {
      response[@"message"] = @"StikJIT detached without leaving NeoStation JIT-enabled.";
      finish();
      return;
    }

    // Do NOT wait for universal.js to finish here. Core constructors and
    // initialize prepare the RX arena and issue BRK #0xf00d / command 0.
    // Waiting before dlopen deadlocks host and helper (the old 90s failure).
    response[@"success"] = @YES;
    response[@"requiresCompletion"] = @YES;
    response[@"message"] = @"RPCS3 helper attached; initialize the Core before completing JIT.";
    dispatch_async(dispatch_get_main_queue(), ^{ result(response); });
  });
}

@end
