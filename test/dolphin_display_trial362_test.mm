#include "DolphinDisplayTrial.h"
#include <cassert>
int main(){@autoreleasepool {
 NSFileManager* fm=NSFileManager.defaultManager;
 NSString* root=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
 [fm createDirectoryAtPath:[root stringByAppendingPathComponent:@"Config"] withIntermediateDirectories:YES attributes:nil error:nil];
 NSString* gfx=[root stringByAppendingPathComponent:@"Config/GFX.ini"];
 NSString* original=@"# settings\n[Settings]\nShaderCompilationMode = 0\nMSAA = 4\n[Hardware]\nVSync = False\n[Settings]\nMTLUsePresentDrawable = 2\n";
 [original writeToFile:gfx atomically:YES encoding:NSUTF8StringEncoding error:nil];
 assert(DOLBeginDisplayTrial(root,@"G4BP08",2));
 NSString* trial=[NSString stringWithContentsOfFile:gfx encoding:NSUTF8StringEncoding error:nil];
 assert([DOLIniValue(trial,@"Settings",@"ShaderCompilationMode") isEqual:@"2"]);
 assert([DOLIniValue(trial,@"Settings",@"MTLUsePresentDrawable") isEqual:@"1"]);
 assert([DOLIniValue(trial,@"Hardware",@"VSync") isEqual:@"False"]);
 assert(DOLRestoreDisplayTrial(root));
 assert([[NSString stringWithContentsOfFile:gfx encoding:NSUTF8StringEncoding error:nil] isEqual:original]);
 assert(![fm fileExistsAtPath:[root stringByAppendingPathComponent:@"GameSettings/G4BP08.ini"]]);
 assert(DOLBeginDisplayTrial(root,@"G4BP08",2));assert(DOLBeginDisplayTrial(root,@"G4BP08",1));
 trial=[NSString stringWithContentsOfFile:gfx encoding:NSUTF8StringEncoding error:nil];
 assert([DOLIniValue(trial,@"Settings",@"ShaderCompilationMode") isEqual:@"0"]);
 assert(DOLRestoreDisplayTrial(root));
 NSString* game=[root stringByAppendingPathComponent:@"GameSettings/G4BP08r0.ini"];
 NSString* gameBefore=@"[Video_Settings]\nShaderCompilationMode = 1\n[Gecko]\n$Keep\n04000000 00000001\n";
 [gameBefore writeToFile:game atomically:YES encoding:NSUTF8StringEncoding error:nil];
 assert(DOLBeginDisplayTrial(root,@"G4BP08",2));
 NSString* during=[NSString stringWithContentsOfFile:game encoding:NSUTF8StringEncoding error:nil];
 assert([DOLIniValue(during,@"Video_Settings",@"ShaderCompilationMode") isEqual:@"2"]);
 during=[during stringByAppendingString:@"\n[Gecko]\n$New cheat\n04000004 00000002\n[Gecko_Disabled]\n$New cheat\n"];
 [during writeToFile:game atomically:YES encoding:NSUTF8StringEncoding error:nil];
 trial=[NSString stringWithContentsOfFile:gfx encoding:NSUTF8StringEncoding error:nil];
 trial=DOLIniSet(trial,@"Settings",@"MSAA",@"8");[trial writeToFile:gfx atomically:YES encoding:NSUTF8StringEncoding error:nil];
 assert(DOLRestoreDisplayTrial(root));
 NSString* after=[NSString stringWithContentsOfFile:game encoding:NSUTF8StringEncoding error:nil];
 assert([after containsString:@"$Keep"] && [after containsString:@"$New cheat"]);
 assert([DOLIniValue(after,@"Video_Settings",@"ShaderCompilationMode") isEqual:@"1"]);
 assert(DOLIniValue(after,@"Video_Settings",@"MTLUsePresentDrawable")==NSNull.null);
 after=[NSString stringWithContentsOfFile:gfx encoding:NSUTF8StringEncoding error:nil];
 assert([DOLIniValue(after,@"Settings",@"MSAA") isEqual:@"8"]);
 assert([DOLIniValue(after,@"Settings",@"ShaderCompilationMode") isEqual:@"0"]);
 assert(DOLBeginDisplayTrial(root,@"G4BP08",0));assert(![fm fileExistsAtPath:DOLTrialJournal(root)]);
 assert(!DOLBeginDisplayTrial(root,@"../../other",2));assert(!DOLBeginDisplayTrial(root,@"G4BP08",3));
 [@"{\"schema\":1,\"files\":[{\"path\":\"../../outside\"}]}" writeToFile:DOLTrialJournal(root) atomically:YES encoding:NSUTF8StringEncoding error:nil];
 NSString* unchanged=[NSString stringWithContentsOfFile:gfx encoding:NSUTF8StringEncoding error:nil];
 assert(!DOLRestoreDisplayTrial(root));assert([[NSString stringWithContentsOfFile:gfx encoding:NSUTF8StringEncoding error:nil] isEqual:unchanged]);
 [fm removeItemAtPath:root error:nil];
 NSLog(@"PASS: reversible per-game/GFX render keys, interrupted-launch recovery, no VSync/clock changes, manual cheats and unrelated settings survive");
}return 0;}
