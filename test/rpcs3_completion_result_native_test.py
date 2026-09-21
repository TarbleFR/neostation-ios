"""Execute the production completion classifier with injected observations.

This tests reporting and state publication, not debugger attachment on a phone.
"""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

@unittest.skipUnless(sys.platform == 'darwin', 'Foundation required; macOS CI gate')
class CompletionResultTests(unittest.TestCase):
    def test_observed_states_never_become_false_success(self):
        source = (ROOT / 'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3JitBridgePlugin.mm').read_text()
        start = source.index('      const BOOL completed = [session waitUntilFinished:kRpcs3CompletionTimeout];', source.index('isEqualToString:@"completeJit"'))
        end = source.index('      RPCS3Milestone(@"jit_completion_end", message);', start)
        body = source[start:end]
        harness = r'''
#import <Foundation/Foundation.h>
#include <cassert>
#include <cerrno>
static BOOL observedDebugged = YES;
static int observedLive = 0;
static int observedErrno = 0;
static BOOL RPCS3HostIsDebugged() { return observedDebugged; }
static int RPCS3LiveDebuggerState() { errno = observedErrno; return observedLive; }
static NSTimeInterval const kRpcs3CompletionTimeout = 2;
@interface TestSession : NSObject
@property(nonatomic) BOOL waitResult;
@property(nonatomic) BOOL finished;
@property(nonatomic) BOOL success;
@property(nonatomic,copy) NSString* finalMessage;
@property(nonatomic,copy) NSArray* logs;
- (BOOL)waitUntilFinished:(NSTimeInterval)timeout;
@end
@implementation TestSession
- (BOOL)waitUntilFinished:(NSTimeInterval)timeout { return self.waitResult; }
@end
@interface TestBridge : NSObject
@property(nonatomic) BOOL transactionClosed;
- (NSDictionary*)evaluate:(TestSession*)session;
@end
@implementation TestBridge
- (NSDictionary*)evaluate:(TestSession*)session {
''' + body + r'''
return response;
}
@end
int main() {
 @autoreleasepool {
   struct Case { BOOL waited, finished, helper, debugged; int live; const char* code; };
   Case cases[] = {
     {YES,YES,YES,YES,0,"RPCS3_JIT_DETACHED"},
     {NO,NO,NO,YES,1,"RPCS3_JIT_COMPLETION_TIMEOUT"},
     {YES,NO,YES,YES,0,"RPCS3_JIT_COMPLETION_TIMEOUT"},
     {YES,YES,NO,YES,0,"RPCS3_JIT_HELPER_FAILED"},
     {YES,YES,YES,YES,-1,"RPCS3_JIT_DETACH_STATE_UNKNOWN"},
     {YES,YES,YES,YES,1,"RPCS3_JIT_STILL_ATTACHED"},
     {YES,YES,YES,NO,0,"RPCS3_JIT_DEBUG_FLAG_MISSING"},
   };
   TestBridge* bridge = [TestBridge new];
   for (const auto& c : cases) {
     TestSession* session = [TestSession new];
     session.waitResult = c.waited; session.finished = c.finished; session.success = c.helper;
     session.logs = @[]; session.finalMessage = @"Old helper success text must not become the failure description";
     observedDebugged = c.debugged; observedLive = c.live; observedErrno = c.live < 0 ? EACCES : 0;
     bridge.transactionClosed = YES;
     NSDictionary* result = [bridge evaluate:session];
     NSString* code = [NSString stringWithUTF8String:c.code];
     assert([result[@"code"] isEqual:code]);
     BOOL expected = c.waited && c.finished && c.helper && c.debugged && c.live == 0;
     assert([result[@"success"] boolValue] == expected);
     assert([result[@"transactionClosed"] boolValue] == expected);
     assert(bridge.transactionClosed == expected);
     if (!expected) assert([result[@"message"] hasPrefix:[code stringByAppendingString:@":"]]);
     if (c.live < 0) assert([result[@"message"] containsString:@"queryErrno=13"]);
   }
 }
}
'''
        with tempfile.TemporaryDirectory() as temp:
            source_path = Path(temp) / 'completion.mm'
            executable = Path(temp) / 'completion'
            source_path.write_text(harness)
            subprocess.run(['clang++', '-std=c++20', '-fobjc-arc', '-fblocks', '-framework', 'Foundation', str(source_path), '-o', str(executable)], check=True)
            subprocess.run([str(executable)], check=True, timeout=10)

if __name__ == '__main__':
    unittest.main()
