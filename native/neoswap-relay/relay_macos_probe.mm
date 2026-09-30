// SPDX-License-Identifier: MIT
#import "NeoSwapPageRelay.h"
#import "NeoSwapPageRelayHandler.h"
#include "Backend.h"
#include "../neoswap-donation/Broker.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <sys/mman.h>
#include <mach/mach.h>
#include <unistd.h>

#if !defined(NEOSWAP_RELAY_EXTENSION)
namespace {
constexpr uint64_t MiB = 1024 * 1024;
NSString* const serviceName = @"com.neogamelab.neostation.relay-probe.NeoSwapPageRelay";
NSString* reportPath;
NSMutableDictionary* evidence;
static_assert(sizeof(vm_address_t) == sizeof(uintptr_t),
  "NeoSwap relay probe requires native-width vm_address_t");
static_assert(sizeof(vm_size_t) >= sizeof(uint64_t),
  "NeoSwap relay probe requires vm_size_t to hold 64-bit relay sizes");
static_assert(sizeof(vm_offset_t) >= sizeof(uint64_t),
  "NeoSwap relay probe requires vm_offset_t to hold 64-bit relay offsets");
void saveReport() {
  NSData* data = [NSJSONSerialization dataWithJSONObject:evidence options:NSJSONWritingPrettyPrinted error:nil];
  if (reportPath && ![data writeToFile:reportPath atomically:YES]) std::fprintf(stderr, "FAIL: evidence write failed\n");
}
void require(bool value, const char* message) {
  if (value) return;
  evidence[@"passed"] = @NO; evidence[@"technicalError"] = [NSString stringWithUTF8String:message]; saveReport();
  std::fprintf(stderr, "FAIL: %s\n", message); std::exit(1);
}
uint64_t pattern(uint64_t offset, uint64_t segment) {
  uint64_t x = offset ^ ((segment + 1) * 0x9e3779b97f4a7c15ULL);
  x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9ULL;
  x = (x ^ (x >> 27)) * 0x94d049bb133111ebULL;
  return x ^ (x >> 31);
}
void requireReservation(vm_address_t target, vm_size_t bytes) {
  vm_address_t region = target;
  vm_size_t size = 0;
  vm_region_basic_info_data_64_t info{};
  mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
  mach_port_t object = MACH_PORT_NULL;
  const kern_return_t result = vm_region_64(mach_task_self(), &region, &size,
    VM_REGION_BASIC_INFO_64, reinterpret_cast<vm_region_info_t>(&info), &count, &object);
  if (object != MACH_PORT_NULL)
    require(mach_port_deallocate(mach_task_self(), object) == KERN_SUCCESS, "Region query right cleanup failed");
  // Darwin may coalesce adjacent anonymous PROT_NONE ranges. Require full
  // containment rather than falsely rejecting a safely merged reservation.
  require(result == KERN_SUCCESS && count >= VM_REGION_BASIC_INFO_COUNT_64 &&
    region <= target && size >= bytes && target - region <= size - bytes && info.protection == VM_PROT_NONE,
    "Fixed relay cleanup left a hole or accessible mapping in the guest reservation");
}
void checkFixedReservation(const NeoSwapRelayAPI* api) {
  constexpr uint64_t bytes = NEOSWAP_RELAY_ALIGNMENT;
  vm_address_t reservation = 0;
  require(vm_map(mach_task_self(), &reservation, static_cast<vm_size_t>(bytes),
    static_cast<vm_address_t>(bytes - 1), VM_FLAGS_ANYWHERE,
    MEMORY_OBJECT_NULL, 0, FALSE, VM_PROT_NONE, VM_PROT_READ | VM_PROT_WRITE, VM_INHERIT_NONE) == KERN_SUCCESS,
    "Guest PROT_NONE reservation could not be created");
  requireReservation(reservation, bytes);
  // MACH_PORT_NULL and MACH_PORT_DEAD both follow XNU's anonymous-map path.
  // Use a genuine send right to an ordinary receive port instead: it is valid
  // IPC ownership, but cannot be interpreted as a named memory-entry object.
  mach_port_t nonMemoryPort = MACH_PORT_NULL;
  require(mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &nonMemoryPort) == KERN_SUCCESS &&
    mach_port_insert_right(mach_task_self(), nonMemoryPort, nonMemoryPort, MACH_MSG_TYPE_MAKE_SEND) == KERN_SUCCESS,
    "Negative fixed-map test could not create a non-memory Mach right");
  vm_address_t invalidTarget = reservation;
  const auto invalidMap = vm_map(mach_task_self(), &invalidTarget, static_cast<vm_size_t>(bytes), 0,
    VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, nonMemoryPort, 0, FALSE,
    VM_PROT_READ | VM_PROT_WRITE, VM_PROT_READ | VM_PROT_WRITE, VM_INHERIT_NONE);
  require(invalidMap != KERN_SUCCESS, "A non-memory Mach right unexpectedly produced a fixed mapping");
  requireReservation(reservation, bytes);
  require(mach_port_deallocate(mach_task_self(), nonMemoryPort) == KERN_SUCCESS,
    "Negative fixed-map Mach send right cleanup failed");
  require(mach_port_mod_refs(mach_task_self(), nonMemoryPort, MACH_PORT_RIGHT_RECEIVE, -1) == KERN_SUCCESS,
    "Negative fixed-map Mach receive right cleanup failed");
  uint64_t token = 0;
  void* view = nullptr;
  require(api->create(0, bytes, &token) == 0 &&
    api->map(token, reinterpret_cast<void*>(reservation), NEOSWAP_RELAY_READ_WRITE, &view) == 0 &&
    reinterpret_cast<vm_address_t>(view) == reservation,
    "Relay did not map into the reserved guest address");
  std::memset(view, 0x6b, bytes);
  require(api->unmap(token, view) == 0, "Fixed relay alias replacement failed");
  requireReservation(reservation, bytes);
  require(api->release(token) == 0, "Fixed relay token retirement failed");
  require(vm_deallocate(mach_task_self(), reservation, static_cast<vm_size_t>(bytes)) == KERN_SUCCESS,
    "Caller could not release its preserved guest reservation");
  evidence[@"fixedReservationPreserved"] = @YES;
  evidence[@"failedFixedMapPreservedReservation"] = @YES;
  evidence[@"invalidFixedMapKernelResult"] = @(invalidMap);
}
NSDictionary* systemMemorySample() {
  neostation::donation::SystemHeadroom sample{};
  const auto result = neostation::donation::system_headroom(sample);
  return @{ @"sampleSucceeded":@(static_cast<bool>(result)), @"kernelResult":@(result.kernel_result),
    @"freeBytes":@(sample.free_bytes), @"usableBudgetBytes":@(sample.usable_bytes),
    @"reclaimableBytes":@(sample.reclaimable_bytes), @"pressure":@(static_cast<uint32_t>(sample.pressure)),
    @"vmPageBytes":@(vm_page_size), @"getPageSizeBytes":@(getpagesize()) };
}
uint64_t residentBytes(void* address, uint64_t bytes, NSMutableDictionary* detail = nil) {
  require(vm_page_size && bytes % vm_page_size == 0, "Residency query is not page aligned");
  std::vector<char> pages(bytes / vm_page_size);
  const CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
  require(mincore(address, bytes, pages.data()) == 0, "Kernel mapping residency measurement failed");
  uint64_t resident = 0, pagedOut = 0;
  for (char page : pages) {
    if (page & MINCORE_INCORE) resident += vm_page_size;
#ifdef MINCORE_PAGED_OUT
    if (page & MINCORE_PAGED_OUT) pagedOut += vm_page_size;
#endif
  }
  if (detail) [detail addEntriesFromDictionary:@{ @"queriedBytes":@(bytes),
    @"residentBytes":@(resident), @"pagedOutBytes":@(pagedOut),
    @"nonresidentBytes":@(bytes - resident), @"pageBytes":@(vm_page_size),
    @"querySeconds":@(CFAbsoluteTimeGetCurrent() - started) }];
  return resident;
}
}
#endif
@interface RelayProbeReceiver : NSObject <NeoSwapPageRelayProbeProtocol>
@property(nonatomic, strong) NSXPCConnection* connection;
@property(nonatomic, strong) NeoSwapPageRelayHandler* handler;
@end
@implementation RelayProbeReceiver
- (void)beginRelayProbe:(NSDictionary*)metadata {
  if ([metadata[@"probeWaitOnly"] isEqual:@YES]) return;
  if ([metadata[@"probeLate"] isEqual:@YES]) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
      [self.handler beginProbeWithConnection:self.connection metadata:metadata];
    }); return;
  }
  [self.handler beginProbeWithConnection:self.connection metadata:metadata];
}
@end
@interface RelayProbeListener : NSObject <NSXPCListenerDelegate>
@end
@implementation RelayProbeListener
- (BOOL)listener:(NSXPCListener*)listener shouldAcceptNewConnection:(NSXPCConnection*)connection {
  (void)listener;
  if (connection.processIdentifier <= 0 || connection.processIdentifier == getpid() || connection.effectiveUserIdentifier != geteuid()) return NO;
  RelayProbeReceiver* receiver = [RelayProbeReceiver new];
  receiver.connection = connection; receiver.handler = [NeoSwapPageRelayHandler new];
  connection.exportedObject = receiver;
  connection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(NeoSwapPageRelayProbeProtocol)];
  [connection resume]; return YES;
}
@end
#if !defined(NEOSWAP_RELAY_EXTENSION)
@interface NeoSwapPageRelaySession (ProbeMetadata)
- (NSDictionary*)requestMetadata;
@end
@interface RelayBadNonceSession : NeoSwapPageRelaySession
@end
@implementation RelayBadNonceSession
- (NSDictionary*)requestMetadata {
  NSMutableDictionary* value = [[super requestMetadata] mutableCopy]; value[@"nonce"] = NSUUID.UUID.UUIDString; return value;
}
@end
@interface RelayBadGenerationSession : NeoSwapPageRelaySession
@end
@implementation RelayBadGenerationSession
- (NSDictionary*)requestMetadata {
  NSMutableDictionary* value = [[super requestMetadata] mutableCopy]; value[@"generation"] = @([value[@"generation"] unsignedLongLongValue] + 1); return value;
}
@end
@interface RelayWaitSession : NeoSwapPageRelaySession
@end
@implementation RelayWaitSession
- (NSDictionary*)requestMetadata {
  NSMutableDictionary* value = [[super requestMetadata] mutableCopy]; value[@"probeWaitOnly"] = @YES; return value;
}
@end
@interface RelayLateSession : NeoSwapPageRelaySession
@end
@implementation RelayLateSession
- (NSDictionary*)requestMetadata {
  NSMutableDictionary* value = [[super requestMetadata] mutableCopy]; value[@"probeLate"] = @YES; return value;
}
@end

static NSDictionary* checkRejected(Class type, uint64_t generation, BOOL cancel) {
  dispatch_semaphore_t changed = dispatch_semaphore_create(0);
  __block NSUInteger count = 0;
  __block BOOL published = NO;
  __block NSError* failure = nil;
  NeoSwapPageRelaySession* session = [[type alloc] initWithHelperIdentifier:@"probe"
    requestedBytes:MiB generation:generation timeout:1
    completion:^(NSArray* handles, int32_t pid, uint64_t actualGeneration, NSError* error) {
      (void)pid; (void)actualGeneration; ++count; published = handles.count != 0; failure = error;
      dispatch_semaphore_signal(changed);
    }];
  [session startWithServiceNameForProbe:serviceName];
  if (cancel) [session cancel];
  require(dispatch_semaphore_wait(changed, dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC)) == 0,
      "Rejected relay scenario did not complete within its deadline");
  require(failure && !published && count == 1, "Failed relay published handles or lost its exact-once failure");
  if (type == RelayLateSession.class) {
    dispatch_semaphore_t late = dispatch_semaphore_create(0);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ dispatch_semaphore_signal(late); });
    require(dispatch_semaphore_wait(late, dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC)) == 0, "Late callback wait failed");
    // Reading diagnostics synchronizes with the session queue before checking.
    require([[session diagnostics][@"stage"] isEqual:@"failed"] && count == 1 && !published,
        "Late callback resurrected expired relay preparation");
  }
  return @{@"scenario":NSStringFromClass(type), @"cancelled":@(cancel), @"publishedHandles":@(published),
    @"completionCount":@(count), @"errorCode":@(failure.code), @"passed":@YES};
}

static NSArray<NeoSwapPageRelayHandle*>* prepare(uint64_t bytes, uint64_t generation, int32_t* pid, NSDictionary** diagnostics) {
  dispatch_semaphore_t changed = dispatch_semaphore_create(0);
  __block NSArray<NeoSwapPageRelayHandle*>* handles = nil;
  __block NSError* failure = nil;
  __block int32_t creator = 0;
  NeoSwapPageRelaySession* session = [[NeoSwapPageRelaySession alloc] initWithHelperIdentifier:@"probe"
    requestedBytes:bytes generation:generation timeout:20
    completion:^(NSArray<NeoSwapPageRelayHandle*>* received, int32_t source, uint64_t actualGeneration, NSError* error) {
      require(actualGeneration == generation, "Relay changed the generation at completion");
      handles = received; creator = source; failure = error; dispatch_semaphore_signal(changed);
    }];
  [session startWithServiceNameForProbe:serviceName];
  require(dispatch_semaphore_wait(changed, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)) == 0,
      "Real relay preparation did not finish");
  *diagnostics = [session diagnostics];
  if (failure) std::fprintf(stderr, "Relay error: %s\n", failure.localizedDescription.UTF8String);
  require(!failure && handles.count && creator > 0 && creator != getpid(), "Real relay preparation failed");
  require([(*diagnostics)[@"creatorExitObserved"] isEqual:@YES] &&
      [(*diagnostics)[@"exitEvidence"] isEqual:@"kernel_dispatch_proc_exit"],
      "Relay completed without actual kernel creator-exit evidence");
  *pid = creator; return handles;
}

#endif
int main(int argc, const char* argv[]) {
  @autoreleasepool {
    if ([[NSBundle.mainBundle objectForInfoDictionaryKey:@"NeoSwapRelayProbeService"] isEqual:@YES]) {
      RelayProbeListener* delegate = [RelayProbeListener new];
      NSXPCListener* listener = NSXPCListener.serviceListener; listener.delegate = delegate; [listener resume]; return 2;
    }
#if defined(NEOSWAP_RELAY_EXTENSION)
    (void)argc; (void)argv; return 3;
#else
    reportPath = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : nil;
    evidence = [@{@"schema":@1, @"platform":@"macOS-real-NSXPC-creator-exit", @"passed":@NO,
      @"iphoneExtensionValidated":@NO, @"realRPCS3GameValidated":@NO, @"hostPID":@(getpid()),
      @"capacityBytes":@0, @"actualWrittenBytes":@0, @"reservedVirtualBytesClaimedAsRAM":@0} mutableCopy];
    evidence[@"negativeScenarios"] = @[
      checkRejected(RelayBadNonceSession.class, 701, NO), checkRejected(RelayBadGenerationSession.class, 702, NO),
      checkRejected(RelayWaitSession.class, 703, NO), checkRejected(RelayLateSession.class, 704, NO),
      checkRejected(RelayWaitSession.class, 705, YES)];
    constexpr uint64_t target = 1024 * MiB;
    int32_t creator = 0; NSDictionary* diagnostics = nil;
    NSArray<NeoSwapPageRelayHandle*>* handles = prepare(target, 706, &creator, &diagnostics);
    evidence[@"session"] = diagnostics; evidence[@"creatorPID"] = @(creator);
    evidence[@"creatorExitObserved"] = @YES;
    require(handles.count == 2 && handles[0].capacityBytes == 512 * MiB && handles[1].capacityBytes == 512 * MiB,
      "Relay did not return two distinct 512-MiB entries");
    const NeoSwapRelayAPI* api = NeoSwap_GetRelayAPI(NEOSWAP_RELAY_ABI);
    require(api && api->struct_size == sizeof(*api), "Relay ABI unavailable");
    require(neostation::relay::configure(1) == 0, "Relay backend configuration failed");
    for (NeoSwapPageRelayHandle* handle in handles)
      require(neostation::relay::adopt(handle.memoryEntry, handle.capacityBytes, creator, 706) == 0,
        "Backend did not retain the post-exit entry");
    handles = nil;
    NeoSwapRelayStats stats{}; stats.struct_size = sizeof(stats);
    require(api->snapshot(&stats) == 0 && stats.capacity_bytes == target && stats.live_bytes == 0,
      "Retained capacity was incorrectly reported as live allocation");
    evidence[@"capacityBytes"] = @(stats.capacity_bytes); evidence[@"entryCount"] = @(stats.entry_count);
    neostation::donation::Footprint before{}, after{};
    require(static_cast<bool>(neostation::donation::footprint(before)), "Host footprint baseline failed");
    evidence[@"systemMemoryBeforeWrite"] = systemMemorySample();
    uint64_t tokens[2]{}; void* views[2][2]{};
    for (unsigned segment = 0; segment < 2; ++segment) {
      require(api->create(0, 512 * MiB, &tokens[segment]) == 0, "Relay token creation failed");
      require(api->map(tokens[segment], nullptr, NEOSWAP_RELAY_READ_WRITE, &views[segment][0]) == 0 &&
        api->map(tokens[segment], nullptr, NEOSWAP_RELAY_READ, &views[segment][1]) == 0,
        "Two genuine aliases of the same token could not be mapped");
      require(views[segment][0] != views[segment][1], "Alias mappings unexpectedly share a virtual address");
      uint64_t* destination = static_cast<uint64_t*>(views[segment][0]);
      for (uint64_t word = 0; word < 512 * MiB / sizeof(uint64_t); ++word)
        destination[word] = pattern(word * sizeof(uint64_t), segment);
    }
    const CFAbsoluteTime verificationStarted = CFAbsoluteTimeGetCurrent();
    for (unsigned segment = 0; segment < 2; ++segment) {
      const uint64_t* alias = static_cast<const uint64_t*>(views[segment][1]);
      for (uint64_t word = 0; word < 512 * MiB / sizeof(uint64_t); ++word)
        require(alias[word] == pattern(word * sizeof(uint64_t), segment), "Shared alias did not contain the full post-exit write");
    }
    evidence[@"verificationSeconds"] = @(CFAbsoluteTimeGetCurrent() - verificationStarted);
    evidence[@"systemMemoryBeforeResidency"] = systemMemorySample();
    // One compact measurement interval across both unique backing views. Do
    // not add a sample before verifying another 512 MiB: that is a sum of
    // different points in time, not evidence of a full live working set.
    const CFAbsoluteTime residencyStarted = CFAbsoluteTimeGetCurrent();
    NSMutableArray* residencyDetails = [NSMutableArray array];
    uint64_t resident = 0;
    for (unsigned segment = 0; segment < 2; ++segment) {
      NSMutableDictionary* detail = [NSMutableDictionary dictionary];
      resident += residentBytes(views[segment][0], 512 * MiB, detail);
      detail[@"segment"] = @(segment); [residencyDetails addObject:detail];
    }
    evidence[@"residencyDetails"] = residencyDetails;
    evidence[@"residencyMeasurementSeconds"] = @(CFAbsoluteTimeGetCurrent() - residencyStarted);
    require(static_cast<bool>(neostation::donation::footprint(after)), "Host footprint after writes failed");
    const uint64_t footprintDelta = after.physical > before.physical ? after.physical - before.physical : 0;
    const uint64_t nonvolatileDelta = after.nonvolatile > before.nonvolatile ? after.nonvolatile - before.nonvolatile : 0;
    evidence[@"actualWrittenBytes"] = @(target); evidence[@"aliasesMatched"] = @YES;
    evidence[@"residentBytesMeasured"] = @(resident); evidence[@"residencySource"] = @"kernel_mincore_unique_backing_view";
    evidence[@"hostFootprintBefore"] = @(before.physical); evidence[@"hostFootprintAfter"] = @(after.physical);
    evidence[@"hostFootprintDelta"] = @(footprintDelta); evidence[@"hostNonvolatileDelta"] = @(nonvolatileDelta);
    require(resident >= target - MiB && resident <= target, "Post-exit relay pages are not resident within 1-MiB tolerance");
    require(footprintDelta < 64 * MiB && nonvolatileDelta < MiB, "Relay pages were charged to the host like ordinary RAM");
    require(api->snapshot(&stats) == 0 && stats.live_bytes == target && stats.alias_count == 4 &&
        stats.mapped_alias_bytes == target * 2, "Relay live token/alias accounting is incorrect");
    for (unsigned segment = 0; segment < 2; ++segment) {
      require(api->release(tokens[segment]) == NEOSWAP_RELAY_BUSY, "Relay released a token with a live alias");
      for (void* view : views[segment]) require(api->unmap(tokens[segment], view) == 0, "Relay alias retirement failed");
      require(api->release(tokens[segment]) == 0, "Relay token release/scrub failed");
    }
    require(api->snapshot(&stats) == 0 && stats.live_bytes == 0 && stats.alias_count == 0, "Relay retained live loans after release");
    evidence[@"liveBytesAfterRelease"] = @(stats.live_bytes); evidence[@"aliasesAfterRelease"] = @(stats.alias_count);
    checkFixedReservation(api);
    uint64_t reused = 0; void* reusedView = nullptr;
    require(api->create(0, 512 * MiB, &reused) == 0 &&
      api->map(reused, nullptr, NEOSWAP_RELAY_READ_WRITE, &reusedView) == 0, "Relay interval could not be reused");
    const uint64_t* scrubbed = static_cast<const uint64_t*>(reusedView);
    for (uint64_t word = 0; word < 512 * MiB / sizeof(uint64_t); ++word)
      require(scrubbed[word] == 0, "Released relay interval exposed stale guest data");
    evidence[@"reusedIntervalZeroed"] = @YES;
    require(api->unmap(reused, reusedView) == 0 && api->release(reused) == 0 && neostation::relay::shutdown() == 0,
      "Relay final cleanup failed");
    require(api->snapshot(&stats) == 0 && stats.retained_capacity_bytes == 0 && stats.pending_cleanup_entries == 0,
      "Relay retained resources after shutdown");
    // Separate capacity experiment: 16 genuine 512-MiB named objects, but
    // only 64 KiB touched in each one. Never label its 8-GiB capacity resident.
    constexpr uint64_t largeCapacity = 8 * 1024 * MiB;
    constexpr uint64_t sampledPerSegment = 64 * 1024;
    int32_t capacityCreator = 0; NSDictionary* capacityDiagnostics = nil;
    NSArray<NeoSwapPageRelayHandle*>* capacityHandles = prepare(largeCapacity, 707, &capacityCreator, &capacityDiagnostics);
    require(capacityCreator != creator && capacityHandles.count == 16, "8-GiB preparation did not produce a new creator and 16 entries");
    require(neostation::relay::configure(1, largeCapacity) == 0, "8-GiB relay backend configuration failed");
    for (NeoSwapPageRelayHandle* handle in capacityHandles)
      require(handle.capacityBytes == 512 * MiB &&
        neostation::relay::adopt(handle.memoryEntry, handle.capacityBytes, capacityCreator, 707) == 0,
        "8-GiB relay adoption failed");
    capacityHandles = nil;
    require(api->snapshot(&stats) == 0 && stats.capacity_bytes == largeCapacity && stats.entry_count == 16,
      "8-GiB relay capacity accounting is incorrect");
    uint64_t largeTokens[16]{}; void* largeViews[16][2]{};
    uint64_t sampleResident = 0;
    for (unsigned segment = 0; segment < 16; ++segment) {
      require(api->create(0, 512 * MiB, &largeTokens[segment]) == 0 &&
        api->map(largeTokens[segment], nullptr, NEOSWAP_RELAY_READ_WRITE, &largeViews[segment][0]) == 0 &&
        api->map(largeTokens[segment], nullptr, NEOSWAP_RELAY_READ, &largeViews[segment][1]) == 0,
        "8-GiB relay could not map every segment and its alias");
      uint64_t* writer = static_cast<uint64_t*>(largeViews[segment][0]);
      const uint64_t* reader = static_cast<const uint64_t*>(largeViews[segment][1]);
      for (uint64_t word = 0; word < sampledPerSegment / sizeof(uint64_t); ++word)
        writer[word] = pattern(word * sizeof(uint64_t), segment + 100);
      for (uint64_t word = 0; word < sampledPerSegment / sizeof(uint64_t); ++word)
        require(reader[word] == pattern(word * sizeof(uint64_t), segment + 100),
          "8-GiB relay sample did not alias the correct segment");
      sampleResident += residentBytes(largeViews[segment][0], sampledPerSegment);
    }
    require(api->snapshot(&stats) == 0 && stats.live_bytes == largeCapacity && stats.alias_count == 32,
      "8-GiB backing interval/alias accounting failed");
    for (unsigned segment = 0; segment < 16; ++segment) {
      for (void* view : largeViews[segment])
        require(api->unmap(largeTokens[segment], view) == 0, "8-GiB relay sample alias cleanup failed");
      require(api->release(largeTokens[segment]) == 0, "8-GiB relay sample release failed");
    }
    require(api->snapshot(&stats) == 0 && stats.live_bytes == 0 && stats.alias_count == 0,
      "8-GiB relay sample retained active objects");
    require(neostation::relay::shutdown() == 0 && api->snapshot(&stats) == 0 &&
      stats.retained_capacity_bytes == 0 && stats.pending_cleanup_entries == 0,
      "8-GiB relay sample retained resources after shutdown");
    evidence[@"capacity8GiB"] = @{@"passed":@YES, @"requestedCapacityBytes":@(largeCapacity),
      @"capacityBytes":@(largeCapacity), @"entryCount":@16, @"segmentBytes":@(512 * MiB),
      @"creatorPID":@(capacityCreator), @"creatorExitObserved":@YES, @"session":capacityDiagnostics,
      @"actualWrittenBytes":@(sampledPerSegment * 16), @"perSegmentWrittenBytes":@(sampledPerSegment),
      @"aliasesMatched":@YES, @"residentBytesForSample":@(sampleResident),
      @"fullCapacityResidentValidated":@NO, @"liveBytesAfterRelease":@0,
      @"retainedBytesAfterShutdown":@(stats.retained_capacity_bytes)};
    int32_t nextCreator = 0; NSDictionary* nextDiagnostics = nil;
    NSArray* next = prepare(MiB, 708, &nextCreator, &nextDiagnostics);
    require(next.count == 1 && nextCreator != capacityCreator, "Relay fresh preparation reused an exited creator process");
    evidence[@"relaunch"] = nextDiagnostics; evidence[@"relaunchSucceeded"] = @YES;
    next = nil;
    evidence[@"passed"] = @YES; saveReport();
    std::printf("PASS: 1 GiB fully written after creator exit; separate 8 GiB capacity with 1 MiB sampled; aliases/cleanup/relaunch verified\n");
    return 0;
#endif
  }
}
