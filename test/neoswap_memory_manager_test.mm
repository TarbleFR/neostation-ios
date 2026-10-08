// Test injected process headroom, real kernel reservations and actual unmapping.
#import "NeoSwapMemoryManager.h"
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <cassert>
#include <cstdio>

static bool mapped(uint64_t pointer) {
    mach_vm_address_t address = pointer;
    mach_vm_size_t bytes = 0;
    vm_region_basic_info_data_64_t info{};
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    const auto result = mach_vm_region(mach_task_self(), &address, &bytes,
        VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &object);
    if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
    return result == KERN_SUCCESS && address <= pointer && pointer - address < bytes;
}
int main() {
    @autoreleasepool {
        constexpr uint64_t MiB = 1024 * 1024;
        [NeoSwapMemoryManager setTestingAvailableMemory:128 * MiB];
        NeoSwapMemoryManager* manager = [[NeoSwapMemoryManager alloc] init];
        assert([manager initializeMemorySystem]);
        assert([manager memoryStatistics][@"reservedMemory"].unsignedLongLongValue == 0);
        assert(![manager allocateMaximumMemory:0]);
        assert(![manager allocateMaximumMemory:UINT64_MAX]);
        [NeoSwapMemoryManager setTestingAvailableMemory:16ULL * 1024 * MiB];
        assert(![manager allocateMaximumMemory:8ULL * 1024 * MiB]);
        [NeoSwapMemoryManager setTestingAvailableMemory:64 * MiB];
        assert(![manager allocateMaximumMemory:MiB]);
        [NeoSwapMemoryManager setTestingAvailableMemory:128 * MiB];
        assert([manager allocateMaximumMemory:MiB]);
        assert([manager allocateMaximumMemory:2 * MiB]);
        NSArray<NSNumber*>* addresses = [manager testingReservationAddresses];
        assert(addresses.count == 2);
        const uint64_t first = addresses[0].unsignedLongLongValue;
        const uint64_t second = addresses[1].unsignedLongLongValue;
        assert(mapped(first) && mapped(second));
        assert([manager memoryStatistics][@"reservedMemory"].unsignedLongLongValue == 3 * MiB);
        [manager releaseMemory:MiB]; // complete last private reservation
        assert(mapped(first) && !mapped(second));
        assert([manager memoryStatistics][@"reservedMemory"].unsignedLongLongValue == MiB);
        [manager releaseMemory:UINT64_MAX];
        assert(!mapped(first));
        assert([manager memoryStatistics][@"reservedMemory"].unsignedLongLongValue == 0);
        assert([manager testingReservationAddresses].count == 0);
        assert([manager memoryStatistics][@"residentMemory"] == NSNull.null);
        [manager releaseMemory:UINT64_MAX]; // repeated cleanup is harmless
        __weak NeoSwapMemoryManager* weakManager;
        uint64_t releasedAtDealloc = 0;
        @autoreleasepool {
            NeoSwapMemoryManager* scoped = [[NeoSwapMemoryManager alloc] init];
            weakManager = scoped;
            assert([scoped allocateMaximumMemory:MiB]);
            releasedAtDealloc = [scoped testingReservationAddresses][0].unsignedLongLongValue;
            assert(mapped(releasedAtDealloc));
        }
        assert(weakManager == nil && !mapped(releasedAtDealloc));
        puts("PASS explicit memory helper: no startup reservation; zero/overflow/ceiling/headroom rejection; real VM map, release and deallocation. Injected headroom, no resident-RAM claim.");
    }
}
