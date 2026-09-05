"""Exercise the production JIT helper socket and fresh-attach launch gate.

The app cannot execute an ARM64 BRK in CI. This runs the exact helper reader
and launch gate against real loopback messages, with the persistent kernel
CS_DEBUGGED result deliberately left true between emulation sessions.
"""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PLUGIN = ROOT / 'packages/dolphin_internal_bridge/ios/Classes/DolphinInternalBridgePlugin.mm'


@unittest.skipUnless(sys.platform == 'darwin', 'Apple Foundation/Objective-C runtime required')
class DolphinJitRelaunchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        compiler = shutil.which('clang++')
        if compiler is None:
            raise unittest.SkipTest('Apple clang++ required')
        source = PLUGIN.read_text()
        # Use the shipped implementation, including its NSCondition, token/PID
        # checks and socket decoder. Only logging and the kernel query are fake.
        helper = source[source.index('@interface DOLHelperSession : NSObject'):
                        source.index('static NSString* _Nullable DOLFindHelperBundleIdentifier')]
        harness = r'''
#import <Foundation/Foundation.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>
#include <atomic>
#include <cassert>
#include <cstdio>
#include <cstring>
static NSTimeInterval const kHelperLaunchTimeout = 2.0;
static std::atomic<bool> debugged{true};
static BOOL DOLHostIsDebugged() { return debugged.load(); }
static void DOLAppendJSONLog(NSString*, NSString*, NSString*, NSDictionary*) {}
'''
        harness += helper
        harness += r'''
static int connectClient(DOLHelperSession* helper) {
  [helper startReader];
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  assert(fd >= 0);
  sockaddr_in address = {};
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  address.sin_port = htons(helper.port);
  assert(connect(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0);
  return fd;
}
static void sendEvent(int fd, NSString* token, id event, id pid = nil, id success = nil) {
  NSMutableDictionary* payload = [@{@"token":token, @"event":event} mutableCopy];
  if (pid) payload[@"targetPID"] = pid;
  if (success) payload[@"success"] = success;
  NSError* error = nil;
  NSMutableData* bytes = [[NSJSONSerialization dataWithJSONObject:payload options:0 error:&error] mutableCopy];
  assert(bytes && !error);
  [bytes appendBytes:"\n" length:1];
  size_t sent = 0;
  while (sent < bytes.length) {
    ssize_t count = write(fd, static_cast<const char*>(bytes.bytes) + sent, bytes.length - sent);
    assert(count > 0);
    sent += count;
  }
}
static void connected(int fd, DOLHelperSession* helper) {
  sendEvent(fd, helper.token, @"helper_connected");
  assert([helper waitUntilConnected:2]);
}
static void finish(int fd, DOLHelperSession* helper) {
  sendEvent(fd, helper.token, @"complete", nil, @YES);
  assert([helper waitUntilFinished:2]);
  close(fd);
  [helper close];
}
static DOLHelperSession* makeHelper() {
  NSError* error = nil;
  DOLHelperSession* helper = [[DOLHelperSession alloc] initWithLogPath:@"" error:&error];
  assert(helper && !error);
  return helper;
}
static void alternatingSessions() {
  NSString* previousToken = @"expired-request";
  debugged = true; // This remains true after the first debugger detaches.
  for (int session = 0; session < 12; ++session) {
    DOLHelperSession* helper = makeHelper();
    int fd = connectClient(helper);
    connected(fd, helper);
    sendEvent(fd, previousToken, @"pid_attached", @(getpid()));
    sendEvent(fd, helper.token, @"pid_attached", @(getpid() + 1));
    sendEvent(fd, helper.token, @"pid_attached", nil);
    sendEvent(fd, helper.token, @"pid_attached", @"not-a-pid");
    sendEvent(fd, helper.token, @"pid_attached", @(getpid() + 0.5));
    sendEvent(fd, helper.token, @123, @(getpid()));
    dispatch_semaphore_t completed = dispatch_semaphore_create(0);
    __block BOOL allowed = NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      allowed = DOLWaitForFreshDebuggerAttach(helper, 2);
      dispatch_semaphore_signal(completed);
    });
    // Neither the stale process flag nor any invalid helper message can
    // release the app into its breakpoint on the next Wii/GameCube launch.
    assert(dispatch_semaphore_wait(completed, dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC)) != 0);
    sendEvent(fd, helper.token, @"pid_attached", @(getpid()));
    assert(dispatch_semaphore_wait(completed, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0);
    assert(allowed);
    previousToken = helper.token;
    finish(fd, helper);
  }
}
static void timeoutAndFailedHelper() {
  debugged = true;
  DOLHelperSession* helper = makeHelper();
  int fd = connectClient(helper);
  // An event before this request's connection announcement is not accepted.
  sendEvent(fd, helper.token, @"pid_attached", @(getpid()));
  connected(fd, helper);
  assert(!DOLWaitForFreshDebuggerAttach(helper, 0.03));
  sendEvent(fd, helper.token, @"complete", nil, @NO);
  assert([helper waitUntilFinished:2]);
  assert(!DOLWaitForFreshDebuggerAttach(helper, 2));
  assert(!helper.success);
  close(fd);
  [helper close];
}
static void kernelFlagStillRequired() {
  debugged = false;
  DOLHelperSession* helper = makeHelper();
  int fd = connectClient(helper);
  connected(fd, helper);
  sendEvent(fd, helper.token, @"pid_attached", @(getpid()));
  assert(!DOLWaitForFreshDebuggerAttach(helper, 2));
  finish(fd, helper);
  debugged = true;
  assert(!DOLWaitForFreshDebuggerAttach(helper, 2));
}
int main(int argc, char** argv) {
  @autoreleasepool {
    assert(argc == 2);
    if (!strcmp(argv[1], "relaunch")) alternatingSessions();
    else if (!strcmp(argv[1], "failure")) timeoutAndFailedHelper();
    else if (!strcmp(argv[1], "kernel")) kernelFlagStillRequired();
    else return 1;
  }
}
'''
        cls.temporary = tempfile.TemporaryDirectory()
        directory = Path(cls.temporary.name)
        unit = directory / 'jit_relaunch.mm'
        cls.executable = directory / 'jit_relaunch'
        unit.write_text(harness)
        result = subprocess.run(
            [compiler, '-std=c++17', '-fobjc-arc', '-fblocks', '-framework',
             'Foundation', str(unit), '-o', str(cls.executable)],
            capture_output=True, text=True, timeout=60)
        if result.returncode:
            cls.temporary.cleanup()
            raise AssertionError(result.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def run_case(self, name):
        result = subprocess.run([str(self.executable), name],
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_next_console_waits_for_its_own_authenticated_attach(self):
        self.run_case('relaunch')

    def test_missing_or_failed_attachment_never_reaches_breakpoint(self):
        self.run_case('failure')

    def test_fresh_attachment_also_requires_kernel_validation(self):
        self.run_case('kernel')


if __name__ == '__main__':
    unittest.main()
