import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/local_jit_lifecycle_policy.dart';

void main() {
  test('a VPN permission dialog does not cancel foreground activation', () {
    expect(shouldStopLocalJitForLifecycle(AppLifecycleState.inactive), isFalse);
    expect(shouldStopLocalJitForLifecycle(AppLifecycleState.resumed), isFalse);
  });

  test('each actual background or teardown state stops the owned tunnel', () {
    for (final state in [
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.detached,
    ]) {
      expect(shouldStopLocalJitForLifecycle(state), isTrue, reason: state.name);
    }
  });
}
