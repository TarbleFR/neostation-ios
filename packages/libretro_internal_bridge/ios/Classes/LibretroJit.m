#import "LibretroJit.h"

#include <unistd.h>

int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

#ifndef CS_OPS_STATUS
#define CS_OPS_STATUS 0
#endif
#ifndef CS_DEBUGGED
#define CS_DEBUGGED 0x10000000
#endif

BOOL LibretroHostIsDebugged(void) {
  uint32_t flags = 0;
  if (csops(getpid(), CS_OPS_STATUS, &flags, sizeof(flags)) != 0) return NO;
  return (flags & CS_DEBUGGED) != 0;
}

BOOL LibretroJitUsableByCores(void) {
  if (@available(iOS 26.0, *)) return NO;
  return LibretroHostIsDebugged();
}
