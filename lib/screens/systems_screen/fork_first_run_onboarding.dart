import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/l10n/fork_onboarding_locale.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:provider/provider.dart';

/// Shared preference used to record that the fork's first-run welcome gate has
/// already been completed.
const forkOnboardingCompletedKey = 'neostation_fork_onboarding_v1';

/// One-time welcome screen shown before NeoStation's existing setup wizard.
///
/// NeoStation automatically applies the iPhone/iPad language when it is one of
/// the supported application languages. The user does not have to make a
/// redundant language choice here; language can still be changed later in
/// Settings.
class ForkFirstRunOnboarding extends StatefulWidget {
  const ForkFirstRunOnboarding({super.key, required this.onFinished});

  final Future<void> Function() onFinished;

  @override
  State<ForkFirstRunOnboarding> createState() =>
      _ForkFirstRunOnboardingState();
}

class _ForkFirstRunOnboardingState extends State<ForkFirstRunOnboarding> {
  bool _finishing = false;

  @override
  void initState() {
    super.initState();

    // Apply the device language once when the welcome screen appears. The old
    // flow wrote the same language again when Continue was pressed, which made
    // the transition to SetupWizard unnecessarily slow on iOS.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await context
          .read<SqliteConfigProvider>()
          .updateAppLanguage(_deviceLanguage());
    });
  }

  String _deviceLanguage() {
    final locale = WidgetsBinding.instance.platformDispatcher.locale;

    if (locale.languageCode == 'zh') {
      final script = locale.scriptCode?.toLowerCase();
      final region = locale.countryCode?.toUpperCase();
      if (script == 'hant' ||
          region == 'TW' ||
          region == 'HK' ||
          region == 'MO') {
        return 'zh_Hant';
      }
      return 'zh';
    }

    return AppLocale.supportedLanguages.containsKey(locale.languageCode)
        ? locale.languageCode
        : 'en';
  }

  Future<void> _continue() async {
    if (_finishing) return;
    setState(() => _finishing = true);
    await widget.onFinished();
    if (mounted) setState(() => _finishing = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 760.w),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 28.w, vertical: 24.h),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Image.asset(
                  'assets/images/logo_transparent.png',
                  width: 96.r,
                  height: 96.r,
                ),
                SizedBox(height: 28.h),
                Text(
                  ForkOnboardingLocale.welcomeTitle(context),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
                ),
                SizedBox(height: 34.h),
                FilledButton.icon(
                  onPressed: _finishing ? null : _continue,
                  icon: _finishing
                      ? SizedBox(
                          width: 16.r,
                          height: 16.r,
                          child: const CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.arrow_forward_rounded),
                  label: Text(ForkOnboardingLocale.continueLabel(context)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
