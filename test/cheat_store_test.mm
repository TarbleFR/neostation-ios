#include "NeoCheatStore.h"
#include <cassert>
int main(){@autoreleasepool {
 NSString* root=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
 NSFileManager* fm=NSFileManager.defaultManager;
 NSDictionary* dolphin=@{@"available":@YES,@"gameId":@"G4BP08",@"gameTdbId":@"G4BP08",@"revision":@0,@"hardcore":@NO,@"gecko":@[],@"actionReplay":@[]};
 NSMutableDictionary* request=[dolphin mutableCopy];request[@"type"]=@"gecko";request[@"name"]=@"Test code";request[@"creator"]=@"Author";request[@"content"]=@"04000000 00000001";
 NSString* target=[root stringByAppendingPathComponent:@"GameSettings/G4BP08r0.ini"];
 [fm createDirectoryAtPath:target.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
 NSString* original=@"[Core]\nCPUThread = True\n[Gecko]\n$Existing\n04000004 00000002\n[Gecko_Enabled]\n$Existing\n";
 [original writeToFile:target atomically:YES encoding:NSUTF8StringEncoding error:nil];
 NSDictionary* result=NeoDolphinImport(root,request,dolphin,NO);assert([result[@"success"] boolValue]);
 NSString* saved=[NSString stringWithContentsOfFile:target encoding:NSUTF8StringEncoding error:nil];
 assert([saved hasPrefix:original]);assert([saved containsString:@"[Gecko_Disabled]\n$Test code"]);
 assert([[NSString stringWithContentsOfFile:[target stringByAppendingString:@".before-import.bak"] encoding:NSUTF8StringEncoding error:nil] isEqual:original]);
 request[@"filename"]=@"G4BE08.ini";assert(![NeoDolphinImport(root,request,dolphin,NO)[@"success"] boolValue]);
 request[@"filename"]=@"G4BP08r1.ini";assert(![NeoDolphinImport(root,request,dolphin,NO)[@"success"] boolValue]);
 request[@"filename"]=@"";request[@"revision"]=@1;assert(![NeoDolphinImport(root,request,dolphin,NO)[@"success"] boolValue]);request[@"revision"]=@0;
 NSMutableDictionary* hardcore=[dolphin mutableCopy];hardcore[@"hardcore"]=@YES;assert(![NeoDolphinImport(root,request,hardcore,NO)[@"success"] boolValue]);
 NSMutableDictionary* duplicate=[dolphin mutableCopy];duplicate[@"gecko"]=@[@{@"name":@"Test code"}];assert(![NeoDolphinImport(root,request,duplicate,NO)[@"success"] boolValue]);
 assert([NeoDolphinImport(root,request,duplicate,YES)[@"added"] intValue]==0);
 assert([[NSString stringWithContentsOfFile:target encoding:NSUTF8StringEncoding error:nil] isEqual:saved]);
 NSDictionary* ps2=@{@"available":@YES,@"serial":@"SLES-00000",@"crc":@"ABCDEF12",@"hardcore":@NO,@"items":@[]};
 request=[ps2 mutableCopy];request[@"name"]=@"Test";request[@"content"]=@"patch=1,EE,00000000,extended,00000001";
 result=NeoPnachImport(root,request,ps2);assert([result[@"success"] boolValue]);
 NSString* filename=[result[@"file"] lastPathComponent];assert([filename hasPrefix:@"ABCDEF12-NeoStation-"]);assert(![filename containsString:@"SLES"]);
 NSString* patch=[NSString stringWithContentsOfFile:result[@"file"] encoding:NSUTF8StringEncoding error:nil];assert([patch containsString:@"[NeoStation/ABCDEF12/"] && [patch containsString:@"/Test]"]);
 assert([NeoPnachImport(root,request,ps2)[@"added"] intValue]==0);
 [fm removeItemAtPath:result[@"file"] error:nil];
 result=NeoPnachImport(root,request,ps2);assert([result[@"success"] boolValue]);
 NSString* reimported=[NSString stringWithContentsOfFile:result[@"file"] encoding:NSUTF8StringEncoding error:nil];
 assert(![reimported isEqual:patch]); // old Enable-list identity cannot reactivate a new import.
 assert([NeoCheatDisplayName(@"NeoStation/ABCDEF12/01234567890123456789012345678901/Test") isEqual:@"Test"]);
 request[@"filename"]=@"SLES-00000_11111111.pnach";assert(![NeoPnachImport(root,request,ps2)[@"success"] boolValue]);
 request[@"filename"]=@"SLUS-00000_ABCDEF12.pnach";assert(![NeoPnachImport(root,request,ps2)[@"success"] boolValue]);
 [fm removeItemAtPath:root error:nil];
 NSLog(@"PASS: actual atomic INI/PNACH storage, backups, exact revision/CRC, disabled imports, duplicate and Hardcore guards");
}return 0;}
