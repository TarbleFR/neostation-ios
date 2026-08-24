#include <stdint.h>
#include <stddef.h>

#if _WIN32
#define FFI_PLUGIN_EXPORT __declspec(dllexport)
#else
#define FFI_PLUGIN_EXPORT
#endif

typedef struct {
  uint16_t *name; // utf-16
  size_t size;
  int is_dir;
  uint32_t crc32;
  uint64_t cTime; // create
  uint64_t mTime; // modify
} ArchiveFile;

typedef enum {
  kArchiveOK = 0,
  kArchiveError = 1,
  kArchiveOpenError = 2,
  kArchiveReadError = 3,
  kArchiveWriteError = 4,
  kArchiveSeekError = 5,
} ArchiveStatus;

#ifdef __cplusplus
extern "C" {
#endif
  FFI_PLUGIN_EXPORT void freeArchiveFile(const ArchiveFile archive);

  FFI_PLUGIN_EXPORT void* openArchive(const char* path);

  FFI_PLUGIN_EXPORT ArchiveStatus checkArchiveStatus(void* archive);

  FFI_PLUGIN_EXPORT void closeArchive(void* archive);

  FFI_PLUGIN_EXPORT uint32_t getArchiveFileCount(void* archive);

  FFI_PLUGIN_EXPORT ArchiveFile getArchiveFile(void* archive, uint32_t index);

  FFI_PLUGIN_EXPORT unsigned char* readArchiveFile(void* archive, uint32_t index);

  FFI_PLUGIN_EXPORT void freeReadData(void* p);

  FFI_PLUGIN_EXPORT ArchiveStatus extractArchiveToFile(void* archive, uint32_t index, const char* path);
#ifdef __cplusplus
};
#endif

