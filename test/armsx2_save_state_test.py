#!/usr/bin/env python3
"""Exercise the production slot adapter against the pinned 2.6 declarations.

The bridge fixture reports asynchronous success/failure; no real save file,
VM, device rendering or JIT is validated by this Foundation regression test.
"""
from pathlib import Path
import argparse
import json
import platform
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--upstream', type=Path, required=True)
args = parser.parse_args()
manifest = json.loads((ROOT/'build-utils/armsx2/source.json').read_text())
assert subprocess.check_output(['git', '-C', str(args.upstream), 'rev-parse', 'HEAD'], text=True).strip() == manifest['revision']
header = (args.upstream/'platforms/ios/app/src/main/cpp/ARMSX2Bridge.h').read_text()
declarations = []
for selector in ('saveStateToSlot', 'loadStateFromSlot'):
    declarations.append(re.search(r'\+ \(void\)'+selector+r':.*?;', header, re.S)[0])
if platform.system() != 'Darwin':
    print('Pinned declarations verified; Foundation behavior requires mandatory macOS native CI.')
    raise SystemExit(0)
core = (ROOT/'packages/armsx2_internal_bridge/core/ARMSX2Core.mm').read_text()
start = core.index('int state_operation(')
end = core.index('int get_retroachievements_state_json(', start)
program = r'''
#import <Foundation/Foundation.h>
#include <algorithm>
#include <cassert>
#include <cstring>
@interface ARMSX2Bridge : NSObject
'''+ '\n'.join(declarations) + r'''
@end
static BOOL running=YES, result=YES, deferred=NO;
static NSInteger calls=0, lastSlot=0;
static void (^lateCallback)(BOOL, NSString*)=nil;
static void respond(void (^callback)(BOOL, NSString*)) {
  ++calls;
  if(deferred) { lateCallback=[callback copy]; return; }
  BOOL outcome=result;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0), ^{ callback(outcome,@"upstream-token"); });
}
@implementation ARMSX2Bridge
+ (void)saveStateToSlot:(NSInteger)slot completion:(void (^)(BOOL, NSString*))completion {
  lastSlot=slot;respond(completion);
}
+ (void)loadStateFromSlot:(NSInteger)slot expectedModified:(NSDate*)modified keepingUndo:(BOOL)undo completion:(void (^)(BOOL, NSString*))completion {
  assert(modified==nil && undo==NO);
  lastSlot=slot;respond(completion);
}
@end
static bool has_running_game() { return running; }
static int error_out(const char* text,char* output,size_t capacity) {
  if(output && capacity) snprintf(output,capacity,"%s",text);
  return 0;
}
'''+core[start:end]+r'''
int main() { @autoreleasepool {
  char error[256]{};
  assert(save_state(3,1000,error,sizeof(error))==1 && lastSlot==3);
  assert(load_state(7,1000,error,sizeof(error))==1 && lastSlot==7);
  result=NO;
  assert(save_state(4,1000,error,sizeof(error))==0);
  assert(strstr(error,"could not save"));
  assert(load_state(4,1000,error,sizeof(error))==0);
  assert(strstr(error,"could not load"));
  NSInteger previous=calls;
  assert(save_state(0,1000,error,sizeof(error))==0);
  assert(load_state(11,1000,error,sizeof(error))==0);
  running=NO;assert(save_state(1,1000,error,sizeof(error))==0);
  assert(calls==previous);
  running=YES;deferred=YES;
  assert(load_state(1,1000,error,sizeof(error))==0);
  assert(strstr(error,"timed out"));
  // The completion owns its semaphore and result storage after the wait expires.
  assert(lateCallback);lateCallback(YES,nil);lateCallback=nil;
  deferred=NO;result=YES;
  assert(load_state(2,1000,error,sizeof(error))==1 && lastSlot==2);
  puts("PASS: pinned 2.6 callbacks; save/load outcomes; slot/VM guards; timeout, late completion and recovery");
} }
'''
with tempfile.TemporaryDirectory(prefix='armsx2-save-state-') as directory:
    source=Path(directory)/'test.mm'
    binary=Path(directory)/'test'
    source.write_text(program)
    subprocess.run(['xcrun','clang++','-std=c++20','-fblocks','-fobjc-arc',str(source),'-framework','Foundation','-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True,timeout=10)
