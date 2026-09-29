#include "DOLTextureZip.h"
#include <cassert>
int main(int argc,char** argv) {
  assert(argc==3);
  assert(DOLTextures::relative("GR8P69/tex1_a.png","GR8P69")=="tex1_a.png");
  assert(DOLTextures::relative("Load/Textures/GR8P69/sub/tex1_a.dds","GR8P69")=="sub/tex1_a.dds");
  for(const auto* name:{"../GR8P69/tex1_a.png","/GR8P69/tex1_a.png","GR8P69/../tex1_a.png","GR8E69/tex1_a.png","GR8P69/readme.txt","GR8P69/tex1_a.png/../tex1_b.png"})assert(DOLTextures::relative(name,"GR8P69").empty());
  std::ifstream in(argv[1],std::ios::binary);std::vector<DOLTextures::File> files;uint64_t total=0;
  if(!DOLTextures::list(in,"GR8P69",files,total))return 2;
  for(const auto& file:files)if(!DOLTextures::extract(in,file,std::filesystem::path(argv[2])/file.relative))return 3;
  return 0;
}
