#include "DOLTextureZip.h"
#include <cassert>
int main(int argc,char** argv) {
  assert(argc==3 || argc==4 || argc==5);
  assert(DOLTextures::relative("GR8P69/tex1_a.png","GR8P69")=="tex1_a.png");
  assert(DOLTextures::relative("Load/Textures/GR8P69/sub/tex1_a.dds","GR8P69")=="sub/tex1_a.dds");
  assert(DOLTextures::relative("Fire Emblem/GFE/Portraits/tex1_a.png","GFEP01")=="Portraits/tex1_a.png");
  const auto us=DOLTextures::match("GFEE01/Map and Battle/tex1_a.dds","GFEP01");
  assert(us.source=="GFEE01" && us.otherRegion && us.relative=="Map and Battle/tex1_a.dds");
  assert(DOLTextures::relative("GFEE01/Map and Battle/tex1_a.dds","GFEP01").empty());
  assert(DOLTextures::match("GR8E69/tex1_a.png","GFEP01").relative.empty());
  assert(DOLTextures::match("GFE/GFEE01/tex1_a.png","GFEP01").relative.empty());
  for(const auto* name:{"../GR8P69/tex1_a.png","/GR8P69/tex1_a.png","GR8P69/../tex1_a.png","GR8E69/tex1_a.png","GR8P69/readme.txt","GR8P69/tex1_a.png/../tex1_b.png"})assert(DOLTextures::relative(name,"GR8P69").empty());
  std::ifstream in(argv[1],std::ios::binary);std::vector<DOLTextures::File> files;uint64_t total=0;DOLTextures::Scan scan;
  const std::string game=argc>=4?argv[3]:"GR8P69";
  const bool allowed=argc==5 && std::string(argv[4])=="allow-other-region";
  if(!DOLTextures::list(in,game,files,total,&scan,allowed)) {
    if(scan.valid && !scan.otherRegions.empty())return 4;
    return 2;
  }
  assert(scan.valid && !scan.sources.empty());
  for(const auto& file:files)if(!DOLTextures::extract(in,file,std::filesystem::path(argv[2])/file.relative))return 3;
  return 0;
}
