import 'dart:async';

import 'package:flutter/services.dart';

/// Only the RPCS3 attach -> Core initialization -> detach transaction owns
/// this lease. A stopped debugger target cannot send its normal heartbeats.
/// The provider still enforces bounded silence and a hard lease deadline.
class LocalJitDebuggerLease {
  LocalJitDebuggerLease._();

  static const _channel = MethodChannel('neostation/stikjit');
  static const _timeout = Duration(seconds: 4);
  static bool _acquiring = false;
  static String? _token;

  static bool get active => _acquiring || _token != null;

  static Future<void> acquire() async {
    if (active) {
      throw StateError('A debugger tunnel lease is already active.');
    }
    _acquiring = true;
    try {
      final reply = await _channel
          .invokeMapMethod<String, dynamic>('beginDebuggerLease')
          .timeout(_timeout);
      if (reply?['leased'] == false &&
          reply?['managedByNeoStation'] == false) {
        return; // A working external VPN is never modified.
      }
      final token = reply?['token'];
      if (reply?['leased'] != true ||
          reply?['managedByNeoStation'] != true ||
          token is! String ||
          token.isEmpty) {
        throw PlatformException(
          code: 'local_tunnel_lease_unconfirmed',
          message: 'The integrated tunnel did not confirm JIT protection.',
        );
      }
      _token = token;
    } finally {
      _acquiring = false;
    }
  }

  static Future<void> release() async {
    final token = _token;
    if (token == null) return;
    try {
      await _channel.invokeMapMethod<String, dynamic>('endDebuggerLease', {
        'token': token,
      }).timeout(_timeout);
    } finally {
      if (_token == token) _token = null;
    }
  }
}
