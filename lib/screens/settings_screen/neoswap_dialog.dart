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

  Future<void> _run({bool capacityTest = false}) async {
    if (_busy) return;
    ++_revision; // An earlier diagnostic response cannot undo a newer test.
    setState(() {
      _busy = true;
      _messageKey = null;
      _code = null;
      if (capacityTest) _capacityReport = null;
    });
    try {
      final stats = capacityTest
          ? await NeoSwap.capacityProbe(_probeMiB)
          : await NeoSwap.probe();
      if (!mounted) return;
      final code = (stats['result'] as num?)?.toInt() ?? -2;
      setState(() {
        _stats = stats;
        if (stats['capacityProbe'] is Map) {
          _capacityReport = Map<String, dynamic>.from(
            stats['capacityProbe'] as Map,
          );
        }
        _code = code;
        _messageKey = code == 0
            ? (capacityTest ? 'capacityPass' : 'pass')
            : code == -7
            ? 'busy'
            : code == -1
            ? 'unavailable'
            : 'failed';
      });
    } catch (_) {
      if (mounted) setState(() => _messageKey = 'unavailable');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setShaderStorage(bool enabled) async {
    if (_busy) return;
    ++_revision;
    setState(() {
      _busy = true;
      _messageKey = null;
      _code = null;
    });
    try {
      final stats = await NeoSwap.setShaderStorage(enabled);
      if (!mounted) return;
      setState(() {
        _stats = stats;
        _code = (stats['result'] as num?)?.toInt() ?? -2;
        _messageKey = _code == 0 ? 'storageApplied' : 'failed';
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
    // Display the actual automatic broker budget, including startup failure.
    final activeBytes = _stats?['capacityBytes'] as num?;
    final capacity = activeBytes == null
        ? ((_stats?['capacityMiB'] as num?)?.toInt() ?? 0)
        : activeBytes ~/ (1024 * 1024);
    final configurationCode = (_stats?['configResult'] as num?)?.toInt() ?? 0;
    final messageKey =
        _messageKey ?? (configurationCode != 0 ? 'failed' : null);
    final resultCode = _code ?? configurationCode;
    final requests =
        (rpc['requestCount'] as num?)?.toInt() ??
        ((rpc['allocationCount'] as num?)?.toInt() ?? 0) +
            ((rpc['rejectionCount'] as num?)?.toInt() ?? 0);
    final rejections = (rpc['rejectionCount'] as num?)?.toInt() ?? 0;
    final allocated = (rpc['allocationCount'] as num?)?.toInt() ?? 0;
    final rpcLastResult = (rpc['lastResult'] as num?)?.toInt() ?? 0;
    final donorState = (_stats?['donorSessionState'] as num?)?.toInt() ?? 0;
    final target = _stats?['donationTargetBytes'] ?? 8192 * 1024 * 1024;
    final donationReady = _stats?['memoryDonationSupported'] == true;
    final growthState = _stats?['donationGrowthState'];
    final storage = _stats?['shaderStorage'] is Map
        ? _stats!['shaderStorage'] as Map
        : const {};
    final cache = storage['cache'] is Map ? storage['cache'] as Map : const {};
    final sourceArchive = storage['sourceArchive'] is Map
        ? storage['sourceArchive'] as Map
        : const {};
    final storageRam =
        cache['rawRamBytes'] is num && cache['compressedCacheRamBytes'] is num
        ? (cache['rawRamBytes'] as num) +
              (cache['compressedCacheRamBytes'] as num)
        : null;
    // Global budget controller: what RPCS3 holds and what NeoSwap supplies
    // outside the process footprint. Raw state/reason identifiers stay as-is.
    final contribution = _stats?['neoswapContribution'] is Map
        ? _stats!['neoswapContribution'] as Map
        : const {};
    final budget = _stats?['budget'] is Map ? _stats!['budget'] as Map : const {};
    final relayLoans = budget['relayHostLoans'] is Map
        ? budget['relayHostLoans'] as Map
        : const {};
    final relayKinds = relayLoans['kindLiveBytes'] is Map
        ? relayLoans['kindLiveBytes'] as Map
        : const {};
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
                if (storage.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  SwitchListTile.adaptive(
                    key: const ValueKey('neoSwapShaderStorage'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(t('storageToggle')),
                    subtitle: Text(t('storageDescription')),
                    value: storage['requestedEnabled'] == true,
                    onChanged: _busy ? null : _setShaderStorage,
                  ),
                  Text(
                    t(
                      storage['active'] == true
                          ? 'storageActive'
                          : 'storageInactive',
                    ),
                  ),
                  if (cache.isNotEmpty)
                    Text(
                      t('storageMetrics', {
                        'ram': _bytes(storageRam),
                        'disk': _bytes(cache['storedPayloadBytes']),
                        'cold': _bytes(cache['diskOnlyLogicalBytes']),
                        'latency': cache['readP95Us'] is num
                            ? ((cache['readP95Us'] as num) / 1000)
                                  .toStringAsFixed(2)
                            : '—',
                      }),
                      key: const ValueKey('neoSwapShaderStorageMetrics'),
                    ),
                  if (sourceArchive.isNotEmpty)
                    Text(
                      t('storageVideoMetrics', {
                        'cold': _bytes(
                          sourceArchive['videoPixelLiveArchivedBytes'],
                        ),
                        'returned': _bytes(
                          sourceArchive['videoPixelReturnedArchiveBytesCumulative'],
                        ),
                      }),
                      key: const ValueKey('neoSwapVideoStorageMetrics'),
                    ),
                ],
                if (contribution.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(
                    t('budgetSummary', {
                      'footprint': _bytes(contribution['hostFootprintBytes']),
                      'mobilized': _bytes(
                        contribution['mobilizedOutsideFootprintBytes'],
                      ),
                    }),
                    key: const ValueKey('neoSwapBudgetSummary'),
                  ),
                  Text(
                    t('budgetBreakdown', {
                      'guest': _bytes(contribution['relayGuestLiveBytes']),
                      'host': _bytes(contribution['relayHostLoanLiveBytes']),
                      'donor': _bytes(contribution['donorLoanLiveBytes']),
                      'file': _bytes(contribution['fileFallbackLiveBytes']),
                      'archived': _bytes(
                        contribution['storageArchivedLiveBytes'],
                      ),
                    }),
                    key: const ValueKey('neoSwapBudgetBreakdown'),
                  ),
                  if (relayKinds.isNotEmpty)
                    Text(
                      t('relayLoanKinds', {
                        'cpu': _bytes(relayKinds['cpuData']),
                        'cache': _bytes(relayKinds['cpuCache']),
                        'gpu': _bytes(relayKinds['gpuHostVisible']),
                        'video': _bytes(relayKinds['videoFrame']),
                      }),
                      key: const ValueKey('neoSwapRelayLoanKinds'),
                    ),
                  if (budget.isNotEmpty) ...[
                    Text(
                      t('budgetState', {
                        'state': '${budget['state'] ?? '—'}',
                        'reason': '${budget['reason'] ?? '—'}',
                      }),
                      key: const ValueKey('neoSwapBudgetState'),
                    ),
                    Text(
                      t('budgetQuota', {
                        'quota': _bytes(budget['hostLoanQuotaBytes']),
                        'room': _bytes(budget['growthRoomBytes']),
                        'reserve': _bytes(budget['operationalReserveBytes']),
                      }),
                    ),
                  ],
                  Text(
                    t('budgetNote'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                const SizedBox(height: 16),
                Text(
                  t('donorTarget', {'size': _bytes(target)}),
                  key: const ValueKey('neoSwapTarget'),
                ),
                if (_stats != null) ...[
                  Text(t(rpc['registered'] == true ? 'connected' : 'pending')),
                  Text(
                    t('donorPrepared', {
                      'size': _bytes(_stats?['donationPreparedBytes'] ?? 0),
                      'count': '${_stats?['donorCount'] ?? 0}',
                    }),
                    key: const ValueKey('neoSwapDonorPrepared'),
                  ),
                  if (_stats!.containsKey('remainingStorageBytes'))
                    Text(
                      t('storageAvailable', {
                        'size': _bytes(_stats?['remainingStorageBytes']),
                      }),
                    ),
                  if (_stats!.containsKey('processAvailableBytes'))
                    Text(
                      t('headroom', {
                        'size': _bytes(_stats?['processAvailableBytes']),
                      }),
                    ),
                  if (donationReady) ...[
                    Text(
                      t('donorReady', {
                        'size': _bytes(_stats?['donatedMemoryBytes']),
                      }),
                      key: const ValueKey('neoSwapDonorCharge'),
                    ),
                    Text(
                      t('donorUsed', {
                        'size': _bytes(_stats?['donatedClientBytes']),
                      }),
                      key: const ValueKey('neoSwapDonorUse'),
                    ),
                    Text(
                      t('donorFootprint', {
                        'size': _bytes(_stats?['donorFootprintBytes']),
                      }),
                    ),
                    Text(
                      t('donorPhysical', {
                        'resident': _bytes(_stats?['donatedResidentBytes']),
                        'compressed': _bytes(_stats?['donatedCompressedBytes']),
                      }),
                      key: const ValueKey('neoSwapDonorPhysical'),
                    ),
                    Text(t('donorNote')),
                  ] else if (donorState == 1 || donorState == 2)
                    Text(t('donorPreparing'))
                  else if ((_stats?['donationState'] as num?)?.toInt() == 3)
                    Text(t('donorLost'))
                  else if (_stats?['memoryDonationSupported'] == false)
                    Text(t('donationUnavailable')),
                  if (growthState == 'growing') Text(t('donorGrowing')),
                  if (growthState == 'waiting') Text(t('donorWaiting')),
                  if (growthState == 'limited')
                    Text(
                      t('donorLimited', {
                        'remaining': _bytes(_stats?['donationRemainingBytes']),
                      }),
                      key: const ValueKey('neoSwapDonorLimited'),
                    ),
                  if ((_stats?['donationRetainedLiveBytes'] as num? ?? 0) > 0)
                    Text(
                      t('donorRetained', {
                        'size': _bytes(_stats?['donationRetainedLiveBytes']),
                      }),
                    ),
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
                    t('allocations', {
                      'count': '${rpc['allocationCount'] ?? 0}',
                    }),
                  ),
                  Text(
                    t('requests', {
                      'count': '$requests',
                      'failed': '$rejections',
                    }),
                  ),
                  if (rpc['registered'] == true &&
                      configurationCode == 0 &&
                      (rpc['liveBytes'] as num? ?? 0) == 0)
                    Text(
                      t(
                        requests == 0
                            ? 'noRequests'
                            : rpcLastResult < 0
                            ? 'fallback'
                            : allocated > 0
                            ? 'released'
                            : 'noRequests',
                        {
                          'code': '$rpcLastResult',
                          'errno': '${rpc['lastErrno'] ?? 0}',
                        },
                      ),
                      key: const ValueKey('neoSwapIdleReason'),
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
                if (_stats?['diagnosticProbesAvailable'] == true) ...[
                  OutlinedButton(
                    onPressed: _busy || _stats == null ? null : () => _run(),
                    child: Text(t('probe')),
                  ),
                  Text(t('capacityProbe')),
                  DropdownButton<int>(
                    key: const ValueKey('neoSwapProbeSize'),
                    isExpanded: true,
                    value: _probeMiB,
                    items: NeoSwap.probeSizesMiB
                        .map(
                          (n) => DropdownMenuItem(
                            value: n,
                            enabled: n <= capacity,
                            child: Text('$n MiB'),
                          ),
                        )
                        .toList(),
                    onChanged: _busy || _stats == null
                        ? null
                        : (n) {
                            if (n != null) setState(() => _probeMiB = n);
                          },
                  ),
                  OutlinedButton(
                    onPressed: _busy || _stats == null || _probeMiB > capacity
                        ? null
                        : () => _run(capacityTest: true),
                    child: Text(t('capacityRun')),
                  ),
                  if (_capacityReport != null)
                    SelectableText(
                      t('capacityResult', {
                        'size': _bytes(_capacityReport!['requestedBytes']),
                        'delta': _capacityDelta(),
                      }),
                    ),
                ],
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
                      Text(t('capacity')),
                      Text(
                        '$capacity MiB',
                        key: const ValueKey('neoSwapBudget'),
                      ),
                      SelectableText(
                        const JsonEncoder.withIndent('  ').convert({
                          ...?_stats,
                          if (_capacityReport != null)
                            'capacityProbe': _capacityReport,
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
