import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/l10n/neoplay_locale.dart';
import 'package:neostation/widgets/neoplay_dialog.dart';

/// Opens screen sharing from the main menu without starting discovery or capture.
class AirPlayMenuButton extends StatelessWidget {
  const AirPlayMenuButton({super.key});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: const ValueKey('main-menu-airplay'),
      tooltip: 'AirPlay · ${NeoPlayLocale.get(context, 'subtitle')}',
      icon: Icon(Icons.airplay_rounded, size: 18.r),
      color: Theme.of(context).colorScheme.onSurface,
      padding: EdgeInsets.all(7.r),
      constraints: BoxConstraints.tightFor(width: 32.r, height: 32.r),
      onPressed: () => showNeoPlayDialog(context),
    );
  }
}
