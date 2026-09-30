#import "NeoSwapDonorIPC.h"
#import "NeoSwapDonorRequestHandler.h"
#include "Broker.h"

#include <cstdio>
#include <cstdlib>
#include <unistd.h>

namespace {
constexpr uint64_t MiB = 1024 * 1024;
NSString* const serviceName = @"com.neogamelab.neostation.neoswap-ipc-probe.donor";
void require(bool condition, const char* message) {
  if (!condition) { std::fprintf(stderr, "FAIL: %s\n", message); std::exit(1); }
}
}

@interface ProbeReceiver : NSObject <NeoSwapDonorProbeProtocol>
@property(nonatomic, strong) NSXPCConnection* connection;
@property(nonatomic, strong) NeoSwapDonorRequestHandler* handler;
@end
@implementation ProbeReceiver
- (void)beginProbe:(NSDictionary*)metadata {
  if ([metadata[@"probeWaitOnly"] isEqual:@YES]) return;
  if ([metadata[@"probeDelay"] isEqual:@YES]) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
      [self.handler beginProbeWithConnection:self.connection metadata:metadata];
    });
    return;
  }
  [self.handler beginProbeWithConnection:self.connection metadata:metadata];
}
@end

@interface ProbeListener : NSObject <NSXPCListenerDelegate>
@end
@implementation ProbeListener
- (BOOL)listener:(NSXPCListener*)listener shouldAcceptNewConnection:(NSXPCConnection*)connection {
  (void)listener;
  if (connection.processIdentifier <= 0 || connection.processIdentifier == getpid()) return NO;
  ProbeReceiver* receiver = [ProbeReceiver new];
  receiver.connection = connection;
  receiver.handler = [NeoSwapDonorRequestHandler new];
  connection.exportedObject = receiver;
  connection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(NeoSwapDonorProbeProtocol)];
  [connection resume];
  return YES;
}
@end

@interface NeoSwapDonorSession (ProbeMetadata)
- (NSDictionary*)requestMetadata;
@end
@interface BadNonceSession : NeoSwapDonorSession
@end
@implementation BadNonceSession
- (NSDictionary*)requestMetadata {
  NSMutableDictionary* result = [[super requestMetadata] mutableCopy];
  result[@"nonce"] = NSUUID.UUID.UUIDString;
  return result;
}
@end
@interface BadGenerationSession : NeoSwapDonorSession
@end
@implementation BadGenerationSession
- (NSDictionary*)requestMetadata {
  NSMutableDictionary* result = [[super requestMetadata] mutableCopy];
  result[@"generation"] = @([result[@"generation"] unsignedLongLongValue] + 1);
  return result;
}
@end
@interface WaitOnlySession : NeoSwapDonorSession
@end
@implementation WaitOnlySession
- (NSDictionary*)requestMetadata {
  NSMutableDictionary* result = [[super requestMetadata] mutableCopy];
  result[@"probeWaitOnly"] = @YES;
  return result;
}
@end
@interface LateSession : NeoSwapDonorSession
@end
@implementation LateSession
- (NSDictionary*)requestMetadata {
  NSMutableDictionary* result = [[super requestMetadata] mutableCopy];
  result[@"probeDelay"] = @YES;
  return result;
}
@end

static NSDictionary* checkRejected(Class type, uint64_t generation) {
  dispatch_semaphore_t changed = dispatch_semaphore_create(0);
  __block NSUInteger active = 0;
  __block NSError* failure = nil;
  NeoSwapDonorSession* session = [[type alloc] initWithHelperIdentifier:@"probe"
      requestedBytes:4 * MiB generation:generation timeout:1
      observer:^(NeoSwapDonorSession* source, NeoSwapDonorSnapshot snapshot, NSError* error) {
    (void)source;
    if (snapshot.state == NeoSwapDonorStateActive) ++active;
    if (snapshot.state == NeoSwapDonorStateFailed) {
      failure = error;
      dispatch_semaphore_signal(changed);
    }
  }];
  [session startWithServiceNameForProbe:serviceName];
  require(dispatch_semaphore_wait(changed, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) == 0,
          "Rejected/expired IPC scenario did not finish");
  const auto snapshot = [session snapshot];
  require(snapshot.state == NeoSwapDonorStateFailed && !snapshot.donatedResidentBytes &&
          !snapshot.donatedCompressedBytes && ![session copyMemoryEntry] && failure,
          "Failed IPC scenario exposed a donation/right or lost its technical error");
  if (type == LateSession.class) {
    dispatch_semaphore_t late = dispatch_semaphore_create(0);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ dispatch_semaphore_signal(late); });
    require(dispatch_semaphore_wait(late, dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC)) == 0,
            "Late callback probe did not finish");
    require([session snapshot].state == NeoSwapDonorStateFailed && !active,
            "Late donor reply resurrected an expired session");
  }
  [session close];
  return @{ @"scenario":NSStringFromClass(type), @"generation":@(generation),
            @"activeCallbacks":@(active), @"errorCode":@(failure.code), @"passed":@YES };
}

int main(int argc, const char* argv[]) {
  @autoreleasepool {
    if ([[NSBundle.mainBundle objectForInfoDictionaryKey:@"NeoSwapIPCProbeService"] isEqual:@YES]) {
      ProbeListener* delegate = [ProbeListener new];
      NSXPCListener* listener = NSXPCListener.serviceListener;
      listener.delegate = delegate;
      [listener resume];
      return 2;
    }
    require([NeoSwapMachHandle isTransportAvailable], "Mach send-right XPC symbols unavailable");
    neostation::donation::Footprint before, after;
    require(bool(neostation::donation::footprint(before)), "Host baseline TASK_VM_INFO failed");
    dispatch_semaphore_t active = dispatch_semaphore_create(0);
    __block NSError* lastError = nil;
    __block BOOL signaled = NO;
    NeoSwapDonorSession* session = [[NeoSwapDonorSession alloc] initWithHelperIdentifier:@"probe"
        requestedBytes:64 * MiB generation:1 timeout:10
        observer:^(NeoSwapDonorSession* source, NeoSwapDonorSnapshot snapshot, NSError* error) {
      (void)source;
      if (!signaled && (snapshot.state == NeoSwapDonorStateActive || snapshot.state == NeoSwapDonorStateFailed)) {
        lastError = error;
        signaled = YES;
        dispatch_semaphore_signal(active);
      }
    }];
    [session startWithServiceNameForProbe:serviceName];
    require(dispatch_semaphore_wait(active, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC)) == 0,
            "Real XPC donor did not complete shared-page verification");
    if (lastError) std::fprintf(stderr, "%s\n", lastError.description.UTF8String);
    const auto snapshot = [session snapshot];
    require(snapshot.state == NeoSwapDonorStateActive && snapshot.donorPID > 0 &&
            snapshot.donorPID != getpid() && snapshot.capacityBytes == 64 * MiB &&
            snapshot.donatedResidentBytes + snapshot.donatedCompressedBytes >= 63 * MiB,
            "Active donor lacks separate PID and measured resident/compressed ledger evidence");
    require(bool(neostation::donation::footprint(after)), "Host after-map TASK_VM_INFO failed");
    const uint64_t hostNonvolatileDelta = after.nonvolatile > before.nonvolatile
        ? after.nonvolatile - before.nonvolatile : 0;
    require(hostNonvolatileDelta < MiB, "Host inherited the donor object's nonvolatile accounting");
    mach_port_t right = [session copyMemoryEntry];
    require(right != MACH_PORT_NULL, "Verified donor did not provide an owned copied right");
    neostation::donation::Block borrowed;
    require(bool(neostation::donation::Block::map_borrowed(right, snapshot.capacityBytes, borrowed)),
            "Copied XPC right could not be independently mapped");
    NeoSwapMachHandle* handle = [[NeoSwapMachHandle alloc] initWithMemoryEntry:right
                                                             capacityBytes:snapshot.capacityBytes];
    mach_port_deallocate(mach_task_self(), right);
    BOOL rejectedArchive = NO;
    @try {
      NSError* archiveError = nil;
      (void)[NSKeyedArchiver archivedDataWithRootObject:handle requiringSecureCoding:YES error:&archiveError];
      rejectedArchive = archiveError != nil;
    } @catch (NSException* exception) { rejectedArchive = YES; }
    require(rejectedArchive, "Numeric right was accepted by non-XPC archival transport");
    [session close];
    require([session snapshot].state == NeoSwapDonorStateClosed &&
            ![session snapshot].donatedResidentBytes && ![session copyMemoryEntry],
            "Closed donor still reports resident donation or vends new rights");
    NSMutableArray* rejected = [NSMutableArray new];
    [rejected addObject:checkRejected(BadNonceSession.class, 2)];
    [rejected addObject:checkRejected(BadGenerationSession.class, 3)];
    [rejected addObject:checkRejected(WaitOnlySession.class, 4)];
    [rejected addObject:checkRejected(LateSession.class, 5)];
    NSDictionary* report = @{ @"schema":@1, @"platform":@"macOS-NSXPC-two-process",
      @"iphoneExtensionValidated":@NO, @"hostPID":@(getpid()), @"donorPID":@(snapshot.donorPID),
      @"capacityBytes":@(snapshot.capacityBytes), @"donorResidentBytes":@(snapshot.donatedResidentBytes),
      @"donorCompressedBytes":@(snapshot.donatedCompressedBytes),
      @"hostNonvolatileDelta":@(hostNonvolatileDelta), @"rejectedArchive":@(rejectedArchive),
      @"rejectedScenarios":rejected, @"passed":@YES };
    NSData* data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
    if (argc > 1) require([data writeToFile:[NSString stringWithUTF8String:argv[1]] atomically:YES],
                          "Could not save IPC proof report");
    std::printf("%s\n", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
    return 0;
  }
}
