import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
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
      'assets/legal/NeoStation-GPL-3.0.txt',
    ),
    _LegalEntry(
      'NeoStation iOS',
      'TarbleFR; iOS fork and native integrations',
      'GPL-3.0; upstream rights preserved',
      'https://github.com/TarbleFR/neostation-ios',
      'assets/legal/NeoStation-GPL-3.0.txt',
    ),
    _LegalEntry(
      'Dolphin / DolphiniOS',
      'Dolphin Emulator, OatmealDome and contributors',
      'GPL-2.0-or-later for most Dolphin code; per-file SPDX applies',
      'https://github.com/OatmealDome/dolphin-ios',
      'assets/legal/Dolphin-COPYING.txt',
    ),
    _LegalEntry(
      'RPCS3 / XITRIX iOS fork',
      'RPCS3 contributors, XITRIX and credited ARM64/JIT contributors',
      'GPL-2.0-only for most RPCS3 files; per-file notices apply',
      'https://github.com/XITRIX/rpcs3',
      'assets/legal/RPCS3-GPL-2.0.txt',
    ),
    _LegalEntry(
      'ARMSX2 / PCSX2',
      'ARMSX2 and PCSX2 contributors',
      'GPLv3 / upstream component notices',
      'https://github.com/ARMSX2/ARMSX2',
      'assets/legal/ARMSX2-GPL-3.0.txt',
    ),
    _LegalEntry(
      'Dusklight',
      'TwilitRealm, TP decompilation, Aurora and Borealis contributors',
      'CC0-1.0 root project; dependencies keep their own licenses',
      'https://github.com/TwilitRealm/dusklight',
      'assets/legal/Dusklight-CC0-1.0.txt',
    ),
    _LegalEntry(
      'KartPad / WiiCompiled',
      'chrissotraidis; WiiCompiled by patchzyy',
      'GPL-3.0-only software where stated; game-derived rights are separate',
      'https://github.com/chrissotraidis/kartpad',
      'assets/legal/KartPad-RIGHTS_AND_LICENSES.md',
    ),
    _LegalEntry(
      'StikJIT',
      'StikDebug and StikJIT contributors',
      'MPL-2.0',
      'https://github.com/StikDebug/StikJIT',
      'assets/legal/StikJIT-MPL-2.0.txt',
    ),
    _LegalEntry(
      'GameDB / GameDB-PS3',
      'Niema / niemasd; source datasets include MiSTer Addons and Redump',
      'GPL-3.0 for GameDB-PS3; dataset attribution preserved',
      'https://github.com/niemasd/GameDB-PS3',
      'assets/legal/GameDB-PS3-GPL-3.0.txt',
    ),
    _LegalEntry(
      'NeoStation Assets',
      'NeoStation asset contributors; runtime-downloaded System Art catalog',
      'CC BY-NC-SA 4.0 for original creative assets; trademarks remain separate',
      'https://github.com/misobadev/neostation-assets',
      'assets/legal/NeoStation-Assets-CC-BY-NC-SA-4.0.txt',
    ),
    _LegalEntry(
      'RiiSU / iiSU System Art',
      'RiiSU by mult1v4c; icons credited to iiSU Interpreted / iiSU Network',
      'External on-demand artwork; no standalone RiiSU license was published when integrated',
      'https://github.com/mult1v4c/RiiSU',
      'assets/legal/RiiSU-ATTRIBUTION.md',
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
                    separatorBuilder: (context, index) =>
                        const Divider(height: 1),
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
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (entry.licenseAsset != null)
                              const Icon(Icons.description_outlined),
                            IconButton(
                              tooltip: LegalCreditsLocale.source(context),
                              onPressed: () => _launch(entry.url),
                              icon: const Icon(Icons.open_in_new_rounded),
                            ),
                          ],
                        ),
                        onTap: () => entry.licenseAsset == null
                            ? _launch(entry.url)
                            : _showBundledDocument(context, entry),
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

  static Future<void> _showBundledDocument(
    BuildContext context,
    _LegalEntry entry,
  ) async {
    final asset = entry.licenseAsset;
    if (asset == null) {
      await _launch(entry.url);
      return;
    }

    String contents;
    try {
      contents = await rootBundle.loadString(asset);
    } catch (_) {
      await _launch(entry.url);
      return;
    }
    if (!context.mounted) return;

    await showDialog<void>(
      context: context,
      builder: (documentContext) => AlertDialog(
        title: Text(
          '${entry.project} — '
          '${LegalCreditsLocale.licenseDocument(documentContext)}',
        ),
        content: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 820,
            maxHeight: MediaQuery.sizeOf(documentContext).height * 0.72,
          ),
          child: Scrollbar(
            child: SingleChildScrollView(
              child: SelectableText(
                contents,
                style: Theme.of(documentContext).textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      height: 1.35,
                    ),
              ),
            ),
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () => _launch(entry.url),
            icon: const Icon(Icons.open_in_new_rounded),
            label: Text(LegalCreditsLocale.source(documentContext)),
          ),
          TextButton(
            onPressed: () => Navigator.of(documentContext).pop(),
            child: Text(LegalCreditsLocale.close(documentContext)),
          ),
        ],
      ),
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
  final String? licenseAsset;

  const _LegalEntry(
    this.project,
    this.credit,
    this.license,
    this.url, [
    this.licenseAsset,
  ]);
}
