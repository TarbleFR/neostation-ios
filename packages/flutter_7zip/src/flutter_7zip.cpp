#include "flutter_7zip.h"
#include "7zip/C/7zCrc.h"
#include "7zip/C/7z.h"
#include "7zip/C/7zFile.h"
#include <iostream>
#include <fstream>

void *_AllocImp(ISzAllocPtr p, size_t size) {
  return malloc(size);
}

void _FreeImp(ISzAllocPtr p, void *ptr) {
  if (ptr != nullptr) {
    free(ptr);
  }
}

static ISzAlloc AllocImp = { _AllocImp, _FreeImp };

class Archive {
  CFileInStream archiveStream;
  CLookToRead2 lookStream;
  CSzArEx db;
  ISzAlloc allocImp = AllocImp;
  ISzAlloc allocTempImp = AllocImp;

public:
  ArchiveStatus status = kArchiveOK;

  explicit Archive(const char* path) {
    if (InFile_Open(&archiveStream.file, path)) {
      status = kArchiveOpenError;
      return;
    }
    CrcGenerateTable();
    FileInStream_CreateVTable(&archiveStream);
    lookStream.realStream = &archiveStream.vt;
    lookStream.buf = new Byte[16 * 1024];
    lookStream.bufSize = 16 * 1024;
    LookToRead2_CreateVTable(&lookStream, False);
    SzArEx_Init(&db);
    if (const auto res = SzArEx_Open(&db, &lookStream.vt, &allocImp, &allocTempImp); res != SZ_OK) {
      status = kArchiveOpenError;
      File_Close(&archiveStream.file);
    }
  }

  ~Archive() {
    SzArEx_Free(&db, &allocImp);
    File_Close(&archiveStream.file);
    delete [] lookStream.buf;
  }

  uint32_t numFiles() const {
    return db.NumFiles;
  }

  ArchiveFile getFileByIndex(const uint32_t index) const {
    ArchiveFile archiveFile;

    archiveFile.is_dir = SzArEx_IsDir(&db, index) ? 1 : 0;

    const size_t offs = db.FileNameOffsets[index];
    const size_t len = db.FileNameOffsets[index + 1] - offs;
    auto fileName = new uint16_t[len+1];
    for (auto i = 0; i < len; i++) {
      fileName[i] = db.FileNames[offs*2 + i*2] + (db.FileNames[offs*2 + i*2 + 1] << 8);
    }
    fileName[len] = 0;
    archiveFile.name = fileName;

    archiveFile.size = SzArEx_GetFileSize(&db, index);

    if (db.CRCs.Defs[index]) {
      archiveFile.crc32 = db.CRCs.Vals[index];
    } else {
      archiveFile.crc32 = 0;
    }
    
    if (db.CTime.Defs != nullptr) {
      if (db.CTime.Defs[index]) {
        auto [Low, High] = db.CTime.Vals[index];
        archiveFile.cTime = Low + (static_cast<uint64_t>(High) << 32);
      } else {
        archiveFile.cTime = 0;
      }
    } else {
      archiveFile.cTime = 0;
    }

    if (db.MTime.Defs != nullptr) {
      if (db.MTime.Defs[index]) {
        auto [Low, High] = db.MTime.Vals[index];
        archiveFile.mTime = Low + (static_cast<uint64_t>(High) << 32);
      } else {
        archiveFile.mTime = 0;
      }
    } else {
      archiveFile.mTime = 0;
    }

    return archiveFile;
  }

  unsigned char* readFile(const uint32_t index) const {
    const ArchiveFile archiveFile = getFileByIndex(index);
    if (archiveFile.is_dir) {
      return nullptr;
    }
    auto* buffer = new unsigned char[archiveFile.size];
    size_t read = 0;
    uint32_t blockIndex;
    Byte* outBuffer = nullptr;
    size_t outBufferSize;
    size_t offset;
    size_t outSizeProcessed;
    while (read < archiveFile.size) {
      if (const auto res = SzArEx_Extract(&db, &lookStream.vt, index, &blockIndex, &outBuffer, &outBufferSize, &offset, &outSizeProcessed, &allocImp, &allocTempImp); res != SZ_OK) {
        delete[] buffer;
        return nullptr;
      }
      for (auto i = offset; i < outSizeProcessed + offset; i++) {
        buffer[read] = outBuffer[i];
        read++;
      }
      _FreeImp(&allocImp, outBuffer);
    }
    return buffer;
  }

  ArchiveStatus extractFileToPath(const uint32_t index, const char* path) const {
    const ArchiveFile archiveFile = getFileByIndex(index);
    if (archiveFile.is_dir) {
      return kArchiveReadError;
    }
    size_t read = 0;
    uint32_t blockIndex;
    Byte* outBuffer = nullptr;
    size_t outBufferSize;
    size_t offset;
    size_t outSizeProcessed;
    std::ofstream outFile;
    outFile.open(path, std::ios::binary | std::ios::out);
    if (!outFile.is_open()) {
      return kArchiveOpenError;
    }
    if (!outFile.good()) {
      return kArchiveOpenError;
    }
    while (read < archiveFile.size) {
      if (const auto res = SzArEx_Extract(&db, &lookStream.vt, index, &blockIndex, &outBuffer, &outBufferSize, &offset, &outSizeProcessed, &allocImp, &allocTempImp); res != SZ_OK) {
        outFile.close();
        return ArchiveStatus::kArchiveReadError;
      }
      outFile.write(reinterpret_cast<const char *>(outBuffer+offset), outSizeProcessed);
      read += outSizeProcessed;
      _FreeImp(&allocImp, outBuffer);
    }
    outFile.close();
    return kArchiveOK;
  }
};

FFI_PLUGIN_EXPORT void freeArchiveFile(const ArchiveFile archive) {
  delete[] archive.name;
}

FFI_PLUGIN_EXPORT void* openArchive(const char* path) {
  return new Archive{path};
}

FFI_PLUGIN_EXPORT ArchiveStatus checkArchiveStatus(void* archive) {
  const auto a = static_cast<Archive *>(archive);
  return a->status;
}

FFI_PLUGIN_EXPORT void closeArchive(void* archive) {
  delete static_cast<Archive *>(archive);
}

FFI_PLUGIN_EXPORT uint32_t getArchiveFileCount(void* archive) {
  const auto a = static_cast<Archive *>(archive);
  return a->numFiles();
}

FFI_PLUGIN_EXPORT ArchiveFile getArchiveFile(void* archive, uint32_t index) {
  const auto a = static_cast<Archive *>(archive);
  return a->getFileByIndex(index);
}

FFI_PLUGIN_EXPORT unsigned char* readArchiveFile(void* archive, uint32_t index) {
  const auto a = static_cast<Archive *>(archive);
  return a->readFile(index);
}
FFI_PLUGIN_EXPORT void freeReadData(void* p) {
  delete[] static_cast<unsigned char *>(p);
}

FFI_PLUGIN_EXPORT ArchiveStatus extractArchiveToFile(void* archive, uint32_t index, const char* path) {
  const auto a = static_cast<Archive *>(archive);
  return a->extractFileToPath(index, path);
}
