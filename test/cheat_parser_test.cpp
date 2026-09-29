#include "NeoCheatParser.h"
#include <cassert>
#include <iostream>
int main(){using namespace NeoCheat;
 auto raw=parse("04000000 00000001\n", "gecko", "Example", "Tester");assert(raw && raw.entries.size()==1 && !raw.entries[0].encrypted);
 assert(!parse("04000000 XXXXXXXX", "gecko", "Example"));
 assert(!parse("04000000 00000001 junk", "gecko", "Example"));
 assert(!parse("1234 00000001", "gecko", "Example"));
 assert(!parse("04000000 00000001", "gecko", "bad\n[section]"));
 auto ar=parse("0123-4567-89ABC", "actionReplay", "Example");assert(ar && ar.entries[0].encrypted);
 assert(!parse("0123-4567-89ABC\n04000000 00000001", "actionReplay", "Example"));
 auto ini=parse("[Other]\nfoo=bar\n[Gecko]\n$One [Author]\n04000000 00000001\n[Gecko_Enabled]\n$One\n[ActionReplay]\n$Two\n0123-4567-89ABC\n", "ini", "Import");
 assert(ini && ini.entries.size()==2 && ini.entries[0].creator=="Author");
 assert(!parse("[Gecko_Enabled]\n$Existing", "ini", "Import"));
 auto patch=parse("[Health]\nauthor=Tester\npatch=1,EE,00000000,extended,00000001 // Comment\n", "pnach", "Import");assert(patch && patch.entries[0].name=="Health");
 assert(!parse("patch=1,EE,00000000,byte,100", "pnach", "Bad"));
 assert(!parse("patch=1,XXX,00000000,word,00000001", "pnach", "Bad"));
 assert(!parse("patch=1,EE,../oops,word,00000001", "pnach", "Bad"));
 assert(!parse(std::string(262145,'a'),"gecko","Big"));
 assert(!parse(std::string("x\0x",3),"gecko","Nul"));
 auto network=geckoDownload("G4BP08\nTitle\n\nExample [Author]\n04000000 00000001\n\nPlaceholders\n04000000 XXXXXXXX\n", "G4BP08");
 assert(network && network.entries.size()==1 && network.entries[0].creator=="Author");
 assert(!geckoDownload("G4BE08\nTitle\n\nExample\n04000000 00000001\n","G4BP08"));
 assert(!geckoDownload("<html>ERROR</html>","G4BP08"));
 assert(parse("patch=3,EE,00000000,extended,00000001", "pnach", "On enable"));
 assert(!parse("patch=1,EE,00000000,extended,00000001,", "pnach", "Trailing comma"));
 assert(!parse("\xEF\xBB\xBF\n", "ini", "BOM only"));
 const std::string screenshot="6HUF-YY22-P0Y4N\nYP3X-W34H-8N8PU\n7663-4G9D-1BPQZ\n0WGZ-DYX8-MXNED\nGPPV-ZN8B-UVPUX";
 auto five=parse(screenshot,"gecko","Auto Aim");
 assert(five && five.entries.size()==1 && five.entries[0].type=="actionReplay" && five.entries[0].lines.size()==5);
 auto copied=parse("6HUF–YY22–P0Y4N\rYP3X–W34H–8N8PU\r7663–4G9D–1BPQZ\r0WGZ–DYX8–MXNED\rGPPV–ZN8B–UVPUX","gecko","");
 assert(copied && copied.entries.size()==1 && copied.entries[0].lines==five.entries[0].lines);
 assert(parse("6HUF-YY22-P0Y4N\n\nYP3X-W34H-8N8PU\n\n7663-4G9D-1BPQZ\n\n0WGZ-DYX8-MXNED\n\nGPPV-ZN8B-UVPUX","gecko","Aim").entries[0].lines.size()==5);
 auto broken=parse("6HUF-YY22-P0Y4N\nYP3X-W34H-8N8PU\n7663-4G9D-1BPQZ\n0WGZ-DYX8-MXNE!\nGPPV-ZN8B-UVPUX","gecko","Aim");
 assert(!broken && broken.line==4 && broken.entries.empty());
 assert(parse("[ActionReplay] Comment\n$Aim [Nikra]\n"+screenshot,"ini","").entries[0].lines.size()==5);
 assert(!parse("XXXXXXXX 00000001\n04000004 00000002", "gecko", "Broken first line"));
 std::cout<<"PASS: strict Gecko/AR/INI/PNACH parsing, region headers, placeholders, bounds, no activation input\n";
}
