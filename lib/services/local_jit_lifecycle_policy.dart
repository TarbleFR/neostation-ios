import 'package:flutter/widgets.dart';

/// Native permission dialogs and transient focus loss produce `inactive`
/// without ending the foreground session. A real background transition does.
/// Manual stop remains immediate and independent of this lifecycle policy.
bool shouldStopLocalJitForLifecycle(AppLifecycleState state) => switch (state) {
  AppLifecycleState.resumed || AppLifecycleState.inactive => false,
  AppLifecycleState.paused ||
  AppLifecycleState.hidden ||
  AppLifecycleState.detached => true,
};
