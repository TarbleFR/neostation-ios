import 'package:flutter/material.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import '../../settings_screen/new_settings_options/settings_title.dart';
import 'package:neostation/widgets/custom_radio_button.dart';

class ScrapeModeContent extends StatefulWidget {
  final bool isContentFocused;
  final int selectedContentIndex;
  final String currentMode;
  final ValueChanged<String> onModeChanged;

  const ScrapeModeContent({
    super.key,
    required this.isContentFocused,
    required this.selectedContentIndex,
    required this.currentMode,
    required this.onModeChanged,
  });

  @override
  State<ScrapeModeContent> createState() => ScrapeModeContentState();
}

class ScrapeModeContentState extends State<ScrapeModeContent> {
  void selectItem(int index) {
    final modes = ['new_only', 'all'];
    if (index >= 0 && index < modes.length) {
      widget.onModeChanged(modes[index]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final modes = [
      {
        'value': 'new_only',
        'title': AppLocale.newContentOnly.getString(context),
        'description': AppLocale.newContentOnlyDesc.getString(context),
      },
      {
        'value': 'all',
        'title': AppLocale.allContent.getString(context),
        'description': AppLocale.allContentDesc.getString(context),
      },
    ];

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SettingsTitle(
            title: AppLocale.scrapeMode.getString(context),
            subtitle: AppLocale.scrapeModeSub.getString(context),
          ),
          SizedBox(height: 12.r),
          ...modes.asMap().entries.map((entry) {
            final index = entry.key;
            final mode = entry.value;
            final isFocused =
                widget.isContentFocused && widget.selectedContentIndex == index;

            return Padding(
              padding: EdgeInsets.only(bottom: 8.r),
              child: CustomRadioButton<String>(
                title: mode['title']!,
                subtitle: mode['description'],
                value: mode['value']!,
                groupValue: widget.currentMode,
                onChanged: (value) {
                  if (value != null) {
                    widget.onModeChanged(value);
                  }
                },
                isFocused: isFocused,
              ),
            );
          }),
        ],
      ),
    );
  }
}
