import 'package:flutter/material.dart';

import '../l10n/manic_emu_locale.dart';
import '../services/ios_emulator_preference_service.dart';
import '../services/retroarch_library_service.dart';

class IosEmulatorChoiceScreen extends StatefulWidget {
  const IosEmulatorChoiceScreen({super.key, required this.onFinished});

  final VoidCallback onFinished;

  @override
  State<IosEmulatorChoiceScreen> createState() =>
      _IosEmulatorChoiceScreenState();
}

class _IosEmulatorChoiceScreenState extends State<IosEmulatorChoiceScreen> {
  IosLibraryEmulator? _selected;
  bool _isSaving = false;

  Future<void> _continue() async {
    final selected = _selected;
    if (selected == null || _isSaving) return;
    setState(() => _isSaving = true);
    try {
      await IosEmulatorPreferenceService.setPrimary(selected);
      await IosEmulatorPreferenceService.markUpgradeOfferSeen();

      // RetroArch needs its exported library metadata before NeoStation can
      // launch a discovered ROM directly. Request that export immediately on
      // first use so the user never has to visit Settings > Directories just
      // to press Sync. RetroArch returns the library through the existing
      // neostation://retroarch callback; the global callback handler persists
      // it and triggers a rescan. The following setup step then links the ROM
      // folder and performs its normal scan with the launch metadata already
      // available.
      //
      // Manic EMU does not use an exported-library callback: its first-run
      // synchronization is the security-scoped folder link + direct scan in
      // SetupWizard, and its launch identifier is derived locally when needed.
      if (selected == IosLibraryEmulator.retroArch) {
        await RetroArchLibraryService.requestLibrarySync();
      }

      if (mounted) widget.onFinished();
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
          child: Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 620),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            ManicEmuLocale.text(context, 'choiceTitle'),
                            textAlign: TextAlign.center,
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            ManicEmuLocale.text(context, 'choiceSubtitle'),
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium,
                          ),
                          const SizedBox(height: 24),
                          _card(
                            IosLibraryEmulator.retroArch,
                            'RetroArch TestFlight',
                            'Synchronisation de bibliothèque et lancement direct via la version bêta/TestFlight de RetroArch.',
                          ),
                          const SizedBox(height: 12),
                          _card(
                            IosLibraryEmulator.manicEmu,
                            'Manic EMU IPA',
                            'Utilisez uniquement la version IPA de Manic EMU comme bibliothèque et lanceur de jeux.',
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 620),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _selected == null || _isSaving
                        ? null
                        : _continue,
                    child: _isSaving
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(ManicEmuLocale.text(context, 'continue')),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _card(IosLibraryEmulator value, String title, String description) {
    final selected = _selected == value;
    final colors = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
          color: selected ? colors.primary : colors.outlineVariant,
          width: selected ? 2 : 1,
        ),
      ),
      child: InkWell(
        onTap: () => setState(() => _selected = value),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Icon(
                Icons.sports_esports_rounded,
                size: 36,
                color: selected ? colors.primary : null,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 4),
                    Text(description),
                  ],
                ),
              ),
              Radio<IosLibraryEmulator>(
                value: value,
                groupValue: _selected,
                onChanged: (choice) => setState(() => _selected = choice),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
