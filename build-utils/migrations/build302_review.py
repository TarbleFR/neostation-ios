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
  // Success requires owned VA, Core initialization, detach and LLVM execution.
  if (!RPCS3HostIsDebugged()) {
    if (error) *error = @"RPCS3_DEBUGGER_AUTHORIZATION_MISSING: stage=core_load; kernel CS_DEBUGGED is absent.";
    return NO;
  }

''' + text[b:]
path.write_text(text)
replace('test/rpcs3_lazy_load_contract_test.dart',
    "      expect(plugin, contains('RPCS3ProbeExecutableMemory'));",
    "      expect(plugin, isNot(contains('RPCS3ProbeExecutableMemory')));\n      expect(plugin, contains('_reservation.verify_owned()'));\n      expect(plugin, contains('verifyJitExecution'));\n      expect(plugin, contains('RPCS3_DEBUGGER_AUTHORIZATION_MISSING'));")
replace('test/rpcs3_internal_integration_test.dart',
    "      expect(bridge, contains('RPCS3ProbeExecutableMemory'));",
    "      expect(bridge, isNot(contains('RPCS3ProbeExecutableMemory')));\n      expect(bridge, contains('_reservation.verify_owned()'));\n      expect(bridge, contains('verifyJitExecution'));\n      expect(bridge, contains('RPCS3_DEBUGGER_AUTHORIZATION_MISSING'));")
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
replace('test/rpcs3_startup_abort_native_test.py',
    '  auto report=run(bridge);',
    '''  auto report=run(bridge);
  fprintf(stderr, "ABORT_RESULT=%s connected=%d attached=%d finished=%d closed=%d live=%d\\n",
      report.description.UTF8String, session.connected, session.attached, session.finished, session.closed, live);''')
replace('test/rpcs3_startup_abort_native_test.py',
    'static uint64_t RPCS3DebuggerProbe(uint64_t nonce) { return live == 1 ? nonce + 1 : 0; }',
    '''static uint64_t RPCS3DebuggerProbe(uint64_t nonce) {
  fprintf(stderr,"ABORT_NONCE=%llu live=%d\\n",(unsigned long long)nonce,live);
  return live == 1 ? nonce + 1 : 0;
}''')
replace('test/rpcs3_startup_abort_native_test.py',
    'static uint64_t RPCS3DebuggerDetach() { detached(); return 0; }',
    'static uint64_t RPCS3DebuggerDetach() { fprintf(stderr,"ABORT_DETACH_REQUEST\\n"); detached(); return 0; }')
print('PASS: startup owner reconciled, obsolete readiness probe removed; native abort outcome will be asserted, not assumed')
