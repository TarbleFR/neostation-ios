import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:neoplay_bridge/neoplay_bridge.dart';
import 'package:neostation/l10n/neoplay_locale.dart';

Future<void> showNeoPlayDialog(BuildContext context) => showDialog<void>(context: context, builder: (_) => const NeoPlayDialog());

class NeoPlayDialog extends StatefulWidget {
  const NeoPlayDialog({super.key});
  @override
  State<NeoPlayDialog> createState() => _NeoPlayDialogState();
}
class _NeoPlayDialogState extends State<NeoPlayDialog> {
  StreamSubscription<Map<String, dynamic>>? subscription;
  Map<String, dynamic> snapshot = const {'state': 'idle', 'receivers': []};
  bool error = false;
  bool searching = false;
  @override
  void initState() {
    super.initState();
    subscription = NeoPlayBridge.events.listen((value) { if (mounted) setState(() { snapshot = value; error = value['error'] != null; }); }, onError: (_) { if (mounted) setState(() => error = true); });
  }
  @override
  void dispose() { unawaited(subscription?.cancel()); unawaited(NeoPlayBridge.stopDiscovery().catchError((Object _) {})); super.dispose(); }
  Future<void> action(Future<void> Function() callback) async {
    try { await callback(); } catch (_) { if (mounted) setState(() => error = true); }
  }
  Future<void> connect(Map receiver) async {
    var pin = '';
    if (receiver['kind'] == 'windows') {
      final input = TextEditingController();
      final value = await showDialog<String>(context: context, builder: (context) => AlertDialog(
        title: Text(NeoPlayLocale.get(context, 'pin')),
        content: TextField(controller: input, autofocus: true, keyboardType: TextInputType.number, maxLength: 6, inputFormatters: [FilteringTextInputFormatter.digitsOnly], onSubmitted: (value) { if (value.length == 6) Navigator.pop(context, value); }),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(NeoPlayLocale.get(context, 'close'))), TextButton(onPressed: () { if (input.text.length == 6) Navigator.pop(context, input.text); }, child: Text(NeoPlayLocale.get(context, 'connect')))],
      ));
      // Dispose after the dialog's reverse transition releases its TextField.
      Future<void>.delayed(const Duration(seconds: 1), input.dispose);
      if (value == null || !mounted) return; pin = value;
    }
    if (!mounted) return;
    final label = NeoPlayLocale.get(context, 'disconnect');
    await action(() => NeoPlayBridge.connect(id: receiver['id'] as String, pin: pin, stopLabel: label));
  }
  @override
  Widget build(BuildContext context) {
    String text(String key) => NeoPlayLocale.get(context, key);
    final state = snapshot['state'] as String? ?? 'idle';
    final busy = const ['connecting','capturing','streaming'].contains(state);
    final receivers = (snapshot['receivers'] as List? ?? const []).whereType<Map>().toList();
    return AlertDialog(
      title: const Text('NeoPlay'),
      content: SizedBox(width: 620, height: MediaQuery.sizeOf(context).height * 0.6, child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(text('description')), const SizedBox(height: 10), Text(text('windows')), const SizedBox(height: 6), Text(text('cast')),
        const SizedBox(height: 10), Text(text(state)),
        if (error) Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(text('error'), style: TextStyle(color: Theme.of(context).colorScheme.error))),
        if (!searching) TextButton.icon(onPressed: () { setState(() => searching = true); action(NeoPlayBridge.discover); }, icon: const Icon(Icons.cast), label: Text(text('discover'))),
        receivers.isEmpty ? Center(child: Text(text('empty'))) : ListView.builder(shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), itemCount: receivers.length, itemBuilder: (context,index) {
          final receiver = receivers[index];
          return ListTile(leading: Icon(receiver['kind'] == 'windows' ? Icons.desktop_windows : Icons.cast), title: Text(receiver['name'] as String? ?? 'NeoPlay'), selected: snapshot['selected'] == receiver['id'], enabled: !busy, onTap: () => connect(receiver));
        }),
        Text(text('prototype'), style: Theme.of(context).textTheme.bodySmall),
      ]))),
      actions: [if (busy) TextButton(onPressed: () => action(NeoPlayBridge.disconnect), child: Text(text('disconnect'))), TextButton(onPressed: () => Navigator.pop(context), child: Text(text('close')))],
    );
  }
}
