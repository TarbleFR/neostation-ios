#include "DOLCheatCatalogue.h"
#include <cassert>
int main(int argc,char** argv){@autoreleasepool {
 NSString* html=@"<title>GCN/WIIRD/PAL</title>[G4BP08]<code>Complete [Tester]\n04000000 00000001\n\nIncomplete [Tester]\n04000004 00000001\n04000008 XXXXXXXX\n</code>";
 auto parsed=DOLForumGecko(html,@"G4BP08");assert(parsed.entries.size()==1 && parsed.entries[0].name=="Complete");
 assert(!DOLForumGecko(html,@"G4BE08"));assert(!DOLForumGecko(@"<html>server error</html>",@"G4BP08"));
 if(argc==2) {
  NSString* live=[NSString stringWithContentsOfFile:[NSString stringWithUTF8String:argv[1]] encoding:NSUTF8StringEncoding error:nil];
  auto codes=DOLForumGecko(live,@"G4BP08");assert(codes && codes.entries.size()>1);
  NSString* ini=NeoEntriesINI(codes.entries);auto roundtrip=NeoCheat::parse(ini.UTF8String,"ini","Catalogue");
  assert(roundtrip && roundtrip.entries.size()==codes.entries.size());
  NSLog(@"PASS: live RE4 PAL author source => %lu complete entries, no placeholder codes, INI round-trip",(unsigned long)codes.entries.size());
 }
 NSLog(@"PASS: catalogue rejects mismatched regions, error pages and incomplete variable codes");
}return 0;}
