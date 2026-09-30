#import "NeoSwapMachHandle.h"
#import "NeoSwapDonorIPC.h"
#include "Broker.h"

#include <dlfcn.h>
#include <xpc/xpc.h>

namespace {
using SetRight = void (*)(xpc_object_t, const char*, mach_port_t);
using CopyRight = mach_port_t (*)(xpc_object_t, const char*);
struct Transport {
  SetRight set = reinterpret_cast<SetRight>(
      dlsym(RTLD_DEFAULT, "xpc_dictionary_set_mach_send"));
  CopyRight copy = reinterpret_cast<CopyRight>(
      dlsym(RTLD_DEFAULT, "xpc_dictionary_copy_mach_send"));
};
const Transport& transport() {
  static const Transport instance;
  return instance;
}
constexpr uint64_t maximumCapacity = 256ULL * 1024 * 1024;
bool validCapacity(uint64_t bytes) {
  return bytes && bytes <= maximumCapacity && bytes % vm_page_size == 0;
}
}

@implementation NeoSwapMachHandle {
  mach_port_t _memoryEntry;
  uint64_t _capacityBytes;
  neostation::donation::SendRight _ownedRight;
}

+ (BOOL)supportsSecureCoding { return YES; }
+ (BOOL)isTransportAvailable {
  return transport().set && transport().copy;
}

- (instancetype)initWithMemoryEntry:(mach_port_t)entry
                     capacityBytes:(uint64_t)bytes {
  if (!entry || !validCapacity(bytes) || ![self.class isTransportAvailable]) return nil;
  if ((self = [super init])) {
    // Reserve retry ownership before obtaining the additional user reference.
    if (!_ownedRight.prepare()) return nil;
    if (mach_port_mod_refs(mach_task_self(), entry, MACH_PORT_RIGHT_SEND, 1)
        != KERN_SUCCESS) return nil;
    // prepare() and the non-null entry make this a single-reference adoption.
    if (!_ownedRight.adopt(entry)) return nil;
    _memoryEntry = entry;
    _capacityBytes = bytes;
  }
  return self;
}

- (instancetype)initWithCoder:(NSCoder*)coder {
  if (![coder isKindOfClass:NSXPCCoder.class] || ![self.class isTransportAvailable])
    return nil;
  if ((self = [super init])) {
    auto dictionary = [(NSXPCCoder*)coder decodeXPCObjectOfType:XPC_TYPE_DICTIONARY
                                                      forKey:@"memoryEntry"];
    if (!dictionary) return nil;
    const uint64_t bytes = xpc_dictionary_get_uint64(dictionary, "capacityBytes");
    if (!validCapacity(bytes) || xpc_dictionary_get_uint64(dictionary, "version") != 1)
      return nil;
    if (!_ownedRight.prepare()) return nil;
    // copy_mach_send provides one owned send right in the receiver's namespace.
    const mach_port_t entry = transport().copy(dictionary, "right");
    if (!entry || !_ownedRight.adopt(entry)) return nil;
    _memoryEntry = entry;
    _capacityBytes = bytes;
  }
  return self;
}

- (void)encodeWithCoder:(NSCoder*)coder {
  if (![coder isKindOfClass:NSXPCCoder.class] || ![self.class isTransportAvailable]) {
    [NSException raise:NSInvalidArgumentException
                format:@"NeoSwapMachHandle requires NSXPCCoder Mach-right transport"];
  }
  xpc_object_t dictionary = xpc_dictionary_create(NULL, NULL, 0);
  xpc_dictionary_set_uint64(dictionary, "version", 1);
  xpc_dictionary_set_uint64(dictionary, "capacityBytes", _capacityBytes);
  transport().set(dictionary, "right", _memoryEntry);
  [(NSXPCCoder*)coder encodeXPCObject:dictionary forKey:@"memoryEntry"];
}

- (mach_port_t)memoryEntry { return _memoryEntry; }
- (uint64_t)capacityBytes { return _capacityBytes; }
- (void)dealloc {
  // A failed release stays owned until the C++ holder retries or quarantines
  // the right for Broker::retry_cleanup; it is never silently discarded.
  const auto released = _ownedRight.reset();
  if (!released) NSLog(@"NEOSWAP_MACH_HANDLE_CLEANUP_PENDING stage=%s kernel=%d",
      neostation::donation::stage_name(released.stage), released.kernel_result);
}
@end

NSXPCInterface* NeoSwapDonorHostInterface(void) {
  NSXPCInterface* result = [NSXPCInterface interfaceWithProtocol:
      @protocol(NeoSwapDonorHostProtocol)];
  [result setClasses:[NSSet setWithObject:NeoSwapMachHandle.class]
         forSelector:@selector(donorReady:metadata:reply:) argumentIndex:0 ofReply:NO];
  NSSet* metadataClasses = [NSSet setWithObjects:NSDictionary.class,
      NSString.class, NSNumber.class, NSNull.class, nil];
  [result setClasses:metadataClasses forSelector:@selector(donorReady:metadata:reply:)
       argumentIndex:1 ofReply:NO];
  [result setClasses:metadataClasses forSelector:@selector(donorUpdate:reply:)
       argumentIndex:0 ofReply:NO];
  [result setClasses:metadataClasses forSelector:@selector(donorFailed:reply:)
       argumentIndex:0 ofReply:NO];
  return result;
}

uint64_t NeoSwapDonorPattern(NSString* nonce, uint64_t generation, BOOL host) {
  uint64_t value = 1469598103934665603ULL ^ generation;
  for (const unsigned char* p = reinterpret_cast<const unsigned char*>(nonce.UTF8String);
       p && *p; ++p) value = (value ^ *p) * 1099511628211ULL;
  return value ^ (host ? 0x65d032f793086aabULL : 0xbd150fa4cf720659ULL);
}

uint64_t NeoSwapDonorChunkPattern(NSString* nonce, uint64_t generation,
                                uint64_t chunkIndex, BOOL host) {
  uint64_t value = NeoSwapDonorPattern(nonce, generation, host);
  value ^= (chunkIndex + 1) * 0x9e3779b97f4a7c15ULL;
  value ^= value >> 30;
  value *= 0xbf58476d1ce4e5b9ULL;
  value ^= value >> 27;
  value *= 0x94d049bb133111ebULL;
  return value ^ (value >> 31);
}
