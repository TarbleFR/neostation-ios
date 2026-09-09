"""Run the production RPCS3 helper socket/condition state machine on macOS.

The host must be released on fresh attach, NOT helper completion: a Universal
helper cannot complete until the host's Core prepares/seals its executable
arena. Real ARM64 BRKs/firmware extraction still require a signed iOS device.
"""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PLUGIN = ROOT / 'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3JitBridgePlugin.mm'


@unittest.skipUnless(sys.platform == 'darwin', 'Apple Foundation runtime required')
class Rpcs3JitHandshakeTests(unittest.TestCase):
    def test_production_session_protocol(self):
        compiler = shutil.which('clang++')
        if compiler is None:
            self.skipTest('Apple clang++ required')
        source = PLUGIN.read_text()
        session = source[source.index('@interface RPCS3JitSession : NSObject'):
                         source.index('static NSString* _Nullable RPCS3FindHelperBundleIdentifier')]
        harness = r'''
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
static NSTimeInterval const kRpcs3HelperConnectTimeout = 2.0;
'''
        harness += session
        harness += r'''
static RPCS3JitSession* makeSession(BOOL universal = YES) {
  NSError* error = nil;
  RPCS3JitSession* session = [[RPCS3JitSession alloc] initWithError:&error];
  assert(session && !error);
  session.requiresCoreHandshake = universal;
  [session startReader];
  return session;
}
static int connectClient(RPCS3JitSession* session) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  assert(fd >= 0);
  sockaddr_in address = {};
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  address.sin_port = htons(session.port);
  assert(connect(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0);
  return fd;
}
static void sendEvent(int fd, NSString* token, id event, id pid = nil, id success = nil) {
  NSMutableDictionary* payload = [@{@"token": token, @"event": event} mutableCopy];
  if (pid) payload[@"targetPID"] = pid;
  if (success) payload[@"success"] = success;
  NSMutableData* bytes = [[NSJSONSerialization dataWithJSONObject:payload options:0 error:nil] mutableCopy];
  [bytes appendBytes:"\n" length:1];
  size_t sent = 0;
  while (sent < bytes.length) {
    ssize_t n = write(fd, static_cast<const char*>(bytes.bytes) + sent, bytes.length - sent);
    assert(n > 0);
    sent += n;
  }
}
static void connected(int fd, RPCS3JitSession* session) {
  sendEvent(fd, session.token, @"helper_connected");
  assert([session waitUntilConnected:2]);
}
static void universalHandshake() {
  RPCS3JitSession* session = makeSession();
  int fd = connectClient(session);
  connected(fd, session);
  // Neither a stale token nor another PID may release Core into its BRK.
  sendEvent(fd, @"stale-token", @"pid_attached", @(getpid()));
  sendEvent(fd, session.token, @"pid_attached", @(getpid() + 1));
  sendEvent(fd, session.token, @"pid_attached", @"invalid");
  assert(![session waitUntilAttached:0.03]);
  sendEvent(fd, session.token, @"pid_attached", @(getpid()));
  // This is the regression: host startup must advance while helper waits.
  assert([session waitUntilAttached:2]);
  assert(!session.finished);
  assert(![session waitUntilFinished:0.03]);
  // Simulate Core preparing and sealing its arena AFTER host was released.
  sendEvent(fd, session.token, @"complete", nil, @YES);
  assert([session waitUntilFinished:2] && session.success);
  close(fd);
  [session close];
}
static void legacyAttachWithoutScript() {
  RPCS3JitSession* session = makeSession(NO);
  int fd = connectClient(session);
  connected(fd, session);
  // StikJIT's non-TXM attach/detach API never emits attach_response.
  sendEvent(fd, session.token, @"complete", nil, @YES);
  assert([session waitUntilAttached:2]);
  assert(session.finished && session.success && !session.attached);
  close(fd);
  [session close];
}
static void completionCannotReplaceUniversalAttach() {
  RPCS3JitSession* session = makeSession();
  int fd = connectClient(session);
  connected(fd, session);
  sendEvent(fd, session.token, @"complete", nil, @YES);
  assert(![session waitUntilAttached:2]);
  close(fd);
  [session close];
}
static void failureAndDisconnect() {
  for (int mode = 0; mode < 3; ++mode) {
    RPCS3JitSession* session = makeSession();
    int fd = connectClient(session);
    connected(fd, session);
    if (mode == 0) sendEvent(fd, session.token, @"complete", nil, @NO);
    if (mode == 1) { close(fd); fd = -1; }
    if (mode == 2) [session close]; // Must unblock fdopen/fgets, not leak it.
    assert([session waitUntilFinished:2]);
    assert(!session.success);
    assert(![session waitUntilAttached:0.03]);
    if (fd >= 0) close(fd);
    [session close];
  }
}
int main() {
  @autoreleasepool {
    universalHandshake();
    legacyAttachWithoutScript();
    completionCannotReplaceUniversalAttach();
    failureAndDisconnect();
    puts("RPCS3 production handshake: all scenarios passed");
  }
}
'''
        with tempfile.TemporaryDirectory(prefix='rpcs3-handshake-') as directory:
            source_file = Path(directory) / 'harness.mm'
            executable = Path(directory) / 'harness'
            source_file.write_text(harness)
            subprocess.run([compiler, '-std=c++17', '-fobjc-arc', '-fblocks',
                            '-framework', 'Foundation', str(source_file), '-o',
                            str(executable)], check=True, timeout=60)
            subprocess.run([str(executable)], check=True, timeout=30)


if __name__ == '__main__':
    unittest.main()
