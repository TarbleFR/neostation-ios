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
  String? _messageKey;
  int? _code;
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
    try {
      final stats = await NeoSwap.snapshot();
      if (mounted && !_busy) setState(() => _stats = stats);
    } catch (_) {
      if (mounted) setState(() => _messageKey = 'unavailable');
    } finally {
      _polling = false;
    }
  }

  Future<void> _run({int? capacity}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _messageKey = null;
      _code = null;
    });
    try {
      final stats = capacity == null
          ? await NeoSwap.probe()
          : await NeoSwap.configure(capacity);
      if (!mounted) return;
      final code = (stats['result'] as num?)?.toInt() ?? -2;
      setState(() {
        _stats = stats;
        _code = code;
        _messageKey = code == 0
            ? (capacity == null ? 'pass' : 'saved')
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
    final capacity = (_stats?['capacityMiB'] as num?)?.toInt() ?? 0;
    return Dialog(
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
              if (_messageKey != null) Text(t(_messageKey!)),
              if (_code != null && _code != 0)
                SelectableText('NeoSwap result: $_code'),
              OutlinedButton(
                onPressed: _busy || _stats == null ? null : () => _run(),
                child: Text(t('probe')),
              ),
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
                      const JsonEncoder.withIndent('  ').convert(_stats),
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
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(t('close')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
