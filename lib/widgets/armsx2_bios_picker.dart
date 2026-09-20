import 'package:flutter/material.dart';

import '../services/armsx2_bios_service.dart';

/// Returns the explicit, persisted choice; cancellation never changes it.
Future<String?> showArmsx2BiosPicker(BuildContext context) async {
  final store = await Armsx2BiosStore.open();
  final files = await store.list();
  if (!context.mounted) return null;
  final fr = Localizations.localeOf(context).languageCode == 'fr';
  final selected = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(fr ? 'Choisir le BIOS PS2' : 'Choose PS2 BIOS'),
      content: SizedBox(
        width: 460,
        height: MediaQuery.sizeOf(context).height * 0.5,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(files.isEmpty
                ? (fr ? 'Importez d’abord un ou plusieurs BIOS PS2.'
                      : 'Import one or more PS2 BIOS files first.')
                : (fr ? 'Ce choix sera utilisé pour les jeux et le démarrage du BIOS. Les langues proposées dépendent du BIOS choisi.'
                      : 'This choice is used for games and BIOS boot. Available languages depend on the chosen BIOS.')),
            const SizedBox(height: 12),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: files.length,
                itemBuilder: (context, index) {
                  final bios = files[index];
                  return ListTile(
                    key: ValueKey('armsx2-bios-${bios.filename}'),
                    title: Text(bios.filename),
                    subtitle: Text('${(bios.bytes / 1048576).toStringAsFixed(2)} MiB'),
                    trailing: bios.filename == store.selectedFilename
                        ? const Icon(Icons.check) : null,
                    onTap: () => Navigator.of(dialogContext).pop(bios.filename),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(fr ? 'Annuler' : 'Cancel'),
        ),
      ],
    ),
  );
  if (selected != null) await store.select(selected);
  return selected;
}
