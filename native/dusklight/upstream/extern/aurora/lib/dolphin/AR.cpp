#include <dolphin/ar.h>
#include "../internal.hpp"
#include "dolphin/os.h"

#include <cerrno>
#include <cstdio>
#include <cstdlib>
#if defined(__APPLE__)
#include <sys/mman.h>
#endif

static aurora::Module Log("aurora::ar");

static u32 AR_StackPointer;
static u32* AR_BlockLength;
static u32 AR_FreeBlocks;
static BOOL AR_init_flag;

#define ARAM_STACK_START 0x4000

// ARAM emulation: allocate a large buffer to simulate the GameCube's Auxiliary RAM.
// ARAM "addresses" are offsets into this buffer. On GameCube, ARAM is 16 MB starting
// at a base address returned by ARInit. We emulate this by malloc'ing a buffer
// and using a simple bump allocator (matching ARAlloc behavior on real hardware).
static u8* sAramBuffer = nullptr;
static size_t sAramAllocationSize;

// Convert an ARAM "address" (offset) to a real host pointer
static u8* aramToHost(u32 aramAddr) {
  if (!sAramBuffer || aramAddr >= aurora::g_config.mem2Size) {
    return nullptr;
  }
  return sAramBuffer + aramAddr;
}

u32 ARAlloc(u32 length) {
  u32 tmp;

  ASSERTMSGLINE(430, !(length & 0x1F), "ARAlloc(): length is not multiple of 32bytes!");
  ASSERTMSGLINE(434, length <= (__AR_Size - __AR_StackPointer), "ARAlloc(): Out of ARAM!");
  ASSERTMSGLINE(435, __AR_FreeBlocks, "ARAlloc(): No more free blocks!");

  tmp = AR_StackPointer;
  AR_StackPointer += length;
  *AR_BlockLength = length;
  AR_BlockLength += 1;
  AR_FreeBlocks -= 1;
  return tmp;
}

u32 ARFree(u32* length) {
  AR_BlockLength -= 1;
  if (length) {
    *length = *AR_BlockLength;
  }
  AR_StackPointer -= *AR_BlockLength;
  AR_FreeBlocks += 1;
  return AR_StackPointer;
}

BOOL ARCheckInit(void) { return AR_init_flag; }

u32 ARInit(u32* stack_index_addr, u32 num_entries) {
  if (aurora::g_config.mem2Size == 0) {
    Log.warn("ARInit called but no mem2Size specified in AuroraConfig. ARAM will not be available!");
    return 0;
  }

  if (AR_init_flag == TRUE) {
    return ARAM_STACK_START;
  }

#if defined(__APPLE__)
  errno = 0;
  void* mapped = mmap(nullptr, aurora::g_config.mem2Size, PROT_READ | PROT_WRITE,
                      MAP_PRIVATE | MAP_ANON, -1, 0);
  if (mapped == MAP_FAILED) {
    const int savedErrno = errno;
    fprintf(stderr,
            "NEODUSKLIGHT_VM_ALLOC region=ARAM address=%p size=%u backend=mmap result=-1 errno=%d\n",
            mapped, static_cast<unsigned>(aurora::g_config.mem2Size), savedErrno);
    fflush(stderr);
    sAramBuffer = nullptr;
  } else {
    sAramBuffer = static_cast<u8*>(mapped);
    sAramAllocationSize = aurora::g_config.mem2Size;
    fprintf(stderr,
            "NEODUSKLIGHT_VM_ALLOC region=ARAM address=%p size=%zu backend=mmap result=0 errno=0\n",
            mapped, sAramAllocationSize);
    fflush(stderr);
  }
#else
  sAramBuffer = static_cast<u8*>(calloc(1, aurora::g_config.mem2Size));
  sAramAllocationSize = aurora::g_config.mem2Size;
#endif
  if (sAramBuffer) {
    Log.debug("Initialized 0x{:X} bytes of ARAM!", aurora::g_config.mem2Size);
  } else {
    Log.fatal("Failed to allocate ARAM!");
  }

  AR_StackPointer = ARAM_STACK_START;
  AR_FreeBlocks = num_entries;
  AR_BlockLength = stack_index_addr;

  AR_init_flag = TRUE;
  return AR_StackPointer;
}

// Aurora has no upstream ARAM shutdown because its desktop executable exits.
// NeoStation remains alive to launch another core, so release this 24 MiB
// mapping only after every reader and game worker has stopped.
extern "C" int NeoDusklight_ReleaseARAM() {
  int result = 1;
#if defined(__APPLE__)
  if (sAramBuffer) {
    if (sAramAllocationSize == 0) {
      result = -EINVAL;
    } else {
      errno = 0;
      const int status = munmap(sAramBuffer, sAramAllocationSize);
      const int savedErrno = errno;
      result = status == 0 ? 1 : -(savedErrno == 0 ? EIO : savedErrno);
      fprintf(stderr,
              "NEODUSKLIGHT_VM_RELEASE region=ARAM address=%p size=%zu backend=munmap result=%d errno=%d\n",
              static_cast<void*>(sAramBuffer), sAramAllocationSize, status, savedErrno);
      fflush(stderr);
    }
  }
#else
  free(sAramBuffer);
#endif
  if (result > 0) {
    sAramBuffer = nullptr;
    sAramAllocationSize = 0;
    AR_StackPointer = 0;
    AR_BlockLength = nullptr;
    AR_FreeBlocks = 0;
    AR_init_flag = FALSE;
  }
  return result;
}

u32 ARGetSize(void) { return aurora::g_config.mem2Size; }

#if !defined(_MSC_VER)
#pragma mark ARQ
#endif
void ARQPostRequest(ARQRequest* request, u32 owner, u32 type, u32 priority, uintptr_t source, uintptr_t dest,
                    u32 length, ARQCallback callback) {
  // Emulate ARAM DMA transfers using memcpy.
  // type 0 = MRAM -> ARAM, type 1 = ARAM -> MRAM
  if (type == ARAM_DIR_MRAM_TO_ARAM) {
    // Main RAM -> ARAM: source is a host pointer (cast to u32), dest is an ARAM offset
    u8* hostSrc = (u8*)(uintptr_t)source;
    u8* aramDst = aramToHost(dest);
    if (aramDst && hostSrc) {
      memcpy(aramDst, hostSrc, length);
    }
  } else {
    // ARAM -> Main RAM: source is an ARAM offset, dest is a host pointer (cast to u32)
    u8* aramSrc = aramToHost(source);
    u8* hostDst = (u8*)(uintptr_t)dest;
    if (aramSrc && hostDst) {
      memcpy(hostDst, aramSrc, length);
    }
  }

  // Immediately invoke the callback (synchronous on PC, no DMA latency)
  if (callback) {
    callback((uintptr_t)request);
  }
}

void ARQInit() {
  // Nothing to do on PC - ARAM is initialized in ARInit
}

void* ARGetStorageAddress() {
  return sAramBuffer;
}
