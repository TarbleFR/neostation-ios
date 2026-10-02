import 'package:flutter/material.dart';
import 'package:neostation/l10n/neoplay_companion_locale.dart';

class NeoPlayAppleTVCard extends StatelessWidget {
  const NeoPlayAppleTVCard({super.key, required this.facts, required this.streamBusy});
  final Map<String,dynamic> facts;
  final bool streamBusy;
  @override
  Widget build(BuildContext context) {
    String text(String key) => NeoPlayCompanionLocale.get(context,key);
    final reported = facts['status'];
    final status = const ['mirrorDetected','audioOnly','notDetected'].contains(reported) ? reported as String : 'notDetected';
    return Card(child: ListTile(
      key: const Key('neoplay-apple-tv-system-entry'),
      leading: const Icon(Icons.airplay),
      title: Text(text('appleTVTitle')),
      subtitle: Text(text(status)),
      onTap: () => showDialog<void>(context:context,builder:(context) => AlertDialog(
        title: Text(text('appleTVTitle')),
        content: SingleChildScrollView(child: Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.start,children:[
          Text(text('appleTVSystem')), const SizedBox(height:12),
          if (streamBusy) Padding(padding:const EdgeInsets.only(bottom:12),child:Text(text('busyAppleTV'))),
          Text(text('appleTVBody')), const SizedBox(height:12), Text(text(status)),
        ])),
        actions:[TextButton(onPressed:() => Navigator.pop(context),child:Text(text('close')))],
      )),
    ));
  }
}
