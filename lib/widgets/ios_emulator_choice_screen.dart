import 'package:flutter/material.dart';

import '../l10n/manic_emu_locale.dart';
import '../services/ios_emulator_preference_service.dart';

class IosEmulatorChoiceScreen extends StatefulWidget {
  const IosEmulatorChoiceScreen({super.key, required this.onFinished});

  final VoidCallback onFinished;

  @override
  State<IosEmulatorChoiceScreen> createState() =>
      _IosEmulatorChoiceScreenState();
}

class _IosEmulatorChoiceScreenState extends State<IosEmulatorChoiceScreen> {
  IosLibraryEmulator? _selected;

  Future<void> _continue() async {
    final selected = _selected;
    if (selected == null) return;
    await IosEmulatorPreferenceService.setPrimary(selected);
    await IosEmulatorPreferenceService.markUpgradeOfferSeen();
    widget.onFinished();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
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
                  const SizedBox(height: 28),
                  _card(
                    IosLibraryEmulator.retroArch,
                    'RetroArch',
                    ManicEmuLocale.text(context, 'retroDescription'),
                  ),
                  const SizedBox(height: 12),
                  _card(
                    IosLibraryEmulator.manicEmu,
                    'Manic EMU',
                    ManicEmuLocale.text(context, 'manicDescription'),
                  ),
                  const SizedBox(height: 28),
                  FilledButton(
                    onPressed: _selected == null ? null : _continue,
                    child: Text(ManicEmuLocale.text(context, 'continue')),
                  ),
                ],
              ),
            ),
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
