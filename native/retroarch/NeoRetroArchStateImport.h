/* GPL-3.0-or-later. Decode existing states without modifying their files. */
#ifndef NEO_RETROARCH_STATE_IMPORT_H
#define NEO_RETROARCH_STATE_IMPORT_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef enum NeoRetroArchStateImportResult {
  NEO_RA_STATE_IMPORT_OK = 0,
  NEO_RA_STATE_IMPORT_OPEN_FAILED,
  NEO_RA_STATE_IMPORT_INVALID_SIZE,
  NEO_RA_STATE_IMPORT_UNSUPPORTED_CODEC,
  NEO_RA_STATE_IMPORT_READ_FAILED,
  NEO_RA_STATE_IMPORT_ALLOCATION_FAILED,
  NEO_RA_STATE_IMPORT_DESERIALIZE_FAILED
} NeoRetroArchStateImportResult;
/* The caller owns the emulation thread. The selected core decides whether the
 * decoded state matches its serialization ABI and current content. */
NeoRetroArchStateImportResult NeoRetroArch_ImportStateFile(
    const char *path, size_t maximumDecodedBytes);
#ifdef __cplusplus
}
#endif
#endif
