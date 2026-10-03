/* GPL-3.0-or-later. Use the pinned upstream RZIP/RASTATE implementations. */
#include "NeoRetroArchStateImport.h"
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <streams/file_stream.h>
#include <streams/rzip_stream.h>
#include "content.h"

NeoRetroArchStateImportResult NeoRetroArch_ImportStateFile(
    const char *path, size_t maximumDecodedBytes) {
  uint8_t header[20] = {0};
  int64_t read;
  RFILE *file;
  rzipstream_t *stream;
  void *data;
  int64_t decoded;
  bool accepted;
  if (!path || !*path || maximumDecodedBytes < 8)
    return NEO_RA_STATE_IMPORT_INVALID_SIZE;
  file = filestream_open(path, RETRO_VFS_FILE_ACCESS_READ, 0);
  if (!file) return NEO_RA_STATE_IMPORT_OPEN_FAILED;
  read = filestream_read(file, header, sizeof(header));
  filestream_close(file);
  if (read < 0) return NEO_RA_STATE_IMPORT_READ_FAILED;
  /* Upstream treats an unknown RZIP version as raw data. Reject it explicitly
   * instead of passing a compressed header to a core's unserializer. */
  if (read >= 6 && memcmp(header, "#RZIPv", 6) == 0) {
    uint32_t chunk;
    uint64_t total = 0;
    unsigned i;
    if (read < 20 || header[7] != '#') return NEO_RA_STATE_IMPORT_READ_FAILED;
    if ((header[6] != 1 && header[6] != 2) ||
        !rzipstream_codec_available(header[6] == 2 ? RZIP_CODEC_ZSTD : RZIP_CODEC_DEFLATE))
      return NEO_RA_STATE_IMPORT_UNSUPPORTED_CODEC;
    chunk = (uint32_t)header[8] | ((uint32_t)header[9] << 8) |
        ((uint32_t)header[10] << 16) | ((uint32_t)header[11] << 24);
    for (i = 0; i < 8; i++) total |= (uint64_t)header[12+i] << (8*i);
    /* Normal RetroArch writers use 128 KiB chunks. Bound scratch buffers as
     * well as the total decoded size before the decoder allocates them. */
    if (!chunk || chunk > 4 * 1024 * 1024 || total < 8 || total > maximumDecodedBytes)
      return NEO_RA_STATE_IMPORT_INVALID_SIZE;
  }
  stream = rzipstream_open(path, RETRO_VFS_FILE_ACCESS_READ);
  if (!stream) return NEO_RA_STATE_IMPORT_READ_FAILED;
  decoded = rzipstream_get_size(stream);
  if (decoded < 8 || (uint64_t)decoded > maximumDecodedBytes) {
    rzipstream_close(stream);
    return NEO_RA_STATE_IMPORT_INVALID_SIZE;
  }
  data = malloc((size_t)decoded);
  if (!data) {
    rzipstream_close(stream);
    return NEO_RA_STATE_IMPORT_ALLOCATION_FAILED;
  }
  read = rzipstream_read(stream, data, decoded);
  rzipstream_close(stream);
  if (read != decoded) {
    free(data);
    return NEO_RA_STATE_IMPORT_READ_FAILED;
  }
  accepted = content_deserialize_state(data, (size_t)decoded);
  free(data);
  return accepted ? NEO_RA_STATE_IMPORT_OK : NEO_RA_STATE_IMPORT_DESERIALIZE_FAILED;
}
