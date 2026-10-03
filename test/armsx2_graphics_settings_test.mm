// Runs the production C adapter with an owned CPU-thread and INI stand-ins.
// No GPU, JIT or gameplay success is inferred from this test.
#import <Foundation/Foundation.h>
#include <algorithm>
#include <cassert>
#include <cstring>
#include <iterator>
#include <string>
#include <stdexcept>
static bool active=true, onCPU=false, saveAllowed=true;
static int reloads=0,retries=0;
struct { std::string resources,data; } state;
auto& runtime(){return state;}
namespace EmuFolders { std::string Settings,GameSettings; }
namespace Path { std::string Combine(const std::string& a,const std::string& b){return a+"/"+b;} }
namespace FileSystem { bool FileExists(const char* p){return [NSFileManager.defaultManager fileExistsAtPath:[NSString stringWithUTF8String:p]];} }
class INISettingsInterface {
 std::string file; NSMutableDictionary* values;
 NSString* k(const char* s,const char* n) const {return [NSString stringWithFormat:@"%s/%s",s,n];}
public:
 INISettingsInterface(std::string f):file(f),values([NSMutableDictionary dictionary]){}
 bool Load(){id loaded=[NSDictionary dictionaryWithContentsOfFile:[NSString stringWithUTF8String:file.c_str()]];if(!loaded)return false;[values addEntriesFromDictionary:loaded];return true;}
 bool Save(){return saveAllowed && [values writeToFile:[NSString stringWithUTF8String:file.c_str()] atomically:YES];}
 std::string GetStringValue(const char* s,const char* n,const char* d){return std::string([(values[k(s,n)] ?: [NSString stringWithUTF8String:d]) description].UTF8String);}
 bool GetBoolValue(const char* s,const char* n,bool d){id v=values[k(s,n)];return v?[v boolValue]:d;}
 void SetStringValue(const char* s,const char* n,const char* v){values[k(s,n)]=[NSString stringWithUTF8String:v];}
 void SetBoolValue(const char* s,const char* n,bool v){values[k(s,n)]=@(v);}
 void SetIntValue(const char* s,const char* n,unsigned v){values[k(s,n)]=@(v);}
 void DeleteValue(const char* s,const char* n){[values removeObjectForKey:k(s,n)];}
};
namespace Host { template<class F> void RunOnCPUThread(F f,bool){assert(!onCPU);onCPU=true;f();onCPU=false;} }
namespace VMManager {
 bool HasValidVM(){return active;}
 std::string GetDiscSerial(){return "SLES-12345";}
 unsigned GetDiscCRC(){return 0x12345678;}
 std::string GetGameSettingsPath(const std::string&,unsigned){return EmuFolders::GameSettings+"/game.ini";}
 void ReloadGameSettings(){assert(onCPU);++reloads;}
}
bool has_running_game(){return active;}
int error_out(const std::string& s,char* out,size_t n){if(out&&n){strncpy(out,s.c_str(),n-1);out[n-1]=0;}return 0;}
@interface ARMSX2Bridge : NSObject
+ (BOOL)isShaderChainSupported;
+ (NSString*)perGameIdentityKeyForCurrentGame;
+ (void)retryShaderChain;
+ (NSString*)getPerGameINIString:(NSString*)s key:(NSString*)k defaultValue:(NSString*)d forISO:(NSString*)iso;
+ (BOOL)getPerGameINIBool:(NSString*)s key:(NSString*)k defaultValue:(BOOL)d forISO:(NSString*)iso;
+ (int)getPerGameINIInt:(NSString*)s key:(NSString*)k defaultValue:(int)d forISO:(NSString*)iso;
+ (NSError*)shaderChainErrorForPreset:(NSString*)path;
+ (NSArray*)extractShaderPackArchiveAtURL:(NSURL*)src toDirectory:(NSURL*)dest error:(NSError**)error;
@end
static NSDictionary* disk(){return [NSDictionary dictionaryWithContentsOfFile:[NSString stringWithUTF8String:VMManager::GetGameSettingsPath("",0).c_str()]];}
@implementation ARMSX2Bridge
+ (BOOL)isShaderChainSupported{return YES;}
+ (NSString*)perGameIdentityKeyForCurrentGame{return @"game";}
+ (void)retryShaderChain{assert(onCPU);++retries;}
+ (NSString*)getPerGameINIString:(NSString*)s key:(NSString*)k defaultValue:(NSString*)d forISO:(NSString*)iso{return disk()[[NSString stringWithFormat:@"%@/%@",s,k]] ?: d;}
+ (BOOL)getPerGameINIBool:(NSString*)s key:(NSString*)k defaultValue:(BOOL)d forISO:(NSString*)iso{id v=disk()[[NSString stringWithFormat:@"%@/%@",s,k]];return v?[v boolValue]:d;}
+ (int)getPerGameINIInt:(NSString*)s key:(NSString*)k defaultValue:(int)d forISO:(NSString*)iso{id v=disk()[[NSString stringWithFormat:@"%@/%@",s,k]];return v?[v intValue]:d;}
+ (NSError*)shaderChainErrorForPreset:(NSString*)path{return nil;}
+ (NSArray*)extractShaderPackArchiveAtURL:(NSURL*)src toDirectory:(NSURL*)dest error:(NSError**)error{return @[];}
@end
#include "ARMSX2GraphicsAssets.inc"
int main(){@autoreleasepool {
 NSString* temp=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
 state.data=temp.UTF8String;state.resources=[temp stringByAppendingPathComponent:@"bundle"].UTF8String;
 EmuFolders::GameSettings=state.data+"/gamesettings";EmuFolders::Settings=state.data+"/inis";
 for(NSString* name in @[@"gamesettings",@"inis",@"bundle/shaders/presets"])
  assert([NSFileManager.defaultManager createDirectoryAtPath:[temp stringByAppendingPathComponent:name] withIntermediateDirectories:YES attributes:nil error:nil]);
 NSString* preset=[temp stringByAppendingPathComponent:@"bundle/shaders/presets/crt.slangp"];
 assert([@"shaders=1" writeToFile:preset atomically:YES encoding:NSUTF8StringEncoding error:nil]);
 INISettingsInterface ini(VMManager::GetGameSettingsPath("",0));ini.SetStringValue("Unrelated","Preserve","yes");assert(ini.Save());
 char error[512]={};
 assert(set_shader_preset("bundle:presets/crt.slangp",error,sizeof(error)));
 assert(reloads==1 && retries==1);
 assert([disk()[@"EmuCore/GS/ShaderChainPreset"] isEqual:preset]);
 assert([disk()[@"EmuCore/GS/ShaderChainPresetRef"] isEqual:@"bundle:presets/crt.slangp"]);
 assert([disk()[@"Unrelated/Preserve"] isEqual:@"yes"]);
 assert(!set_shader_preset("data:../escape.slangp",error,sizeof(error)) && reloads==1);
 assert(set_performance_overlay(3,error,sizeof(error)) && reloads==2);
 assert([disk()[@"EmuCore/GS/OsdShowFrameTimes"] boolValue]);
 assert([disk()[@"EmuCore/GS/OsdPerformancePos"] intValue]==3);
 assert(set_performance_overlay(1,error,sizeof(error)) && reloads==3);
 assert([disk()[@"EmuCore/GS/OsdShowFPS"] boolValue] && ![disk()[@"EmuCore/GS/OsdShowFrameTimes"] boolValue]);
 assert(!set_performance_overlay(4,error,sizeof(error)) && reloads==3);
 saveAllowed=false;assert(!set_shader_preset("",error,sizeof(error)) && reloads==3);saveAllowed=true;
 assert(set_shader_preset("",error,sizeof(error)) && reloads==4);
 assert(!disk()[@"EmuCore/GS/ShaderChainPresetRef"] && ![disk()[@"EmuCore/GS/ShaderChainEnabled"] boolValue]);
 // Re-root cached paths before boot without modifying unrelated settings.
 assert(set_shader_preset("bundle:presets/crt.slangp",error,sizeof(error)));
 ini.Load();ini.SetStringValue("EmuCore/GS","ShaderChainPreset","/old/container/uuid/crt.slangp");assert(ini.Save());
 repair_shader_paths();assert([disk()[@"EmuCore/GS/ShaderChainPreset"] isEqual:preset]);
 [NSFileManager.defaultManager removeItemAtPath:preset error:nil];repair_shader_paths();
 assert(![disk()[@"EmuCore/GS/ShaderChainEnabled"] boolValue]);assert(!disk()[@"EmuCore/GS/ShaderChainPreset"]);
 assert([disk()[@"Unrelated/Preserve"] isEqual:@"yes"]);
 active=false;assert(!set_shader_preset("",error,sizeof(error)));assert(!set_performance_overlay(0,error,sizeof(error)));
 [NSFileManager.defaultManager removeItemAtPath:temp error:nil];
 puts("PASS: production per-game settings; one reload; save failure; OSD flags; container repair; missing preset; inactive session rejection");
}}
