#pragma once

#include <dlfcn.h>
#include <sys/stat.h>
#include <string>

struct NeoDusklightCoreLoadResult {
  void* handle;
  bool filePresent;
  std::string detail;
};

inline bool NeoDusklightCoreFilePresent(const char* path) {
  struct stat info {};
  return path && *path && stat(path, &info) == 0 && S_ISREG(info.st_mode);
}

inline NeoDusklightCoreLoadResult NeoDusklightLoadCore(const char* path) {
  if (!path || !*path) return {nullptr, false, "The framework path is unavailable."};
  // A dylib is mapped, not executed as a process. Let dyld validate the image
  // and its signature; an executable-bit probe is not a presence check.
  void* handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
  if (handle) return {handle, true, {}};
  const char* raw = dlerror();
  const std::string detail = raw ? raw : "The native loader returned no detail.";
  return {nullptr, NeoDusklightCoreFilePresent(path), detail};
}
