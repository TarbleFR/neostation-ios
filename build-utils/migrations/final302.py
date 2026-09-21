#!/usr/bin/env python3
"""One-time host error-reporting correction; removed after native tests."""
from pathlib import Path
root=Path(__file__).resolve().parents[2]
p=root/'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3JitBridgePlugin.mm'
s=p.read_text()
def one(old,new):
    global s
    assert s.count(old)==1, (old[:120],s.count(old))
    s=s.replace(old,new,1)
one('result(@{@"success": @NO, @"message": @"No RPCS3 JIT transaction is ready to complete."});',
    'result(@{@"success": @NO, @"code": session ? @"RPCS3_JIT_COMPLETION_BUSY" : @"RPCS3_JIT_SESSION_MISSING", @"stage": @"jit_completion", @"message": @"No RPCS3 JIT transaction is ready to complete."});')
a=s.index('      BOOL completed = [session waitUntilFinished:kRpcs3CompletionTimeout];',s.index('isEqualToString:@"completeJit"'))
b=s.index('      // A failed/incomplete handshake',a)
s=s[:a]+'''      const BOOL completed = [session waitUntilFinished:kRpcs3CompletionTimeout];
      const BOOL finished = session.finished;
      const BOOL helperSuccess = session.success;
      const BOOL debugged = RPCS3HostIsDebugged();
      const int debuggerState = RPCS3LiveDebuggerState();
      const int queryErrno = debuggerState < 0 ? errno : 0;
      const BOOL success = completed && finished && helperSuccess && debugged && debuggerState == 0;
      NSString* code = !completed || !finished ? @"RPCS3_JIT_COMPLETION_TIMEOUT" :
          !helperSuccess ? @"RPCS3_JIT_HELPER_FAILED" :
          debuggerState < 0 ? @"RPCS3_JIT_DETACH_STATE_UNKNOWN" :
          debuggerState != 0 ? @"RPCS3_JIT_STILL_ATTACHED" :
          !debugged ? @"RPCS3_JIT_DEBUG_FLAG_MISSING" : @"RPCS3_JIT_DETACHED";
      self.transactionClosed = success;
      NSString* message = success ? @"RPCS3 JIT arena prepared and helper detached." :
          [NSString stringWithFormat:@"%@: completed=%d finished=%d helperSuccess=%d debugged=%d debuggerState=%d queryErrno=%d; helperMessage=%@",
              code, completed, finished, helperSuccess, debugged, debuggerState, queryErrno, session.finalMessage ?: @""];
      NSDictionary* response = @{
        @"success": @(success), @"code": code, @"stage": @"jit_completion",
        @"transactionClosed": @(success), @"logs": session.logs, @"message": message,
      };
      RPCS3Milestone(@"jit_completion_end", message);
'''+s[b:]
one('if (completed && session.finished && (RPCS3LiveDebuggerState() == 0)) {',
    'if (completed && finished && debuggerState == 0) {')
for message,code in [
 ('Embedded RPCS3 requires iOS 17.4 or newer.','RPCS3_IOS_VERSION_UNSUPPORTED'),
 ('This NeoStation installation does not preserve get-task-allow.','RPCS3_GET_TASK_ALLOW_MISSING'),
 ('Import a readable pairing file before enabling RPCS3 JIT.','RPCS3_PAIRING_FILE_UNREADABLE'),
 ('An RPCS3 JIT operation is already running.','RPCS3_JIT_TRANSACTION_BUSY'),
]:
    old='@"message" : @"'+message+'",'
    one(old,'@"code" : @"'+code+'",\n      '+old)
for anchor,code in [
 ('      response[@"message"] = @"The stored pairing file could not be read.";', 'RPCS3_PAIRING_FILE_READ_FAILED'),
 ('      response[@"message"] = sessionError.localizedDescription ?: @"Could not prepare the RPCS3 JIT helper.";', 'RPCS3_JIT_CONTROL_SOCKET_FAILED'),
 ('      response[@"message"] = launchError.localizedDescription ?: @"Could not launch the RPCS3 JIT helper.";', 'RPCS3_JIT_HELPER_LAUNCH_FAILED'),
 ('    if (![session waitUntilConnected:kRpcs3HelperConnectTimeout]) {', 'RPCS3_JIT_HELPER_CONNECT_FAILED'),
 ('    if (![session waitUntilAttached:kRpcs3AttachTimeout]) {', 'RPCS3_JIT_ATTACH_NOT_CONFIRMED'),
 ('    if (session.finished && !session.success) {', 'RPCS3_JIT_HELPER_FAILED'),
 ('      response[@"message"] = @"StikJIT detached without leaving NeoStation JIT-enabled.";', 'RPCS3_JIT_DEBUG_FLAG_MISSING'),
]:
    if anchor.endswith('{'):
        one(anchor,anchor+'\n      response[@"code"] = @"'+code+'";')
    else:
        one(anchor,'      response[@"code"] = @"'+code+'";\n'+anchor)
one('#import <poll.h>', '#import <poll.h>\n#include <cerrno>')
p.write_text(s)
print('PASS: explicit helper/connect/attach/closure codes; stage and observed flags retained')
