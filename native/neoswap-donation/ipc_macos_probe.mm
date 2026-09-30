#import "NeoSwapDonorIPC.h"
#import "NeoSwapDonorRequestHandler.h"
#include "Broker.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cerrno>
#include <unistd.h>

namespace {
constexpr uint64_t MiB = 1024 * 1024;
NSString* const serviceName = @"com.neogamelab.neostation.neoswap-ipc-probe.donor";
NSString* reportFile;
NSMutableDictionary* evidence;
void saveReport(NSDictionary* report) {
  NSData* data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
  if (reportFile && ![data writeToFile:reportFile atomically:YES])
    std::fprintf(stderr, "FAIL: Could not save IPC evidence report\n");
}
void require(bool condition, const char* message) {
  if (!condition) {
    std::fprintf(stderr, "FAIL: %s\n", message);
    if (evidence) {
      evidence[@"passed"] = @NO;
      evidence[@"technicalError"] = [NSString stringWithUTF8String:message];
      saveReport(evidence);
    }
    std::exit(1);
  }
}
}

#if defined(NEOSWAP_METAL_PROBE)
#include "MetalDonationProbe.h"
#endif
#if defined(NEOSWAP_VULKAN_PROBE)
#include "VulkanDonationProbe.h"
#endif

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
    reportFile = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : nil;
    evidence = [@{@"schema":@2, @"platform":@"macOS-NSXPC-two-process", @"passed":@NO,
                  @"hostPID":@(getpid()),
                  @"iphoneExtensionValidated":@NO, @"capacityBytes":@0, @"preparedBytes":@0,
                  @"donorResidentBytes":@0, @"donorCompressedBytes":@0} mutableCopy];
    uint64_t target = 128 * MiB;
    const char* requestedStress = std::getenv("NEOSWAP_IPC_STRESS_BYTES");
    const BOOL stress = requestedStress != nullptr;
    evidence[@"stressRequested"] = @(stress);
    neostation::donation::SystemHeadroom startingSystem{};
    const auto startingStatus = neostation::donation::system_headroom(startingSystem);
    evidence[@"systemFreeBeforeBytes"] = @(startingSystem.free_bytes);
    evidence[@"systemPurgeableBeforeBytes"] = @(startingSystem.purgeable_bytes);
    evidence[@"systemUsableBeforeBytes"] = @(startingSystem.usable_bytes);
    evidence[@"systemPressureBefore"] = @(static_cast<uint32_t>(startingSystem.pressure));
    evidence[@"systemSampleKernelResult"] = @(startingStatus.kernel_result);
    evidence[@"kernelAvailableBeforeBytes"] = @(startingSystem.kernel_available_bytes);
    evidence[@"kernelAvailablePercent"] = @(startingSystem.kernel_available_percent);
    evidence[@"kernelEstimateValid"] = @(startingSystem.kernel_estimate_valid);
    if (stress) {
      char* end = nullptr;
      errno = 0;
      target = std::strtoull(requestedStress, &end, 10);
      evidence[@"targetBytes"] = @(target);
      require(errno == 0 && end && *end == '\0' && requestedStress[0] != '-' &&
              target >= 128 * MiB && target <= 8ULL * 1024 * MiB && target % vm_page_size == 0,
              "Invalid opt-in stress target; expected 128 MiB..8 GiB page-aligned bytes");
      neostation::donation::SystemHeadroom system;
      const auto available = neostation::donation::system_headroom(system);
      evidence[@"systemHeadroomBeforeBytes"] = @(system.usable_bytes);
      evidence[@"systemPressureBefore"] = @(static_cast<uint32_t>(system.pressure));
      evidence[@"stage"] = @"stress_system_headroom_guard";
      require(bool(available) && system.usable_bytes >= target + MiB,
              "Real stress growth refused: measured system headroom cannot cover the target and safety reserve");
    }
    evidence[@"targetBytes"] = @(target);
    evidence[@"requestedBytes"] = @(target);
    evidence[@"stage"] = @"initial_chunk";
    require([NeoSwapMachHandle isTransportAvailable], "Mach send-right XPC symbols unavailable");
    neostation::donation::Footprint before, after;
    require(bool(neostation::donation::footprint(before)), "Host baseline TASK_VM_INFO failed");
    dispatch_semaphore_t active = dispatch_semaphore_create(0);
    __block NSError* lastError = nil;
    __block uint64_t signaledChunks = 0;
    NeoSwapDonorSession* session = [[NeoSwapDonorSession alloc] initWithHelperIdentifier:@"probe"
        requestedBytes:target generation:1 timeout:10
        observer:^(NeoSwapDonorSession* source, NeoSwapDonorSnapshot snapshot, NSError* error) {
      (void)source;
#if defined(NEOSWAP_VULKAN_PROBE)
      if (snapshot.state == NeoSwapDonorStateActive && !error)
        vulkanDonorLedgerEpoch.fetch_add(1, std::memory_order_release);
#endif
      if (snapshot.state == NeoSwapDonorStateFailed ||
          (snapshot.state == NeoSwapDonorStateActive &&
           (snapshot.verifiedChunkCount > signaledChunks || snapshot.growthState == NeoSwapDonorGrowthRefused))) {
        lastError = error;
        signaledChunks = snapshot.verifiedChunkCount;
        dispatch_semaphore_signal(active);
      }
    }];
    [session startWithServiceNameForProbe:serviceName];
    require(dispatch_semaphore_wait(active, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC)) == 0,
            "Real XPC donor did not complete shared-page verification");
    if (lastError) std::fprintf(stderr, "%s\n", lastError.description.UTF8String);
    const auto first = [session snapshot];
    evidence[@"donorPID"] = @(first.donorPID);
    evidence[@"capacityBytes"] = @(first.capacityBytes);
    evidence[@"preparedBytes"] = @(first.capacityBytes);
    evidence[@"donorResidentBytes"] = @(first.donatedResidentBytes);
    evidence[@"donorCompressedBytes"] = @(first.donatedCompressedBytes);
    evidence[@"diagnostics"] = session.diagnostics;
    require(first.state == NeoSwapDonorStateActive && first.verifiedChunkCount == 1 &&
            first.capacityBytes == 64 * MiB, "Initial real chunk was not established");
    mach_port_t firstRight = [session copyMemoryEntryForChunk:0];
    neostation::donation::Block firstBorrowed;
    require(firstRight && bool(neostation::donation::Block::map_borrowed(firstRight, 64 * MiB, firstBorrowed)),
            "First independently retained real chunk could not be mapped");
    const uint64_t preservedBytes = stress ? static_cast<uint64_t>(vm_page_size) : 64 * MiB;
    std::memset(firstBorrowed.data(), 0xa5, preservedBytes);
    require(![session requestNextChunkWithMaximumBytes:64 * MiB],
            "Growth was accepted before the host acknowledged adoption");
    require([session acknowledgeVerifiedChunk:0], "Initial host adoption could not be acknowledged");
    NSMutableSet<NSNumber*>* rights = [NSMutableSet setWithObject:@(firstRight)];
    NeoSwapDonorSnapshot snapshot = first;
    while (snapshot.capacityBytes < target) {
      const uint64_t maximum = MIN(256 * MiB, target - snapshot.capacityBytes);
      evidence[@"stage"] = @"incremental_chunk_proof";
      require([session requestNextChunkWithMaximumBytes:maximum],
              "The acknowledged donor could not request bounded sequential growth");
      require(dispatch_semaphore_wait(active, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC)) == 0,
              "A genuine incremental chunk did not finish its page/ledger proof");
      snapshot = [session snapshot];
      evidence[@"capacityBytes"] = @(snapshot.capacityBytes);
      evidence[@"preparedBytes"] = @(snapshot.capacityBytes);
      evidence[@"unacquiredBytes"] = @(target - snapshot.capacityBytes);
      evidence[@"refusedBytes"] = @(snapshot.refusedBytes);
      evidence[@"donorResidentBytes"] = @(snapshot.donatedResidentBytes);
      evidence[@"donorCompressedBytes"] = @(snapshot.donatedCompressedBytes);
      evidence[@"verifiedChunkCount"] = @(snapshot.verifiedChunkCount);
      evidence[@"diagnostics"] = session.diagnostics;
      require(snapshot.state == NeoSwapDonorStateActive && snapshot.growthState != NeoSwapDonorGrowthRefused,
              "Real chunk growth was refused or failed; previous measured capacity is preserved in this report");
      const uint64_t index = snapshot.verifiedChunkCount - 1;
      mach_port_t chunkRight = [session copyMemoryEntryForChunk:index];
      require(chunkRight && ![rights containsObject:@(chunkRight)],
              "A growth chunk replayed a previously verified memory entry");
      [rights addObject:@(chunkRight)];
      mach_port_deallocate(mach_task_self(), chunkRight);
      for (uint64_t offset = 0; offset < preservedBytes; ++offset)
        require(static_cast<const unsigned char*>(firstBorrowed.data())[offset] == 0xa5,
                "Growth proof overwrote prior borrowed data (replay/alias)");
      require([session acknowledgeVerifiedChunk:index], "Growth adoption could not be acknowledged");
    }
    require(snapshot.state == NeoSwapDonorStateActive && snapshot.donorPID > 0 &&
            snapshot.donorPID != getpid() && snapshot.capacityBytes == target && snapshot.verifiedChunkCount >= 2 &&
            snapshot.donatedResidentBytes + snapshot.donatedCompressedBytes >= target - MiB,
            "Active donor lacks distinct PID and cumulative charged page evidence");
    evidence[@"stage"] = @"final_resident_ledger";
    evidence[@"residentTargetVerified"] = @(snapshot.donatedResidentBytes >= target - MiB);
    if (stress)
      require(snapshot.donatedResidentBytes >= target - MiB,
              "The stress target was acquired logically but its final resident ledger does not prove the requested physical pages");
    require(bool(neostation::donation::footprint(after)), "Host after-map TASK_VM_INFO failed");
    const uint64_t hostNonvolatileDelta = after.nonvolatile > before.nonvolatile
        ? after.nonvolatile - before.nonvolatile : 0;
    require(hostNonvolatileDelta < MiB, "Host inherited the donor object's nonvolatile accounting");
    NSDictionary* metalReport = @{@"requested":@NO, @"passed":@NO};
#if defined(NEOSWAP_METAL_PROBE)
    metalReport = runMetalDonationProbe(session, target);
    evidence[@"metalDonation"] = metalReport;
#endif
    NSDictionary* vulkanReport = @{@"requested":@NO, @"passed":@NO};
#if defined(NEOSWAP_VULKAN_PROBE)
    vulkanReport = runVulkanDonationProbe(session, target);
    evidence[@"vulkanDonation"] = vulkanReport;
#endif
    const uint64_t lastIndex = snapshot.verifiedChunkCount - 1;
    const uint64_t lastBytes = [session chunkCapacityBytes:lastIndex];
    mach_port_t right = [session copyMemoryEntryForChunk:lastIndex];
    require(right != MACH_PORT_NULL && right != firstRight,
            "Last verified chunk did not provide a distinct owned memory entry");
    neostation::donation::Block borrowed;
    require(bool(neostation::donation::Block::map_borrowed(right, lastBytes, borrowed)),
            "Copied XPC right could not be independently mapped");
    NeoSwapMachHandle* handle = [[NeoSwapMachHandle alloc] initWithMemoryEntry:right capacityBytes:lastBytes];
    require(handle != nil, "The copied Mach-right wrapper could not reserve ownership");
    // Use an isolated real kernel entry for exact reference counts; asynchronous
    // Foundation message disposal must not influence this cleanup assertion.
    neostation::donation::Block cleanupObject;
    require(bool(neostation::donation::Block::create_owned(vm_page_size, cleanupObject)),
            "Could not create the real cleanup-test memory entry");
    const mach_port_t cleanupRight = cleanupObject.entry();
    neostation::donation::CleanupSnapshot cleanupBefore;
    neostation::donation::cleanup_snapshot(cleanupBefore);
    mach_port_urefs_t refsBefore = 0, refsQuarantined = 0, refsAfter = 0;
    require(mach_port_get_refs(mach_task_self(), cleanupRight, MACH_PORT_RIGHT_SEND, &refsBefore) == KERN_SUCCESS,
            "Could not measure the real wrapper send-right references");
    {
      __attribute__((objc_precise_lifetime)) NeoSwapMachHandle* retiring =
          [[NeoSwapMachHandle alloc] initWithMemoryEntry:cleanupRight capacityBytes:vm_page_size];
      require(retiring != nil && retiring.memoryEntry == cleanupRight,
              "The real retiring wrapper did not own its extra send reference");
      // One explicit dealloc attempt and the holder destructor both fail.
      // The actual kernel reference must remain quarantined for retry.
      neostation::donation::test_fail_next_right_releases(2);
    }
    neostation::donation::CleanupSnapshot quarantined;
    neostation::donation::cleanup_snapshot(quarantined);
    require(quarantined.pending_rights == cleanupBefore.pending_rights + 1 &&
            mach_port_get_refs(mach_task_self(), cleanupRight, MACH_PORT_RIGHT_SEND, &refsQuarantined) == KERN_SUCCESS &&
            refsQuarantined == refsBefore + 1,
            "A failed wrapper release discarded retry ownership of the real kernel reference");
    require(bool(neostation::donation::retry_cleanup()), "The wrapper's quarantined send reference could not be retired");
    neostation::donation::CleanupSnapshot cleaned;
    neostation::donation::cleanup_snapshot(cleaned);
    require(cleaned.pending_rights == cleanupBefore.pending_rights &&
            mach_port_get_refs(mach_task_self(), cleanupRight, MACH_PORT_RIGHT_SEND, &refsAfter) == KERN_SUCCESS &&
            refsAfter == refsBefore,
            "Retry did not release exactly the quarantined wrapper user reference");
    require(bool(cleanupObject.reset()), "The real cleanup-test memory entry could not be retired");
    require(![session requestNextChunkWithMaximumBytes:64 * MiB],
            "Completed target still accepted further chunk growth");
    mach_port_deallocate(mach_task_self(), firstRight);
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
    NSDictionary* report = @{ @"schema":@2, @"platform":@"macOS-NSXPC-two-process",
      @"iphoneExtensionValidated":@NO, @"hostPID":@(getpid()), @"donorPID":@(snapshot.donorPID),
      @"capacityBytes":@(snapshot.capacityBytes), @"donorResidentBytes":@(snapshot.donatedResidentBytes),
      @"targetBytes":@(snapshot.targetBytes), @"requestedBytes":@(target),
      @"verifiedChunkCount":@(snapshot.verifiedChunkCount),
      @"preparedBytes":@(snapshot.capacityBytes), @"stressRequested":@(stress),
      @"residentTargetVerified":@(snapshot.donatedResidentBytes >= target - MiB),
      @"distinctChunkRights":@YES, @"priorBorrowedDataPreserved":@YES,
      @"donorCompressedBytes":@(snapshot.donatedCompressedBytes),
      @"hostNonvolatileDelta":@(hostNonvolatileDelta), @"rejectedArchive":@(rejectedArchive),
      @"machHandleCleanupRetried":@YES,
      @"metalDonation":metalReport,
      @"vulkanDonation":vulkanReport,
      @"rejectedScenarios":rejected, @"passed":@YES };
    NSData* data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
    if (argc > 1) require([data writeToFile:[NSString stringWithUTF8String:argv[1]] atomically:YES],
                          "Could not save IPC proof report");
    std::printf("%s\n", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
    return 0;
  }
}
