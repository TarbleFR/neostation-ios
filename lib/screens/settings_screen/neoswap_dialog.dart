import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:neo_swap/neo_swap.dart';
import 'package:neostation/l10n/neoswap_locale.dart';

class NeoSwapDialog extends StatefulWidget {
  const NeoSwapDialog({super.key});
  @override
  State<NeoSwapDialog> createState() => _NeoSwapDialogState();
}

class _NeoSwapDialogState extends State<NeoSwapDialog> {
  Map<String, dynamic>? _stats;
  Timer? _timer;
  bool _busy = false;
  bool _polling = false;
  int _revision = 0;
  String? _messageKey;
  int? _code;
  int _probeMiB = 64;
  Map<String, dynamic>? _capacityReport;
  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_polling || _busy) return;
    _polling = true;
    final requestedRevision = _revision;
    try {
      final stats = await NeoSwap.snapshot();
      if (mounted && !_busy && requestedRevision == _revision) {
        setState(() {
          _stats = stats;
          if (_messageKey == 'unavailable') _messageKey = null;
        });
      }
    } catch (_) {
      if (mounted && !_busy && requestedRevision == _revision) {
        setState(() => _messageKey = 'unavailable');
      }
    } finally {
      _polling = false;
    }
  }

  Future<void> _run({int? capacity, bool capacityTest = false}) async {
    if (_busy) return;
    ++_revision; // An earlier diagnostic response cannot undo a newer command.
    setState(() {
      _busy = true;
      _messageKey = null;
      _code = null;
      if (capacityTest) _capacityReport = null;
    });
    try {
      final stats = capacity == null
          ? (capacityTest ? await NeoSwap.capacityProbe(_probeMiB) : await NeoSwap.probe())
          : await NeoSwap.configure(capacity);
      if (!mounted) return;
      final code = (stats['result'] as num?)?.toInt() ?? -2;
      setState(() {
        _stats = stats;
        if (stats['capacityProbe'] is Map) {
          _capacityReport = Map<String, dynamic>.from(stats['capacityProbe'] as Map);
        }
        _code = code;
        _messageKey = code == 0
            ? (capacity == null ? (capacityTest ? 'capacityPass' : 'pass') : 'saved')
            : code == -7
            ? 'busy'
            : code == -1
            ? 'enableFirst'
            : 'failed';
      });
    } catch (_) {
      if (mounted) setState(() => _messageKey = 'unavailable');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _bytes(Object? n) =>
      n is num ? '${(n / (1024 * 1024)).toStringAsFixed(1)} MiB' : '—';
  @override
  Widget build(BuildContext context) {
    String t(String key, [Map<String, String> args = const {}]) =>
        NeoSwapLocale.get(context, key, args);
    Map<dynamic, dynamic> rpc = const {};
    for (final owner in (_stats?['owners'] as List? ?? const [])) {
      if (owner is Map && owner['owner'] == 'rpcs3') rpc = owner;
    }
    // Display the active broker budget, not merely the saved preference.
    final activeBytes = _stats?['capacityBytes'] as num?;
    final capacity = activeBytes == null
        ? ((_stats?['capacityMiB'] as num?)?.toInt() ?? 0)
        : activeBytes ~/ (1024 * 1024);
    final configurationCode = (_stats?['configResult'] as num?)?.toInt() ?? 0;
    final messageKey =
        _messageKey ?? (configurationCode != 0 ? 'failed' : null);
    final resultCode = _code ?? configurationCode;
    return PopScope(
      canPop: !_busy,
      child: Dialog(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 620,
          maxHeight: MediaQuery.sizeOf(context).height * .88,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(t('title'), style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              Text(t('scope')),
              const SizedBox(height: 8),
              Text(t('warning')),
              const SizedBox(height: 16),
              Text(t('capacity')),
              DropdownButton<int>(
                key: const ValueKey('neoSwapBudget'),
                isExpanded: true,
                value: NeoSwap.capacitiesMiB.contains(capacity) ? capacity : 0,
                items: NeoSwap.capacitiesMiB
                    .map(
                      (n) => DropdownMenuItem(
                        value: n,
                        child: Text(n == 0 ? t('off') : '$n MiB'),
                      ),
                    )
                    .toList(),
                onChanged: _busy || _stats == null
                    ? null
                    : (n) {
                        if (n != null) _run(capacity: n);
                      },
              ),
              if (_stats != null) ...[
                Text(t(rpc['registered'] == true ? 'connected' : 'pending')),
                Text(
                  t('used', {
                    'current': _bytes(rpc['liveBytes']),
                    'peak': _bytes(rpc['peakBytes']),
                  }),
                ),
                Text(
                  t('disk', {'disk': _bytes(_stats?['allocatedDiskBytes'])}),
                ),
                Text(
                  t('footprint', {
                    'ram': _bytes(_stats?['processFootprintBytes']),
                  }),
                ),
                Text(
                  t('allocations', {'count': '${rpc['allocationCount'] ?? 0}'}),
                ),
                const SizedBox(height: 8),
                Text(
                  t('peakNote'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: 12),
              if (_busy) const LinearProgressIndicator(),
              if (messageKey != null) Text(t(messageKey)),
              if (resultCode != 0)
                SelectableText('NeoSwap result: $resultCode'),
              OutlinedButton(
                onPressed: _busy || _stats == null ? null : () => _run(),
                child: Text(t('probe')),
              ),
              Text(t('capacityProbe')),
              DropdownButton<int>(
                key: const ValueKey('neoSwapProbeSize'),
                isExpanded: true,
                value: _probeMiB,
                items: NeoSwap.probeSizesMiB.map((n) => DropdownMenuItem(
                  value: n, enabled: n <= capacity, child: Text('$n MiB'),
                )).toList(),
                onChanged: _busy || _stats == null ? null : (n) {
                  if (n != null) setState(() => _probeMiB = n);
                },
              ),
              OutlinedButton(
                onPressed: _busy || _stats == null || _probeMiB > capacity
                    ? null : () => _run(capacityTest: true),
                child: Text(t('capacityRun')),
              ),
              if (_capacityReport != null)
                SelectableText(t('capacityResult', {
                  'size': _bytes(_capacityReport!['requestedBytes']),
                  'delta': _capacityDelta(),
                })),
              if (_stats != null) ...[
                SelectableText(
                  t('diagnostics', {
                    'path': '${_stats?['diagnosticPath'] ?? ''}',
                  }),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                ExpansionTile(
                  title: Text(t('technical')),
                  children: [
                    SelectableText(
                      const JsonEncoder.withIndent('  ').convert({
                        ...?_stats,
                        if (_capacityReport != null) 'capacityProbe': _capacityReport,
                      }),
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ],
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: _busy ? null : () => Navigator.of(context).pop(),
                  child: Text(t('close')),
                ),
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }
  String _capacityDelta() {
    final samples = _capacityReport?['samples'] as List? ?? const [];
    if (samples.isEmpty || samples.first is! Map) return '—';
    final before = (samples.first as Map)['processFootprintBytes'];
    if (before is! num) return '—';
    num peak = before;
    for (final row in samples) {
      if (row is Map && row['processFootprintBytes'] is num) {
        final n = row['processFootprintBytes'] as num;
        if (n > peak) peak = n;
      }
    }
    return _bytes(peak - before);
  }
}
