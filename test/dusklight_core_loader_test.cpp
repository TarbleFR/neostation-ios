#if defined(DUSKLIGHT_LOADER_FIXTURE)
extern "C" int NeoDusklightLoaderFixture() { return 312; }
#else
#include "DusklightCoreLoader.h"
#include <cassert>
#include <iostream>

int main(int argc, char** argv) {
  assert(argc == 3);
  // The fixture is readable but has no executable permission bits.
  struct stat info {};
  assert(stat(argv[1], &info) == 0 && (info.st_mode & 0111) == 0);
  const auto valid = NeoDusklightLoadCore(argv[1]);
  assert(valid.handle && valid.filePresent && valid.detail.empty());
  auto entry = reinterpret_cast<int (*)()>(dlsym(valid.handle, "NeoDusklightLoaderFixture"));
  assert(entry && entry() == 312);

  const auto invalid = NeoDusklightLoadCore(argv[2]);
  assert(!invalid.handle && invalid.filePresent && !invalid.detail.empty());
  const auto missing = NeoDusklightLoadCore((std::string(argv[1]) + ".absent").c_str());
  assert(!missing.handle && !missing.filePresent && !missing.detail.empty());
  const auto empty = NeoDusklightLoadCore("");
  assert(!empty.handle && !empty.filePresent && !empty.detail.empty());
  std::cout << "PASS: load a non-executable dylib; distinguish missing and invalid images; preserve loader errors\n";
}
#endif
