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
 std::cout<<"PASS: strict Gecko/AR/INI/PNACH parsing, region headers, placeholders, bounds, no activation input\n";
}
