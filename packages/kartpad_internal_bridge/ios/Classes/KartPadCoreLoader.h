#pragma once

#ifdef __cplusplus

#include <dlfcn.h>
#include <sys/stat.h>
#include <string>

struct NeoKartPadCoreLoadResult {
  void* handle;
  bool filePresent;
  std::string detail;
};

inline bool NeoKartPadCoreFilePresent(const char* path) {
  struct stat info {};
  return path && *path && stat(path, &info) == 0 && S_ISREG(info.st_mode);
}

inline NeoKartPadCoreLoadResult NeoKartPadLoadCore(const char* path) {
  if (!path || !*path) return {nullptr, false, "The framework path is unavailable."};
  void* handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
  if (handle) return {handle, true, {}};
  const char* raw = dlerror();
  return {nullptr, NeoKartPadCoreFilePresent(path),
          raw ? raw : "The native loader returned no detail."};
}

#endif
