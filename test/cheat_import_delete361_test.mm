#include "NeoCheatStore.h"
#include <cassert>
int main(){@autoreleasepool {
 NSDictionary* identity=@{@"available":@YES,@"gameId":@"G4BP08",@"revision":@0,@"gecko":@[],@"actionReplay":@[],@"hardcore":@NO};
 NSString* exact=@"6HUF–YY22–P0Y4N\rYP3X–W34H–8N8PU\r7663–4G9D–1BPQZ\r0WGZ–DYX8–MXNED\rGPPV–ZN8B–UVPUX";
 for(NSNumber* encoding in @[@(NSUTF8StringEncoding),@(NSUTF16StringEncoding),@(NSUTF16BigEndianStringEncoding)]) {
   NSData* data=[exact dataUsingEncoding:encoding.unsignedIntegerValue];
   if(encoding.unsignedIntegerValue==NSUTF16BigEndianStringEncoding){unsigned char bom[]={0xFE,0xFF};NSMutableData* bomData=[NSMutableData dataWithBytes:bom length:2];[bomData appendData:data];data=bomData;}
   NSDictionary* decoded=NeoDecodeCheatDocument(data,@"RE4.txt",identity,NO,@"gecko");
   assert([decoded[@"success"] boolValue] && [decoded[@"type"] isEqual:@"actionReplay"]);
   auto codes=NeoCheat::parse([decoded[@"content"] UTF8String],[decoded[@"type"] UTF8String],"Auto Aim","Nikra");
   assert(codes && codes.entries.size()==1 && codes.entries[0].lines.size()==5);
 }
 assert([NeoDecodeCheatDocument([NSData data],@"empty.txt",identity,NO,@"gecko")[@"errorKey"] isEqual:@"emptyFile"]);
 assert([NeoDecodeCheatDocument([@"%PDF-1.7" dataUsingEncoding:NSUTF8StringEncoding],@"test.pdf",identity,NO,@"gecko")[@"errorKey"] isEqual:@"unsupportedFile"]);
 const unsigned char gct[]={0,0xD0,0xC0,0xDE,0,0xD0,0xC0,0xDE,4,0,0,0,0,0,0,1,0xF0,0,0,0,0,0,0,0};
 NSDictionary* decoded=NeoDecodeCheatDocument([NSData dataWithBytes:gct length:sizeof(gct)],@"G4BP08.gct",identity,NO,@"gecko");
 assert([decoded[@"success"] boolValue] && [decoded[@"content"] containsString:@"04000000 00000001"]);
 assert(![NeoDecodeCheatDocument([NSData dataWithBytes:gct length:sizeof(gct)-1],@"G4BP08.gct",identity,NO,@"gecko")[@"success"] boolValue]);
 assert(![NeoDecodeCheatDocument([NSData dataWithBytes:gct length:sizeof(gct)],@"G4BE08.gct",identity,NO,@"gecko")[@"success"] boolValue]);
 NSString* root=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
 NSMutableDictionary* request=[identity mutableCopy];request[@"name"]=@"Aim";request[@"creator"]=@"Nikra";request[@"type"]=@"gecko";request[@"content"]=exact;
 NSString* zero=[NSString stringWithFormat:@"%@%C%@",exact,(unichar)0,@"HIDDEN_INVALID_TAIL"];
 request[@"content"]=zero;assert(![NeoDolphinImport(root,request,identity,NO)[@"success"] boolValue]);request[@"content"]=exact;
 auto result=NeoDolphinImport(root,request,identity,NO);assert([result[@"success"] boolValue]);
 NSString* path=result[@"file"];NSString* initial=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
 assert([initial containsString:@"[ActionReplay]\n$Aim [Nikra]\n6HUF-YY22-P0Y4N"]);
 NSString* extra=@"\n[Core]\nCPUThread=True\n[Gecko]\n$Keep [Other]\n04000000 00000001\n[Gecko_Enabled]\n$Keep\n[ActionReplay_Enabled]\n$Aim [Nikra]\n";
 [[initial stringByAppendingString:extra] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
 request[@"type"]=@"actionReplay";request[@"name"]=@"Aim [Nikra]";
 auto plan=NeoCheatRemovalPlan(root,request,identity,NO);assert([plan[@"success"] boolValue] && NeoCommitCheatRemoval(plan));
 NSString* remaining=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
 assert(![remaining containsString:@"Aim [Nikra]"] && ![remaining containsString:@"6HUF"]);
 assert([remaining containsString:@"$Keep [Other]"] && [remaining containsString:@"CPUThread=True"] && [remaining containsString:@"[Gecko_Enabled]\n$Keep"]);
 assert([[NSFileManager defaultManager] fileExistsAtPath:[path stringByAppendingString:@".before-delete.bak"]]);
 assert(![NeoCheatRemovalPlan(root,request,identity,NO)[@"success"] boolValue]);
 NSDictionary* ps2=@{@"available":@YES,@"serial":@"SLES-00000",@"crc":@"12345678",@"items":@[],@"hardcore":@NO};
 request=[ps2 mutableCopy];request[@"name"]=@"Example";request[@"content"]=@"[First]\npatch=1,EE,00000000,word,00000001\n[Second]\npatch=1,EE,00000004,word,00000002\n";
 result=NeoPnachImport(root,request,ps2);assert([result[@"success"] boolValue]);path=result[@"file"];
 NSString* pnach=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];NSMutableArray* names=[NSMutableArray array];
 for(NSString* line in [pnach componentsSeparatedByString:@"\n"])if([line hasPrefix:@"["])[names addObject:[line substringWithRange:NSMakeRange(1,line.length-2)]];
 request[@"name"]=names[0];plan=NeoCheatRemovalPlan(root,request,ps2,YES);assert(NeoCommitCheatRemoval(plan));
 remaining=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];assert(![remaining containsString:names[0]] && [remaining containsString:names[1]]);
 request[@"name"]=names[1];plan=NeoCheatRemovalPlan(root,request,ps2,YES);assert(NeoCommitCheatRemoval(plan));assert(![[NSFileManager defaultManager] fileExistsAtPath:path]);
 result=NeoPnachImport(root,request,ps2);assert([result[@"success"] boolValue] && [result[@"added"] integerValue]==2);
 [[NSFileManager defaultManager] removeItemAtPath:root error:nil];
 NSLog(@"PASS: exact reported 5-line AR import (UTF-8/UTF-16), GCT, scoped delete, unrelated code/settings preservation, PS2 reimport");
}return 0;}
