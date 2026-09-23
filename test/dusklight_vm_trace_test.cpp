#include "VirtualMemoryTrace.h"
#include <cassert>
#include <string>

int main() {
  constexpr auto b = NeoDusklightVMHoles::begin;
  constexpr auto e = NeoDusklightVMHoles::end;
  NeoDusklightVMHoles empty;
  empty.finish();
  assert(empty.mapped == 0 && empty.largestHole == e - b);
  NeoDusklightVMHoles map;
  map.observe(0, b + 4096); // clip a region crossing the lower bound
  map.observe(b, 4096); // no double accounting of an overlapping range
  map.observe(b + 8192, 4096);
  map.observe(b + 8192, 0);
  assert(map.mapped == 8192 && map.largestHole == 4096);
  map.observe(b + 12288, e); // clip at upper bound
  map.finish();
  assert(map.mapped == e - b - 4096 && map.largestHole == 4096);
  NeoDusklightVMHoles overflow;
  overflow.observe(b, std::numeric_limits<uint64_t>::max());
  overflow.finish();
  assert(overflow.mapped == e - b && overflow.largestHole == 0);
  overflow.observe(e, 4096);
  assert(overflow.mapped == e - b);
#ifdef __APPLE__
  FILE* file = tmpfile();
  assert(file);
  NeoDusklightTraceVM(file, 0, "test", "read_only");
  assert(ftell(file) > 0);
  rewind(file);
  std::string output;
  char line[2048];
  while (fgets(line, sizeof(line), file)) output += line;
  assert(output.find("complete=1") != std::string::npos);
  assert(output.find("topology=top_level") != std::string::npos);
  fclose(file);
#endif
}
