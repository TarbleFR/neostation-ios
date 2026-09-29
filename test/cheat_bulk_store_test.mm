#include "NeoCheatStore.h"
#include <cassert>
static NSString* TestFixture(BOOL ps2){
 NSMutableString* text=[NSMutableString string];
 for(int i=0;i<50;++i) {
  if(ps2)[text appendFormat:@"[Cheat %d]\nauthor=Tester\npatch=1,EE,%08X,word,00000001\npatch=1,EE,%08X,word,00000002\n\n",i,i*8,i*8+4];
  else [text appendFormat:@"Cheat %d [Tester]\n%08X 00000001\n\n%08X 00000002\n\n",i,0x04000000+i*8,0x04000004+i*8];
 }
 return text;
}
static NSMutableDictionary* Request(NSDictionary* identity,NSDictionary* document){
 auto request=[identity mutableCopy];request[@"type"]=document[@"type"];
 request[@"content"]=document[@"content"];request[@"filename"]=document[@"filename"];
 request[@"name"]=@"Imported";request[@"batchImport"]=@YES;return request;
}
int main(){@autoreleasepool {
 NSFileManager* fm=NSFileManager.defaultManager;
 NSString* root=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
 NSDictionary* dolphin=@{@"available":@YES,@"gameId":@"G4BP08",@"revision":@0,@"gecko":@[],@"actionReplay":@[],@"hardcore":@NO};
 NSDictionary* ps2=@{@"available":@YES,@"serial":@"SLES-00000",@"crc":@"12345678",@"items":@[],@"hardcore":@NO};
 NSString* folder=[root stringByAppendingPathComponent:@"GameSettings"];
 [fm createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
 NSString* target=[folder stringByAppendingPathComponent:@"G4BP08r0.ini"];
 NSString* existing=@"[Core]\nCPUThread=True\n[Video_Settings]\nInternalResolution=4\n[Gecko]\n$Existing\n04009999 00000001\n[Gecko_Enabled]\n$Existing\n";
 [existing writeToFile:target atomically:YES encoding:NSUTF8StringEncoding error:nil];
 for(NSNumber* encoding in @[@(NSUTF8StringEncoding),@(NSUTF16StringEncoding)]) {
  auto document=NeoDecodeCheatDocument([TestFixture(NO) dataUsingEncoding:encoding.unsignedIntegerValue],@"G4BP08.txt",dolphin,NO,@"gecko");
  assert([document[@"success"] boolValue] && [document[@"count"] intValue]==50 && [document[@"hasTitles"] boolValue]);
  assert([document[@"entries"] count]==50);
  for(int i=0;i<50;++i){assert([document[@"entries"][i][@"name"] isEqual:[NSString stringWithFormat:@"Cheat %d",i]]);assert([document[@"entries"][i][@"lines"] count]==2);}
 }
 auto document=NeoDecodeCheatDocument([TestFixture(NO) dataUsingEncoding:NSUTF8StringEncoding],@"G4BP08.txt",dolphin,NO,@"gecko");
 auto request=Request(dolphin,document);auto result=NeoDolphinImport(root,request,dolphin,NO);
 assert([result[@"success"] boolValue] && [result[@"added"] intValue]==50 && [result[@"skipped"] intValue]==0);
 NSData* saved=[NSData dataWithContentsOfFile:target];NSString* ini=[[NSString alloc] initWithData:saved encoding:NSUTF8StringEncoding];
 assert([ini hasPrefix:existing]);assert([[NSData dataWithContentsOfFile:[target stringByAppendingString:@".before-import.bak"]] isEqual:[existing dataUsingEncoding:NSUTF8StringEncoding]]);
 auto parsed=NeoCheat::parse(NeoUTF8(ini),"ini","file");assert(parsed && parsed.entries.size()==51);
 for(int i=0;i<50;++i)assert([ini containsString:[NSString stringWithFormat:@"[Gecko_Disabled]\n$Cheat %d\n",i]]);
 result=NeoDolphinImport(root,request,dolphin,NO);assert([result[@"success"] boolValue] && [result[@"added"] intValue]==0 && [result[@"skipped"] intValue]==50);
 assert([[NSData dataWithContentsOfFile:target] isEqual:saved]);
 auto conflict=[request mutableCopy];conflict[@"content"]=[request[@"content"] stringByReplacingOccurrencesOfString:@"04000000 00000001" withString:@"04000000 00000003"];
 result=NeoDolphinImport(root,conflict,dolphin,NO);assert(![result[@"success"] boolValue] && [result[@"entryName"] isEqual:@"Cheat 0"]);assert([[NSData dataWithContentsOfFile:target] isEqual:saved]);
 auto bad=NeoDecodeCheatDocument([[TestFixture(NO) stringByReplacingOccurrencesOfString:@"04000184 00000002" withString:@"04000184 XXXXXXXX"] dataUsingEncoding:NSUTF8StringEncoding],@"G4BP08.txt",dolphin,NO,@"gecko");
 assert(![bad[@"success"] boolValue] && [bad[@"errorLine"] unsignedIntegerValue]>1);
 NSString* wrongHeader=[@"G4BE08\nWrong game\n\n" stringByAppendingString:TestFixture(NO)];
 assert(![NeoDecodeCheatDocument([wrongHeader dataUsingEncoding:NSUTF8StringEncoding],@"export.txt",dolphin,NO,@"gecko")[@"success"] boolValue]);
 auto deletion=[dolphin mutableCopy];deletion[@"type"]=@"gecko";deletion[@"name"]=@"Cheat 17";
 auto plan=NeoCheatRemovalPlan(root,deletion,dolphin,NO);assert([plan[@"success"] boolValue] && NeoCommitCheatRemoval(plan));
 result=NeoDolphinImport(root,request,dolphin,NO);assert([result[@"added"] intValue]==1 && [result[@"skipped"] intValue]==49);
 assert([[NSString stringWithContentsOfFile:target encoding:NSUTF8StringEncoding error:nil] hasPrefix:existing]);
 auto malicious=[request mutableCopy];malicious[@"type"]=@"pnach";malicious[@"content"]=@"[PS2]\npatch=1,EE,00000000,word,00000001";
 assert(![NeoDolphinImport(root,malicious,dolphin,NO)[@"success"] boolValue]);
 // PS2: fifty independent groups in one atomic file, exact-repeat import is a no-op.
 document=NeoDecodeCheatDocument([TestFixture(YES) dataUsingEncoding:NSUTF16StringEncoding],@"12345678.pnach",ps2,YES,@"pnach");
 assert([document[@"success"] boolValue] && [document[@"count"] intValue]==50);
 request=Request(ps2,document);result=NeoPnachImport(root,request,ps2);assert([result[@"success"] boolValue] && [result[@"added"] intValue]==50);
 NSString* pnachPath=result[@"file"];NSData* original=[NSData dataWithContentsOfFile:pnachPath];
 result=NeoPnachImport(root,request,ps2);assert([result[@"success"] boolValue] && [result[@"added"] intValue]==0 && [result[@"skipped"] intValue]==50);assert([[NSData dataWithContentsOfFile:pnachPath] isEqual:original]);
 NSString* pnach=[[NSString alloc] initWithData:original encoding:NSUTF8StringEncoding];NSMutableArray* groups=[NSMutableArray array];
 for(NSString* row in [pnach componentsSeparatedByString:@"\n"])if([row hasPrefix:@"["])[groups addObject:[row substringWithRange:NSMakeRange(1,row.length-2)]];
 assert(groups.count==50);
 deletion=[ps2 mutableCopy];deletion[@"name"]=groups[17];plan=NeoCheatRemovalPlan(root,deletion,ps2,YES);assert(NeoCommitCheatRemoval(plan));
 result=NeoPnachImport(root,request,ps2);assert([result[@"success"] boolValue] && [result[@"added"] intValue]==1 && [result[@"skipped"] intValue]==49);
 NSString* reimported=[NSString stringWithContentsOfFile:result[@"file"] encoding:NSUTF8StringEncoding error:nil];
 assert([reimported containsString:@"/Cheat 17]"] && ![reimported containsString:groups[17]]);
 // Identical duplicates inside one incoming document do not create two rows.
 auto newRoot=[root stringByAppendingPathComponent:@"duplicates"];request=[dolphin mutableCopy];request[@"name"]=@"File";request[@"type"]=@"ini";request[@"batchImport"]=@YES;
 request[@"content"]=@"[Gecko]\n$Same\n04000000 00000001\n$Same\n04000000 00000001";
 result=NeoDolphinImport(newRoot,request,dolphin,NO);assert([result[@"added"] intValue]==1 && [result[@"skipped"] intValue]==1);
 [fm removeItemAtPath:root error:nil];
 NSLog(@"PASS: 50-entry document decode/import, title/line preservation, disabled groups, exact duplicates, conflict atomicity, game identity, single-entry delete/reimport and PS2 fresh identities");
}return 0;}
