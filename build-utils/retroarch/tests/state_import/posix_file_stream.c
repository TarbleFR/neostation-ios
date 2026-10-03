/* Harness-only POSIX adapters. The RZIP container and codec remain upstream. */
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <streams/file_stream.h>
#include <streams/trans_stream.h>

struct RFILE { FILE *file; };
unsigned neo_state_import_open_files;

RFILE *filestream_open(const char *path, unsigned mode, unsigned hints)
{
   RFILE *stream;
   FILE *file;
   const char *flags;
   (void)hints;
   if (!path) return NULL;
   if (mode == RETRO_VFS_FILE_ACCESS_READ) flags = "rb";
   else if (mode == RETRO_VFS_FILE_ACCESS_WRITE) flags = "wb";
   else return NULL;
   file = fopen(path, flags);
   if (!file) return NULL;
   stream = malloc(sizeof(*stream));
   if (!stream) { fclose(file); return NULL; }
   stream->file = file;
   neo_state_import_open_files++;
   return stream;
}

int filestream_close(RFILE *stream)
{
   int result = fclose(stream->file);
   neo_state_import_open_files--;
   free(stream);
   return result;
}

int64_t filestream_read(RFILE *stream, void *data, int64_t size)
{
   size_t count;
   if (size < 0) return -1;
   count = fread(data, 1, (size_t)size, stream->file);
   return ferror(stream->file) ? -1 : (int64_t)count;
}

int64_t filestream_write(RFILE *stream, const void *data, int64_t size)
{
   size_t count;
   if (size < 0) return -1;
   count = fwrite(data, 1, (size_t)size, stream->file);
   return ferror(stream->file) ? -1 : (int64_t)count;
}

int64_t filestream_seek(RFILE *stream, int64_t offset, int origin)
{
   return fseeko(stream->file, (off_t)offset, origin) ? -1 : ftello(stream->file);
}

int64_t filestream_tell(RFILE *stream) { return ftello(stream->file); }
void filestream_rewind(RFILE *stream) { rewind(stream->file); }
int filestream_error(RFILE *stream) { return ferror(stream->file); }
int filestream_eof(RFILE *stream) { return feof(stream->file) ? EOF : 0; }

int64_t filestream_get_size(RFILE *stream)
{
   struct stat value;
   return fstat(fileno(stream->file), &value) ? -1 : value.st_size;
}

bool path_is_valid(const char *path)
{
   struct stat value;
   return path && stat(path, &value) == 0;
}

/* These getters only select the genuine codec objects linked below. */
const struct trans_stream_backend *trans_stream_get_zlib_deflate_backend(void)
{ return &zlib_deflate_backend; }
const struct trans_stream_backend *trans_stream_get_zlib_inflate_backend(void)
{ return &zlib_inflate_backend; }
