import 'package:flutter/material.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import '../../settings_screen/new_settings_options/settings_title.dart';
import 'package:neostation/widgets/custom_radio_button.dart';

class LanguageContent extends StatefulWidget {
  final bool isContentFocused;
  final int selectedContentIndex;
  final String currentLanguage;
  final ValueChanged<String> onLanguageChanged;

  const LanguageContent({
    super.key,
    required this.isContentFocused,
    required this.selectedContentIndex,
    required this.currentLanguage,
    required this.onLanguageChanged,
  });

  @override
  State<LanguageContent> createState() => LanguageContentState();
}

class LanguageContentState extends State<LanguageContent> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void selectItem(int index) {
    final languages = ['en', 'es', 'fr', 'de', 'it', 'pt'];
    if (index >= 0 && index < languages.length) {
      widget.onLanguageChanged(languages[index]);
    }
  }

  void ensureVisible(int index) {
    if (!_scrollController.hasClients) return;

    const itemHeight = 50.0;
    const headerHeight = 120.0;
    const padding = 40.0;

    // Calcular la posición del item en el scroll (considerando header)
    final itemPosition = headerHeight + (index * itemHeight);
    final itemEnd = itemPosition + itemHeight;

    final viewportHeight = _scrollController.position.viewportDimension;
    final currentScroll = _scrollController.offset;
    final maxScroll = _scrollController.position.maxScrollExtent;
    final minScroll = _scrollController.position.minScrollExtent;

    double? targetScroll;

    // Si el item está cerca del borde superior, hacer scroll hacia arriba
    if (itemPosition < currentScroll + padding) {
      targetScroll = (itemPosition - padding).clamp(minScroll, maxScroll);
    }
    // Si el item está cerca del borde inferior, hacer scroll hacia abajo
    else if (itemEnd > currentScroll + viewportHeight - padding) {
      targetScroll = (itemEnd - viewportHeight + padding).clamp(
        minScroll,
        maxScroll,
      );
    }

    // Si necesitamos hacer scroll
    if (targetScroll != null) {
      _scrollController.animateTo(
        targetScroll,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final languages = {
      'en': 'English',
      'es': 'Español',
      'fr': 'Français',
      'de': 'Deutsch',
      'it': 'Italiano',
      'pt': 'Português',
    };

    return SingleChildScrollView(
      controller: _scrollController,
      physics: const BouncingScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SettingsTitle(
            title: AppLocale.preferredLanguage.getString(context),
            subtitle: AppLocale.languageSub.getString(context),
          ),
          SizedBox(height: 12.h),
          ...languages.entries.toList().asMap().entries.map((entry) {
            final index = entry.key;
            final lang = entry.value;
            final isFocused =
                widget.isContentFocused && widget.selectedContentIndex == index;

            return Padding(
              padding: EdgeInsets.only(bottom: 8.h),
              child: CustomRadioButton<String>(
                title: lang.value,
                value: lang.key,
                groupValue: widget.currentLanguage,
                onChanged: (value) {
                  if (value != null) {
                    widget.onLanguageChanged(value);
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
