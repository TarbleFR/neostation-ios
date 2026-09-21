"""Exercise the production abort method and real socket reader on macOS."""
from pathlib import Path
import sys, subprocess, tempfile, unittest
ROOT = Path(__file__).resolve().parents[1]
HEADERS = ROOT/'packages/rpcs3_internal_bridge/ios/Classes'

@unittest.skipUnless(sys.platform == 'darwin', 'Foundation required; exercised by macOS CI')
class AbortTests(unittest.TestCase):
    def test_owned_abort_and_unknown_state(self):
        text=(HEADERS/'Rpcs3JitBridgePlugin.mm').read_text()
        session=text[text.index('@interface RPCS3JitSession'):text.index('static NSString* _Nullable RPCS3FindHelperBundleIdentifier')]
        start=text.index('- (void)abortStartup:(void (^)(NSDictionary*))completion {')
        abort=text[start:text.index('- (void)handleMethodCall:',start)]
        harness=r'''
#import <Foundation/Foundation.h>
#import <objc/message.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>
#include <cassert>
#include <cstdio>
#include <functional>
#include <atomic>
#import "Rpcs3Diagnostics.h"
static NSTimeInterval const kRpcs3HelperConnectTimeout = 0.2;
static NSTimeInterval const kRpcs3CompletionTimeout = 2.0;
static std::atomic<int> live{0};
static int RPCS3LiveDebuggerState() { return live; }
static BOOL RPCS3HostHasLiveDebugger() { return live == 1; }
static uint64_t RPCS3DebuggerProbe(uint64_t nonce) { return live == 1 ? nonce + 1 : 0; }
static std::function<void()> detached;
static uint64_t RPCS3DebuggerDetach() { detached(); return 0; }
'''+session+r'''
@interface TestAbortBridge : NSObject
@property(nonatomic,strong) RPCS3JitSession* activeSession;
@property(nonatomic,assign) BOOL operationInProgress;
@property(nonatomic,assign) BOOL completionInProgress;
@property(nonatomic,assign) BOOL transactionClosed;
- (void)abortStartup:(void (^)(NSDictionary*))completion;
@end
@implementation TestAbortBridge { dispatch_queue_t _jitQueue; }
- (instancetype)init {
 if ((self=[super init])) _jitQueue=dispatch_queue_create("abort-test",DISPATCH_QUEUE_SERIAL);
 return self;
}
'''+abort+r'''
@end
static void event(int fd, RPCS3JitSession* session, NSString* type, id pid=nil) {
 NSMutableDictionary* data=[@{@"token":session.token,@"event":type,@"success":@YES} mutableCopy];
 if(pid) data[@"targetPID"]=pid;
 NSMutableData* bytes=[[NSJSONSerialization dataWithJSONObject:data options:0 error:nil] mutableCopy];
 [bytes appendBytes:"\n" length:1];
 assert(write(fd,bytes.bytes,bytes.length)==(ssize_t)bytes.length);
}
static NSDictionary* run(TestAbortBridge* bridge) {
 __block NSDictionary* report=nil; dispatch_semaphore_t sem=dispatch_semaphore_create(0);
 [bridge abortStartup:^(NSDictionary* value){ report=value; dispatch_semaphore_signal(sem); }];
 assert(dispatch_semaphore_wait(sem,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC))==0);
 return report;
}
int main(int argc,char** argv) {
 @autoreleasepool {
 assert(argc==2); RPCS3DiagnosticsSetDirectoryForTesting([NSString stringWithUTF8String:argv[1]]);
 TestAbortBridge* bridge=[TestAbortBridge new];
 live=-1; assert(![run(bridge)[@"success"] boolValue]); // UNKNOWN cannot mean detached
 live=0; assert([run(bridge)[@"success"] boolValue]);
 NSError* error=nil; RPCS3JitSession* session=[[RPCS3JitSession alloc] initWithError:&error];
 session.requiresCoreHandshake=YES; [session startReader];
 int fd=socket(AF_INET,SOCK_STREAM,0); sockaddr_in addr={}; addr.sin_family=AF_INET;
 addr.sin_addr.s_addr=htonl(INADDR_LOOPBACK); addr.sin_port=htons(session.port);
 assert(connect(fd,reinterpret_cast<sockaddr*>(&addr),sizeof(addr))==0);
 event(fd,session,@"helper_connected"); assert([session waitUntilConnected:1]);
 event(fd,session,@"pid_attached",@(getpid())); assert([session waitUntilAttached:1]);
 bridge.activeSession=session; bridge.operationInProgress=YES; live=1;
 detached=[=] { live=0; event(fd,session,@"complete"); };
 auto report=run(bridge);
 fprintf(stderr, "ABORT_RESULT=%s connected=%d attached=%d finished=%d closed=%d live=%d\n",
     report.description.UTF8String, session.connected, session.attached, session.finished, session.closed, live.load());
 assert([report[@"success"] boolValue]&&[report[@"transactionClosed"] boolValue]);
 assert(bridge.transactionClosed&&!bridge.operationInProgress&&!bridge.activeSession);
 close(fd); RPCS3DiagnosticsFlushForTesting();
 }
}
'''
        with tempfile.TemporaryDirectory() as tmp:
            source=Path(tmp)/'test.mm'; exe=str(Path(tmp)/'test');source.write_text(harness)
            subprocess.run(['clang++','-std=c++20','-fobjc-arc','-fblocks','-DRPCS3_DIAGNOSTICS_TESTING=1',
                            '-framework','Foundation','-I',str(HEADERS),str(HEADERS/'Rpcs3Diagnostics.mm'),
                            str(source),'-o',exe],check=True)
            subprocess.run([exe,tmp],check=True,timeout=15)
if __name__=='__main__': unittest.main()
