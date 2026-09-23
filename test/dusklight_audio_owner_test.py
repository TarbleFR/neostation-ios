#!/usr/bin/env python3
"""Execute the private SDL iOS session/observer code on macOS Foundation.

Only the hardware queue and AVAudioSession are doubled. In particular,
setActive:YES does not resurrect a host device stopped by setActive:NO.
Pass --source with the pristine SDL file to demonstrate the old failure.
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--source', type=Path, default=ROOT / 'native/dusklight/sdl/src/audio/coreaudio/SDL_coreaudio.m')
parser.add_argument('--expect-host-interference', action='store_true')
args = parser.parse_args()
source = args.source.read_text()
begin = source.index('#else  // iOS-specific section follows.')
end = source.index('\n#endif\n', source.index('static bool UpdateAudioSession', begin))
production = source[begin + len('#else  // iOS-specific section follows.'):end]

fixture = r'''
#import <Foundation/Foundation.h>
#include <cassert>
#include <cstring>
static bool hostDeviceRunning = true;
static int sessionWrites = 0, pauses = 0, resumes = 0;
static NSString* const AVAudioSessionCategoryAmbient = @"ambient";
static NSString* const AVAudioSessionCategorySoloAmbient = @"solo";
static NSString* const AVAudioSessionCategoryPlayback = @"playback";
static NSString* const AVAudioSessionCategoryPlayAndRecord = @"playrecord";
static NSString* const AVAudioSessionCategoryRecord = @"record";
static NSString* const AVAudioSessionModeDefault = @"default";
static NSString* const AVAudioSessionInterruptionNotification = @"interrupt";
static NSString* const AVAudioSessionInterruptionTypeKey = @"type";
static NSString* const UIApplicationDidBecomeActiveNotification = @"active";
static NSString* const UIApplicationWillEnterForegroundNotification = @"foreground";
enum { AVAudioSessionCategoryOptionMixWithOthers = 1,
       AVAudioSessionCategoryOptionDefaultToSpeaker = 2,
       AVAudioSessionCategoryOptionAllowBluetoothA2DP = 8,
       AVAudioSessionCategoryOptionAllowAirPlay = 16,
       AVAudioSessionCategoryOptionDuckOthers = 32,
       AVAudioSessionErrorCodeNone = 0,
       AVAudioSessionErrorCodeResourceNotAvailable = 42,
       AVAudioSessionInterruptionTypeBegan = 1 };
@interface AVAudioSession : NSObject
@property(copy) NSString* category;
@property NSUInteger categoryOptions;
@property BOOL active;
+ (instancetype)sharedInstance;
- (BOOL)setActive:(BOOL)value error:(NSError**)error;
- (BOOL)setCategory:(NSString*)category mode:(NSString*)mode options:(NSUInteger)options error:(NSError**)error;
@end
@implementation AVAudioSession
+ (instancetype)sharedInstance {
    static AVAudioSession* session;
    if (!session) {
        session = [AVAudioSession new]; session.category = AVAudioSessionCategoryAmbient;
        session.categoryOptions = AVAudioSessionCategoryOptionMixWithOthers; session.active = YES;
    }
    return session;
}
- (BOOL)setActive:(BOOL)value error:(NSError**)error {
    (void)error; ++sessionWrites; self.active = value;
    if (!value) hostDeviceRunning = false;
    return YES;
}
- (BOOL)setCategory:(NSString*)category mode:(NSString*)mode options:(NSUInteger)options error:(NSError**)error {
    (void)mode; (void)error; ++sessionWrites; self.category = category; self.categoryOptions = options;
    return YES;
}
@end
struct SDL_PrivateAudioData { void* audioQueue; bool interrupted; CFTypeRef interruption_listener; };
struct SDL_AudioDevice { SDL_PrivateAudioData* hidden; bool recording; };
static SDL_AudioDevice* currentDevice;
static int AudioQueuePause(void* queue) { assert(queue); ++pauses; return 0; }
static int AudioQueueStart(void* queue, void*) { assert(queue); ++resumes; return 0; }
static void SDL_FindPhysicalAudioDeviceByCallback(bool (*cb)(SDL_AudioDevice*, void*), void* data) {
    if (currentDevice) cb(currentDevice, data);
}
#define SDL_zero(value) memset(&(value), 0, sizeof(value))
#define SDL_strcasecmp strcasecmp
#define SDL_HINT_AUDIO_CATEGORY "category"
static const char* SDL_GetHint(const char*) { return nullptr; }
static bool SDL_SetError(const char*, ...) { return false; }
'''

scenarios = r'''
int main() {
  @autoreleasepool {
    AVAudioSession* session = AVAudioSession.sharedInstance;
    NSNotificationCenter* center = NSNotificationCenter.defaultCenter;
    for (int i = 0; i < 100; ++i) {
      SDL_PrivateAudioData hidden{reinterpret_cast<void*>(1), false, nullptr};
      SDL_AudioDevice device{&hidden, false}; currentDevice = &device;
      assert(UpdateAudioSession(&device, true, true));
      if (!hostDeviceRunning || !session.active || sessionWrites != 0) return 42;
      assert([session.category isEqualToString:AVAudioSessionCategoryAmbient]);
      __weak id listener = (__bridge id)hidden.interruption_listener;
      assert(listener != nil);
      [center postNotificationName:AVAudioSessionInterruptionNotification object:session
        userInfo:@{AVAudioSessionInterruptionTypeKey: @(AVAudioSessionInterruptionTypeBegan)}];
      assert(hidden.interrupted && pauses == i + 1);
      // A foreground notification resumes only the queue interrupted above.
      [center postNotificationName:UIApplicationDidBecomeActiveNotification object:nil];
      assert(!hidden.interrupted && resumes == i + 1);
      [center postNotificationName:UIApplicationWillEnterForegroundNotification object:nil];
      assert(resumes == i + 1);
      currentDevice = nullptr;
      assert(UpdateAudioSession(&device, false, true));
      assert(hidden.interruption_listener == nullptr);
      // Listener teardown must sever the device pointer before its storage dies.
      assert(listener == nil);
      device.hidden = nullptr;
      [center postNotificationName:AVAudioSessionInterruptionNotification object:session
        userInfo:@{AVAudioSessionInterruptionTypeKey: @(AVAudioSessionInterruptionTypeBegan)}];
      [center postNotificationName:UIApplicationDidBecomeActiveNotification object:nil];
      assert(pauses == i + 1 && resumes == i + 1);
      assert(hostDeviceRunning && session.active && sessionWrites == 0);
    }
  }
}
'''

# A build must consume the reviewed SDL file, not leave a test-only override.
manifest = json.loads((ROOT / 'native/dusklight/upstream-manifest.json').read_text())
assert 'sdl/src/audio/coreaudio/SDL_coreaudio.m' in manifest
if sys.platform != 'darwin':
    assert '[session setActive:' not in production
    assert '[session setCategory:' not in production
    print('PASS: canonical host-audio ownership contract; SKIP: Foundation behavior test requires macOS CI')
    sys.exit(0)

with tempfile.TemporaryDirectory(prefix='dusklight-audio-owner-') as tmp:
    path = Path(tmp) / 'audio.mm'
    binary = Path(tmp) / 'audio-test'
    path.write_text(fixture + production + scenarios)
    subprocess.run(['xcrun', 'clang++', '-std=c++20', '-fobjc-arc', '-Wall', '-Wextra', '-Werror',
                    '-Wno-unused-function', '-Wno-unused-const-variable', '-Wno-unused-parameter',
                    '-framework', 'Foundation',
                    str(path), '-o', str(binary)], check=True)
    result = subprocess.run([str(binary)], timeout=20)
    assert result.returncode == (42 if args.expect_host_interference else 0), result.returncode
if args.expect_host_interference:
    print('PASS: pristine SDL reproduced the host-audio interference (exit 42)')
    sys.exit(0)
print('PASS: production SDL observer/session code, 100 open/close cycles, host audio survives, no stale listener')
