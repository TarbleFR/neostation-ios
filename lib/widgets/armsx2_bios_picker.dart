import 'package:flutter/material.dart';

import '../l10n/armsx2_ui_locale.dart';
import '../services/armsx2_bios_service.dart';

/// Returns the explicit, persisted choice; cancellation never changes it.
Future<String?> showArmsx2BiosPicker(BuildContext context) async {
  final store = await Armsx2BiosStore.open();
  final files = await store.list();
  if (!context.mounted) return null;
  final selected = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(Armsx2UiLocale.text(context, 'chooseBios')),
      content: SizedBox(
        width: 460,
        height: MediaQuery.sizeOf(context).height * 0.5,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              files.isEmpty
                  ? Armsx2UiLocale.text(context, 'importBiosFirst')
                  : Armsx2UiLocale.text(context, 'biosChoiceHelp'),
            ),
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
          child: Text(Armsx2UiLocale.text(context, 'cancel')),
        ),
      ],
    ),
  );
  if (selected != null) await store.select(selected);
  return selected;
}
