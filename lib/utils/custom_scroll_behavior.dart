import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Custom scroll behavior to enable various pointer devices across platforms.
class CustomScrollBehavior extends MaterialScrollBehavior {
  /// Defines the set of pointer devices that can trigger drag gestures.
  ///
  /// Includes [PointerDeviceKind.mouse] and [PointerDeviceKind.trackpad] to
  /// allow drag-to-scroll functionality on desktop platforms.
  @override
  Set<PointerDeviceKind> get dragDevices => {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
  };
}
