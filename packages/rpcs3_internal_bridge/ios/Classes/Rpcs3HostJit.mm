#import "Rpcs3HostJit.h"

#import <Security/Security.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <poll.h>
#import <stdio.h>
#import <string.h>
#import <arpa/inet.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <sys/types.h>
#import <unistd.h>

static NSString* const kRPCS3JITRequestType = @"com.neogamelab.neostation.rpcs3-jit-request";
static NSTimeInterval const kRPCS3JITConnectTimeout = 30.0;
static NSTimeInterval const kRPCS3JITAttachTimeout = 240.0;
static NSTimeInterval const kRPCS3JITCompletionTimeout = 90.0;

extern "C" {
void* SecTaskCreateFromSelf(CFAllocatorRef allocator);
CFTypeRef SecTaskCopyValueForEntitlement(void* task,
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
      task, CFSTR("get-task-allow"), NULL);
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

@interface RPCS3JITSession : NSObject
@property(nonatomic, readonly) uint16_t port;
@property(nonatomic, readonly) NSString* token;
@property(nonatomic, readonly) BOOL connected;
@property(nonatomic, readonly) BOOL attached;
@property(nonatomic, readonly) BOOL finished;
@property(nonatomic, readonly) BOOL success;
@property(nonatomic, readonly) NSString* finalMessage;
@property(nonatomic, readonly) NSArray<NSString*>* logs;
@property(nonatomic, strong, nullable) id extensionObject;
@property(nonatomic, strong, nullable) id requestIdentifier;
- (nullable instancetype)initWithError:(NSError**)error;
- (void)startReader;
- (BOOL)waitUntilConnected:(NSTimeInterval)timeout;
- (BOOL)waitUntilAttached:(NSTimeInterval)timeout;
- (BOOL)waitUntilFinished:(NSTimeInterval)timeout;
- (void)close;
@end

@implementation RPCS3JITSession {
  int _listener;
  int _client;
  uint16_t _port;
  NSString* _token;
  NSCondition* _condition;
  BOOL _connected;
  BOOL _attached;
  BOOL _finished;
  BOOL _success;
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
      *error = [NSError errorWithDomain:@"NeoStationRPCS3JIT"
                                   code:2001
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
      *error = [NSError errorWithDomain:@"NeoStationRPCS3JIT"
                                   code:2002
                               userInfo:@{NSLocalizedDescriptionKey : @"Could not bind the RPCS3 JIT helper socket."}];
    }
    return nil;
  }

  socklen_t length = sizeof(address);
  if (getsockname(_listener, (struct sockaddr*)&address, &length) != 0) {
    close(_listener);
    _listener = -1;
    if (error != NULL) {
      *error = [NSError errorWithDomain:@"NeoStationRPCS3JIT"
                                   code:2003
                               userInfo:@{NSLocalizedDescriptionKey : @"Could not resolve the RPCS3 JIT helper port."}];
    }
    return nil;
  }

  _port = ntohs(address.sin_port);
  _token = NSUUID.UUID.UUIDString;
  _condition = [NSCondition new];
  _mutableLogs = [NSMutableArray array];
  _finalMessage = @"";
  _readerQueue = dispatch_queue_create("com.neogamelab.neostation.rpcs3.jit-reader",
                                       DISPATCH_QUEUE_SERIAL);
  return self;
}

- (uint16_t)port { return _port; }
- (NSString*)token { return _token; }
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
  NSString* value = _finalMessage ?: @"";
  [_condition unlock];
  return value;
}
- (NSArray<NSString*>*)logs {
  [_condition lock];
  NSArray<NSString*>* value = [_mutableLogs copy];
  [_condition unlock];
  return value;
}

- (void)finish:(BOOL)success message:(NSString*)message {
  [_condition lock];
  _finished = YES;
  _success = success;
  _finalMessage = message ?: @"";
  [_condition broadcast];
  [_condition unlock];
}

- (void)startReader {
  __weak RPCS3JITSession* weakSelf = self;
  dispatch_async(_readerQueue, ^{
    RPCS3JITSession* strongSelf = weakSelf;
    if (strongSelf == nil) return;

    struct pollfd descriptor = {strongSelf->_listener, POLLIN, 0};
    int pollResult = poll(&descriptor, 1, (int)(kRPCS3JITConnectTimeout * 1000.0));
    if (pollResult <= 0) {
      [strongSelf finish:NO message:@"The RPCS3 JIT helper did not connect to NeoStation."];
      return;
    }

    strongSelf->_client = accept(strongSelf->_listener, NULL, NULL);
    if (strongSelf->_client < 0) {
      [strongSelf finish:NO message:@"The RPCS3 JIT helper socket could not be accepted."];
      return;
    }

    FILE* stream = fdopen(strongSelf->_client, "r");
    if (stream == NULL) {
      [strongSelf finish:NO message:@"The RPCS3 JIT helper stream could not be opened."];
      return;
    }
    strongSelf->_client = -1;

    char buffer[65536];
    while (fgets(buffer, sizeof(buffer), stream) != NULL) {
      @autoreleasepool {
        NSString* line = [[NSString alloc] initWithUTF8String:buffer];
        line = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (line.length == 0) continue;
        NSData* data = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary* payload = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![payload isKindOfClass:NSDictionary.class] ||
            ![payload[@"token"] isEqualToString:strongSelf->_token]) {
          continue;
        }

        NSString* event = [payload[@"event"] isKindOfClass:NSString.class]
                              ? payload[@"event"] : @"unknown";
        NSString* message = [payload[@"message"] isKindOfClass:NSString.class]
                                ? payload[@"message"] : @"";

        [strongSelf->_condition lock];
        if ([event isEqualToString:@"helper_connected"]) {
          strongSelf->_connected = YES;
        } else if ([event isEqualToString:@"pid_attached"] &&
                   strongSelf->_connected && !strongSelf->_finished) {
          NSNumber* targetPID = [payload[@"targetPID"] isKindOfClass:NSNumber.class]
                                    ? payload[@"targetPID"] : nil;
          if ([targetPID isEqualToNumber:@(getpid())]) strongSelf->_attached = YES;
        } else if ([event isEqualToString:@"log"] && message.length > 0) {
          [strongSelf->_mutableLogs addObject:message];
        } else if ([event isEqualToString:@"complete"]) {
          strongSelf->_finished = YES;
          strongSelf->_success = [payload[@"success"] boolValue];
          strongSelf->_finalMessage = message ?: @"";
        }
        [strongSelf->_condition broadcast];
        BOOL done = strongSelf->_finished;
        [strongSelf->_condition unlock];
        if (done) break;
      }
    }
    fclose(stream);
    if (!strongSelf.finished) {
      [strongSelf finish:NO message:@"The RPCS3 JIT helper disconnected before completing the attach transaction."];
    }
  });
}

- (BOOL)waitFor:(BOOL (^)(void))predicate timeout:(NSTimeInterval)timeout {
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
  return [self waitFor:^BOOL { return self->_connected || self->_finished; }
                timeout:timeout] && self.connected;
}

- (BOOL)waitUntilAttached:(NSTimeInterval)timeout {
  return [self waitFor:^BOOL { return self->_attached || self->_finished; }
                timeout:timeout] && self.attached;
}

- (BOOL)waitUntilFinished:(NSTimeInterval)timeout {
  return [self waitFor:^BOOL { return self->_finished; } timeout:timeout];
}

- (void)close {
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
}

- (void)dealloc { [self close]; }
@end

static NSString* _Nullable RPCS3FindJITHelperBundleIdentifier(void) {
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
                          ? extension[@"NSExtensionPointIdentifier"] : nil;
    NSString* marker = [bundle objectForInfoDictionaryKey:@"NeoStationRPCS3JITHelper"];
    if ([point isEqualToString:@"com.apple.share-services"] &&
        [marker isEqualToString:@"1"] && bundle.bundleIdentifier.length > 0) {
      return bundle.bundleIdentifier;
    }
  }
  return nil;
}

static BOOL RPCS3LaunchJITHelper(RPCS3JITSession* session,
                                 NSData* pairingData,
                                 NSError** error) {
  NSString* helperIdentifier = RPCS3FindJITHelperBundleIdentifier();
  if (helperIdentifier.length == 0) {
    if (error != NULL) {
      *error = [NSError errorWithDomain:@"NeoStationRPCS3JIT"
                                   code:2101
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
  };
  NSData* requestData = [NSJSONSerialization dataWithJSONObject:request options:0 error:error];
  if (requestData == nil) return NO;

  NSItemProvider* provider = [[NSItemProvider alloc] initWithItem:requestData
                                                   typeIdentifier:kRPCS3JITRequestType];
  NSExtensionItem* item = [NSExtensionItem new];
  item.attachments = @[provider];

  Class extensionClass = NSClassFromString(@"NSExtension");
  SEL createSelector = NSSelectorFromString(@"extensionWithIdentifier:error:");
  SEL beginSelector = NSSelectorFromString(@"beginExtensionRequestWithInputItems:completion:");
  if (extensionClass == Nil || ![extensionClass respondsToSelector:createSelector]) {
    if (error != NULL) {
      *error = [NSError errorWithDomain:@"NeoStationRPCS3JIT"
                                   code:2102
                               userInfo:@{NSLocalizedDescriptionKey : @"This iOS build cannot start the embedded RPCS3 JIT helper."}];
    }
    return NO;
  }

  id (*createMessage)(id, SEL, NSString*, NSError**) =
      reinterpret_cast<id (*)(id, SEL, NSString*, NSError**)>(objc_msgSend);
  id extensionObject = createMessage(extensionClass, createSelector, helperIdentifier, error);
  if (extensionObject == nil || ![extensionObject respondsToSelector:beginSelector]) return NO;
  session.extensionObject = extensionObject;

  __weak RPCS3JITSession* weakSession = session;
  void (^completion)(id) = ^(id requestIdentifier) {
    RPCS3JITSession* strongSession = weakSession;
    if (strongSession != nil) strongSession.requestIdentifier = requestIdentifier;
  };
  void (*beginMessage)(id, SEL, NSArray*, id) =
      reinterpret_cast<void (*)(id, SEL, NSArray*, id)>(objc_msgSend);
  beginMessage(extensionObject, beginSelector, @[item], completion);
  return YES;
}

NSDictionary<NSString*, id>* RPCS3PrepareHostJit(NSString* pairingFilePath) {
  if (pairingFilePath.length == 0) {
    return @{ @"success" : @NO, @"message" : @"RPCS3 requires a NeoStation pairing file before enabling JIT." };
  }
  if (!RPCS3HostHasGetTaskAllow()) {
    return @{ @"success" : @NO, @"message" : @"NeoStation is missing get-task-allow; RPCS3 JIT cannot be enabled." };
  }

  NSError* readError = nil;
  NSData* pairingData = [NSData dataWithContentsOfFile:pairingFilePath
                                               options:NSDataReadingMappedIfSafe
                                                 error:&readError];
  if (pairingData.length < 128 || pairingData.length > (5 * 1024 * 1024)) {
    return @{ @"success" : @NO,
              @"message" : readError.localizedDescription ?: @"The stored pairing file is invalid for RPCS3 JIT." };
  }

  NSError* sessionError = nil;
  RPCS3JITSession* session = [[RPCS3JITSession alloc] initWithError:&sessionError];
  if (session == nil) {
    return @{ @"success" : @NO,
              @"message" : sessionError.localizedDescription ?: @"RPCS3 could not create its JIT helper session." };
  }

  [session startReader];
  NSError* launchError = nil;
  if (!RPCS3LaunchJITHelper(session, pairingData, &launchError)) {
    [session close];
    return @{ @"success" : @NO,
              @"message" : launchError.localizedDescription ?: @"RPCS3 could not launch its JIT helper." };
  }

  if (![session waitUntilConnected:kRPCS3JITConnectTimeout]) {
    NSString* message = session.finalMessage.length > 0
        ? session.finalMessage : @"The RPCS3 JIT helper did not connect.";
    [session close];
    return @{ @"success" : @NO, @"message" : message, @"logs" : session.logs };
  }
  if (![session waitUntilAttached:kRPCS3JITAttachTimeout]) {
    NSString* message = session.finalMessage.length > 0
        ? session.finalMessage : @"StikJIT did not attach to NeoStation for RPCS3.";
    [session close];
    return @{ @"success" : @NO, @"message" : message, @"logs" : session.logs };
  }
  if (![session waitUntilFinished:kRPCS3JITCompletionTimeout]) {
    [session close];
    return @{ @"success" : @NO,
              @"message" : @"RPCS3 JIT attach succeeded but the helper did not finish cleanly.",
              @"logs" : session.logs };
  }

  BOOL success = session.success && RPCS3HostIsDebugged();
  NSString* message = session.finalMessage;
  if (success && message.length == 0) message = @"RPCS3 JIT is ready.";
  if (!success && message.length == 0) message = @"RPCS3 JIT attach did not leave NeoStation debugged.";
  NSArray<NSString*>* logs = session.logs;
  [session close];
  return @{ @"success" : @(success), @"message" : message ?: @"", @"logs" : logs ?: @[] };
}
