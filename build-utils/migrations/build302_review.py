#!/usr/bin/env python3
"""One-time source review corrections; removed after gated consolidation."""
from pathlib import Path
root = Path(__file__).resolve().parents[2]
def replace(path, old, new):
    p = root / path
    text = p.read_text()
    assert text.count(old) == 1, (path, old, text.count(old))
    p.write_text(text.replace(old, new, 1))
replace('lib/services/rpcs3_startup_transaction.dart',
    '  bool get ready => phase == Rpcs3StartupPhase.ready;',
    '  bool get ready => phase == Rpcs3StartupPhase.ready;\n  bool get inProgress => _pending != null;')
replace('lib/services/rpcs3_internal_service.dart',
    '        _runtimePreparation != null ||\n        _jitPreparation != null ||',
    '        _startup.inProgress ||')
path = root / 'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm'
text = path.read_text()
a = text.index('// Only the legacy Core backend uses an ordinary RW -> RX transition.')
b = text.index('static UIViewController* RPCS3RootViewController', a)
text = text[:a] + text[b:]
a = text.index('  // The original RPCS3 iOS loader requires JIT to be active before dlopen.')
b = text.index('  // NEOSTATION_RPCS3_BUILD301_SINGLE_DLOPEN_V1', a)
text = text[:a] + '''  // libRPCS3Core.dylib is loaded into NeoStation itself, not a child process.
  // This is debugger authorization only, never proof of usable JIT memory.
  // The final nonce below proves live ownership before this single dlopen.
  if (!RPCS3HostIsDebugged()) {
    if (error) *error = @"RPCS3_DEBUGGER_AUTHORIZATION_MISSING: stage=core_load; kernel CS_DEBUGGED is absent.";
    return NO;
  }

''' + text[b:]
# RPCS3IOS.cpp generates f(x)=3*x+7, so f(11)=40, not f(5).
assert text.count('status = test(5, &output);') == 1
text = text.replace('status = test(5, &output);', 'status = test(11, &output);')
text = text.replace('status=%d input=5 output=', 'status=%d input=11 output=')
# There is one execution proof, before ready. Never silently rerun it at boot.
a = text.index('      if (!self.llvmSelfTestPassed) {', text.index('isEqualToString:@"launchGame"'))
b = text.index('      NSString* audioError = nil;', a)
text = text[:a] + '''      if (!self.llvmSelfTestPassed || !RPCS3JitTransactionIsClosed()) {
        [self stopAndDismiss:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
          result(@{@"success": @NO, @"code": @"RPCS3_STARTUP_NOT_VERIFIED",
            @"stage": @"game_boot", @"message": @"RPCS3_STARTUP_NOT_VERIFIED: complete startup and execution verification before boot."});
        });
        return;
      }
''' + text[b:]
path.write_text(text)
for filename, variable in [('test/rpcs3_lazy_load_contract_test.dart','plugin'), ('test/rpcs3_internal_integration_test.dart','bridge')]:
    replace(filename,
        f"      expect({variable}, contains('RPCS3ProbeExecutableMemory'));",
        f"      expect({variable}, isNot(contains('RPCS3ProbeExecutableMemory')));\n"
        f"      expect({variable}, contains('_reservation.verify_owned()'));\n"
        f"      expect({variable}, contains('verifyJitExecution'));\n"
        f"      expect({variable}, contains('RPCS3_DEBUGGER_AUTHORIZATION_MISSING'));")
replace('test/rpcs3_internal_integration_test.dart',
    "      expect(bridge, contains('RPCS3JitHasActiveCoreHandshake()'));",
    "      expect(bridge, isNot(contains('RPCS3JitHasActiveCoreHandshake()')));\n"
    "      expect(bridge.indexOf('if (!RPCS3JitConfirmCoreLoadHandoff())'),\n"
    "        allOf(greaterThanOrEqualTo(0), lessThan(bridge.indexOf('handle = dlopen('))));")
replace('test/rpcs3_startup_transaction_test.dart',
    "import '../lib/services/rpcs3_startup_transaction.dart';",
    "import 'package:neostation/services/rpcs3_startup_transaction.dart';")
replace('test/rpcs3_startup_transaction_test.dart',
    "    expect(tx.ready, false);\n    expect(h.calls, ['route','reserve','attach']);",
    "    expect(tx.ready, false);\n    expect(tx.inProgress, true);\n    expect(h.calls, ['route','reserve','attach']);")
replace('test/rpcs3_startup_transaction_test.dart',
    "    await Future.wait([one,two]); expect(h.calls.where((c)=>c=='attach').length,1);",
    "    await Future.wait([one,two]); expect(h.calls.where((c)=>c=='attach').length,1);\n    expect(tx.inProgress, false);")
replace('packages/rpcs3_internal_bridge/ios/Classes/Rpcs3ArenaReservation.h',
    '''    return ::vm_deallocate(mach_task_self(), static_cast<vm_address_t>(address),
        static_cast<vm_size_t>(bytes));''',
    '''    const int error = ::vm_deallocate(mach_task_self(), static_cast<vm_address_t>(address),
        static_cast<vm_size_t>(bytes));
    if (error) cleanup_error = error;
    return error;''')
# Keep injected debugger state race-free; sockets/session reader are production.
replace('test/rpcs3_startup_abort_native_test.py', '#include <functional>', '#include <functional>\n#include <atomic>')
replace('test/rpcs3_startup_abort_native_test.py', 'static int live = 0;', 'static std::atomic<int> live{0};')
replace('test/rpcs3_startup_abort_native_test.py',
    ' auto report=run(bridge);',
    ''' auto report=run(bridge);
 fprintf(stderr, "ABORT_RESULT=%s connected=%d attached=%d finished=%d closed=%d live=%d\\n",
     report.description.UTF8String, session.connected, session.attached, session.finished, session.closed, live.load());''')
# A static consistency gate, not a claim that device JIT ran on the CI host.
replace('test/rpcs3_reserved_startup_core_test.py',
    "print('PASS actual Core reset: retry before publication, preservation after publication, failure retained')",
    '''print('PASS actual Core reset: retry before publication, preservation after publication, failure retained')
import re
host=(ROOT/'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm').read_text()
selftest=api[api.index('extern "C" rpcs3_ios_status rpcs3_ios_run_llvm_self_test('):]
assert 'CreateMul(argument, llvm::ConstantInt::get(argument->getType(), 3))' in selftest
assert 'CreateAdd(multiplied, llvm::ConstantInt::get(argument->getType(), 7))' in selftest
probe=host[host.index('isEqualToString:@"verifyJitExecution"'):host.index('isEqualToString:@"diagnostics"')]
input_value=int(re.search(r'status = test\\((\\d+), &output\\);', probe).group(1))
expected=int(re.search(r'status == 0 && output == (\\d+)', probe).group(1))
assert input_value*3+7 == expected, (input_value,expected)
assert host.count('dlsym(self->_api.handle, "rpcs3_ios_run_llvm_self_test")') == 1
print('PASS static host/Core LLVM probe contract: f(%d)=%d; one execution proof' % (input_value,expected))''')
print('PASS: single startup owner; one correct LLVM proof; no redundant probe; exact rollback errors')
