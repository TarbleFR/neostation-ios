/* Portable harness: the selected core receives and validates exact payloads. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "core.h"
#include "NeoRetroArchStateImport.h"
#include <streams/file_stream.h>
#include <streams/rzip_stream.h>

extern unsigned neo_state_import_open_files;
static unsigned core_calls;
static unsigned import_allocations;
static unsigned import_frees;
static void *import_buffer;
static size_t largest_import_allocation;
static int refuse_allocation;
static unsigned char *expected;
static size_t expected_size;

void *neo_state_import_test_malloc(size_t size)
{
   import_allocations++;
   if (size > largest_import_allocation) largest_import_allocation = size;
   if (refuse_allocation) return NULL;
   if (import_buffer) abort();
   import_buffer = malloc(size);
   return import_buffer;
}

void neo_state_import_test_free(void *data)
{
   if (!data || data != import_buffer) abort();
   import_frees++;
   import_buffer = NULL;
   free(data);
}

bool core_unserialize(retro_ctx_serialize_info_t *info)
{
   core_calls++;
   return expected && info && info->data_const &&
      info->size == expected_size &&
      memcmp(info->data_const, expected, expected_size) == 0;
}

static unsigned char *read_fixture(const char *path, size_t *size)
{
   unsigned char *data;
   long length;
   FILE *file = fopen(path, "rb");
   if (!file) return NULL;
   if (fseek(file, 0, SEEK_END) || (length = ftell(file)) < 0 ||
       fseek(file, 0, SEEK_SET)) { fclose(file); return NULL; }
   data = malloc(length ? (size_t)length : 1);
   if (!data) { fclose(file); return NULL; }
   if (fread(data, 1, (size_t)length, file) != (size_t)length) {
      free(data); fclose(file); return NULL;
   }
   fclose(file);
   *size = (size_t)length;
   return data;
}

int main(int argc, char **argv)
{
   if (argc == 4 && strcmp(argv[1], "encode") == 0) {
      size_t size;
      unsigned char *data = read_fixture(argv[2], &size);
      rzipstream_t *stream;
      int64_t written;
      int closed;
      if (!data) return 2;
      rzipstream_set_write_codec(RZIP_CODEC_DEFLATE);
      stream = rzipstream_open(argv[3], RETRO_VFS_FILE_ACCESS_WRITE);
      if (!stream) { free(data); return 3; }
      written = rzipstream_write(stream, data, (int64_t)size);
      closed = rzipstream_close(stream);
      free(data);
      return written == (int64_t)size && closed == 0 &&
         neo_state_import_open_files == 0 ? 0 : 4;
   }
   if (argc == 6 && strcmp(argv[1], "import") == 0) {
      NeoRetroArchStateImportResult result;
      const char *path = strcmp(argv[2], "<null>") ? argv[2] : NULL;
      if (strcmp(argv[3], "-") != 0) {
         expected = read_fixture(argv[3], &expected_size);
         if (!expected) return 2;
      }
      refuse_allocation = atoi(argv[5]);
      result = NeoRetroArch_ImportStateFile(path,
         (size_t)strtoull(argv[4], NULL, 10));
      printf("{\"result\":%d,\"coreCalls\":%u,\"openFiles\":%u,"
         "\"allocations\":%u,\"frees\":%u,\"activeAllocations\":%u,"
         "\"largestAllocation\":%zu}\n", result,
         core_calls, neo_state_import_open_files, import_allocations,
         import_frees, import_buffer ? 1 : 0, largest_import_allocation);
      free(expected);
      return 0;
   }
   fprintf(stderr, "usage: import FILE EXPECTED_OR_- LIMIT FAIL_ALLOCATION; encode IN OUT\n");
   return 1;
}
