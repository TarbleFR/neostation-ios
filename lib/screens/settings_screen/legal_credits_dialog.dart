import 'package:flutter/material.dart';
import 'package:neostation/l10n/legal_credits_locale.dart';
import 'package:url_launcher/url_launcher.dart';

class LegalCreditsDialog {
  static const _fullRecordUrl =
      'https://github.com/TarbleFR/neostation-ios/blob/main/docs/LEGAL_AND_CREDITS.md';

  static const List<_LegalEntry> _entries = [
    _LegalEntry(
      'NeoStation',
      'Miguel Soto / misobadev, androosio, ItsRetroPup and contributors',
      'GPL-3.0-or-later',
      'https://github.com/misobadev/neostation-frontend',
    ),
    _LegalEntry(
      'NeoStation iOS',
      'TarbleFR; iOS fork and native integrations',
      'GPL-3.0; upstream rights preserved',
      'https://github.com/TarbleFR/neostation-ios',
    ),
    _LegalEntry(
      'Dolphin / DolphiniOS',
      'Dolphin Emulator, OatmealDome and contributors',
      'GPL-2.0-or-later for most Dolphin code; per-file SPDX applies',
      'https://github.com/OatmealDome/dolphin-ios',
    ),
    _LegalEntry(
      'RPCS3 / XITRIX iOS fork',
      'RPCS3 contributors, XITRIX and credited ARM64/JIT contributors',
      'GPL-2.0-only for most RPCS3 files; per-file notices apply',
      'https://github.com/XITRIX/rpcs3',
    ),
    _LegalEntry(
      'ARMSX2 / PCSX2',
      'ARMSX2 and PCSX2 contributors',
      'GPLv3 / upstream component notices',
      'https://github.com/ARMSX2/ARMSX2',
    ),
    _LegalEntry(
      'Dusklight',
      'TwilitRealm, TP decompilation, Aurora and Borealis contributors',
      'CC0-1.0 root project; dependencies keep their own licenses',
      'https://github.com/TwilitRealm/dusklight',
    ),
    _LegalEntry(
      'KartPad / WiiCompiled',
      'chrissotraidis; WiiCompiled by patchzyy',
      'GPL-3.0-only software where stated; game-derived rights are separate',
      'https://github.com/chrissotraidis/kartpad',
    ),
    _LegalEntry(
      'StikJIT',
      'StikDebug and StikJIT contributors',
      'MPL-2.0',
      'https://github.com/StikDebug/StikJIT',
    ),
    _LegalEntry(
      'GameDB / GameDB-PS3',
      'Niema / niemasd; source datasets include MiSTer Addons and Redump',
      'GPL-3.0 for GameDB-PS3; dataset attribution preserved',
      'https://github.com/niemasd/GameDB-PS3',
    ),
    _LegalEntry(
      'RetroArch / libretro',
      'libretro and RetroArch contributors',
      'External integration; upstream licenses apply',
      'https://github.com/libretro/RetroArch',
    ),
    _LegalEntry(
      'MeloNX',
      'MeloNX contributors; based on Ryujinx/Ryubing as credited upstream',
      'External integration; upstream notices apply',
      'https://github.com/nurtrino/MeloNX',
    ),
  ];

  static Future<void> show(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        return AlertDialog(
          title: Text(LegalCreditsLocale.dialogTitle(dialogContext)),
          content: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 760,
              maxHeight: MediaQuery.sizeOf(dialogContext).height * 0.72,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  LegalCreditsLocale.intro(dialogContext),
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                const Divider(height: 1),
                const SizedBox(height: 8),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: _entries.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final entry = _entries[index];
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          entry.project,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        subtitle: Text(
                          '${entry.credit}\n${entry.license}',
                        ),
                        isThreeLine: true,
                        trailing: const Icon(Icons.open_in_new_rounded),
                        onTap: () => _launch(entry.url),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton.icon(
              onPressed: () => _launch(_fullRecordUrl),
              icon: const Icon(Icons.gavel_rounded),
              label: Text(LegalCreditsLocale.fullRecord(dialogContext)),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(LegalCreditsLocale.close(dialogContext)),
            ),
          ],
        );
      },
    );
  }

  static Future<void> _launch(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}

class _LegalEntry {
  final String project;
  final String credit;
  final String license;
  final String url;

  const _LegalEntry(this.project, this.credit, this.license, this.url);
}
