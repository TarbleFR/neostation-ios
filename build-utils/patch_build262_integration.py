#!/usr/bin/env python3
from pathlib import Path

SETTINGS = Path('lib/screens/settings_screen/new_settings_options/themes_settings_content.dart')
WORKFLOW = Path('.github/workflows/build-ipa-once.yml')
CORE = Path('build-utils/build_rpcs3_embedded_core.sh')
TUNNEL = Path('build-utils/configure_local_jit_tunnel.py')
FULL_THEME_SERVICE = Path('lib/services/full_theme_service.dart')
CONTRACT = Path('test/full_theme_category_contract_test.py')


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f'Missing Build 262 patch anchor: {label}')
    return text.replace(old, new, 1)


def patch_settings() -> None:
    text = SETTINGS.read_text()

    text = replace_once(
        text,
        "import 'package:neostation/l10n/home_music_locale.dart';\n",
        "import 'package:neostation/l10n/home_music_locale.dart';\n"
        "import 'package:neostation/l10n/full_theme_locale.dart';\n",
        'full theme locale import',
    )
    text = replace_once(
        text,
        "import 'package:neostation/services/home_music_service.dart';\n",
        "import 'package:neostation/services/home_music_service.dart';\n"
        "import 'package:neostation/services/full_theme_service.dart';\n",
        'full theme service import',
    )
    text = replace_once(
        text,
        "    final count = themeProvider.getThemeList().length + 4;",
        "    final count = themeProvider.getThemeList().length + 5;",
        'navigation key count',
    )
    text = replace_once(
        text,
        "    return themeProvider.getThemeList().length + 4;",
        "    return themeProvider.getThemeList().length + 5;",
        'item count',
    )
    text = replace_once(
        text,
        "    final customBackgroundIndex = themes.length + 1;\n"
        "    final menuMusicIndex = themes.length + 2;\n",
        "    final customBackgroundIndex = themes.length + 1;\n"
        "    final menuMusicIndex = themes.length + 2;\n"
        "    final importIndex = themes.length + 3;\n"
        "    final fullThemeIndex = themes.length + 4;\n",
        'selection indexes',
    )
    text = replace_once(
        text,
        "    } else if (index == menuMusicIndex) {\n"
        "      await _toggleHomeMusic();\n"
        "      return;\n"
        "    } else {\n"
        "      await _importTheme();\n"
        "      return;\n"
        "    }",
        "    } else if (index == menuMusicIndex) {\n"
        "      await _toggleHomeMusic();\n"
        "      return;\n"
        "    } else if (index == importIndex) {\n"
        "      await _importTheme();\n"
        "      return;\n"
        "    } else if (index == fullThemeIndex) {\n"
        "      await _showFullThemeActions();\n"
        "      return;\n"
        "    } else {\n"
        "      return;\n"
        "    }",
        'selection dispatch',
    )

    full_theme_methods = '''  Future<void> _showFullThemeActions() async {
    await FullThemeService.instance.initialize();
    if (!mounted) return;
    final active = FullThemeService.instance.activeTheme.value;
    if (active == null) {
      await _pickFullTheme();
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(FullThemeLocale.title(dialogContext)),
        content: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 480.r),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                active.name,
                style: Theme.of(dialogContext).textTheme.titleMedium,
              ),
              SizedBox(height: 6.r),
              Text(FullThemeLocale.description(dialogContext)),
              SizedBox(height: 14.r),
              ListTile(
                leading: const Icon(Symbols.folder_open_rounded),
                title: Text(FullThemeLocale.replace(dialogContext)),
                onTap: () {
                  Navigator.of(dialogContext).pop();
                  _pickFullTheme();
                },
              ),
              ListTile(
                leading: const Icon(Symbols.delete_rounded),
                title: Text(FullThemeLocale.remove(dialogContext)),
                subtitle: Text(active.name),
                onTap: () {
                  Navigator.of(dialogContext).pop();
                  _removeFullTheme();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickFullTheme() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['zip'],
        allowMultiple: false,
        dialogTitle: FullThemeLocale.import(context),
      );
      final filePath = result?.files.single.path;
      if (filePath == null || filePath.isEmpty) return;

      final imported = await FullThemeService.instance.importZip(File(filePath));
      if (!mounted) return;
      setState(() {});
      AppNotification.showNotification(
        context,
        FullThemeLocale.success(context, imported.name),
        type: NotificationType.success,
      );
    } catch (e) {
      _log.e('Full theme import failed: $e');
      if (!mounted) return;
      AppNotification.showNotification(
        context,
        FullThemeLocale.error(context),
        type: NotificationType.error,
      );
    }
  }

  Future<void> _removeFullTheme() async {
    final active = FullThemeService.instance.activeTheme.value;
    if (active == null) return;
    await FullThemeService.instance.removeActiveTheme();
    if (!mounted) return;
    setState(() {});
    AppNotification.showNotification(
      context,
      FullThemeLocale.remove(context),
      type: NotificationType.info,
    );
  }

'''
    text = replace_once(
        text,
        "  Future<void> _toggleHomeMusic() async {",
        full_theme_methods + "  Future<void> _toggleHomeMusic() async {",
        'full theme actions insertion',
    )
    text = replace_once(
        text,
        "    homeMusic.setMainMenuActive(false).then((_) {\n"
        "      if (mounted) setState(() {});\n"
        "    });\n",
        "    homeMusic.setMainMenuActive(false).then((_) {\n"
        "      if (mounted) setState(() {});\n"
        "    });\n"
        "    FullThemeService.instance.initialize().then((_) {\n"
        "      if (mounted) setState(() {});\n"
        "    });\n",
        'full theme initialization',
    )

    # This exact snippet occurs again in deleteFocusedTheme after the first
    # selectItem replacement above has already expanded its copy.
    text = replace_once(
        text,
        "    final customBackgroundIndex = themes.length + 1;\n"
        "    final menuMusicIndex = themes.length + 2;\n\n"
        "    if (index == customBackgroundIndex) {",
        "    final customBackgroundIndex = themes.length + 1;\n"
        "    final menuMusicIndex = themes.length + 2;\n"
        "    final fullThemeIndex = themes.length + 4;\n\n"
        "    if (index == fullThemeIndex) {\n"
        "      if (FullThemeService.instance.activeTheme.value != null) {\n"
        "        _removeFullTheme();\n"
        "      }\n"
        "      return;\n"
        "    }\n\n"
        "    if (index == customBackgroundIndex) {",
        'full theme delete dispatch',
    )
    text = replace_once(
        text,
        "    final importIndex = allThemes.length + 2;\n"
        "    final itemCount = allThemes.length + 3;",
        "    final importIndex = allThemes.length + 2;\n"
        "    final fullThemeIndex = allThemes.length + 3;\n"
        "    final itemCount = allThemes.length + 4;",
        'build indexes',
    )

    full_theme_item = '''              if (index == fullThemeIndex) {
                return Container(
                  key: _itemKeys[index],
                  child: _FullThemeCategoryCard(
                    isFocused: isFocused,
                    onTap: () {
                      SfxService().playNavSound();
                      widget.onSelectionChanged?.call(index);
                      _showFullThemeActions();
                    },
                    onDelete: FullThemeService.instance.activeTheme.value != null
                        ? _removeFullTheme
                        : null,
                  ),
                );
              }

'''
    text = replace_once(
        text,
        "              if (index == importIndex) {",
        full_theme_item + "              if (index == importIndex) {",
        'full theme card insertion',
    )

    card = '''

class _FullThemeCategoryCard extends StatelessWidget {
  const _FullThemeCategoryCard({
    required this.isFocused,
    required this.onTap,
    this.onDelete,
  });

  final bool isFocused;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;

    return ValueListenableBuilder(
      valueListenable: FullThemeService.instance.activeTheme,
      builder: (context, activeTheme, _) {
        final background = activeTheme?.resolve(activeTheme.backgroundPath);
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AspectRatio(
              aspectRatio: 4 / 3,
              child: Container(
                margin: EdgeInsets.symmetric(vertical: 4.h),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(8.r),
                  border: Border.all(
                    color: isFocused ? accent : Colors.transparent,
                    width: 2.r,
                  ),
                  boxShadow: isFocused
                      ? [
                          BoxShadow(
                            color: accent.withValues(alpha: 0.3),
                            blurRadius: 8.r,
                            spreadRadius: 1.r,
                          ),
                        ]
                      : null,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6.r),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (background != null)
                        Image.file(
                          File(background),
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                        )
                      else
                        DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                theme.colorScheme.surface,
                                accent.withValues(alpha: 0.45),
                              ],
                            ),
                          ),
                        ),
                      ColoredBox(color: Colors.black.withValues(alpha: 0.24)),
                      Positioned(
                        left: 8.r,
                        top: 8.r,
                        child: Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: 8.r,
                            vertical: 4.r,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.68),
                            borderRadius: BorderRadius.circular(12.r),
                          ),
                          child: Text(
                            FullThemeLocale.title(context),
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 9.r,
                            ),
                          ),
                        ),
                      ),
                      Center(
                        child: Icon(
                          activeTheme == null
                              ? Symbols.add_rounded
                              : Symbols.dashboard_customize_rounded,
                          color: Colors.white,
                          size: 34.r,
                        ),
                      ),
                      Positioned.fill(
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            canRequestFocus: false,
                            onTap: onTap,
                          ),
                        ),
                      ),
                      if (onDelete != null)
                        Positioned(
                          right: 6.r,
                          top: 6.r,
                          child: Material(
                            color: Colors.black.withValues(alpha: 0.68),
                            shape: const CircleBorder(),
                            child: InkWell(
                              canRequestFocus: false,
                              customBorder: const CircleBorder(),
                              onTap: onDelete,
                              child: Padding(
                                padding: EdgeInsets.all(4.r),
                                child: Icon(
                                  Symbols.close_rounded,
                                  color: Colors.white,
                                  size: 15.r,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            SizedBox(height: 4.r),
            Text(
              activeTheme?.name ?? FullThemeLocale.import(context),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: isFocused
                    ? theme.colorScheme.onSurface
                    : theme.colorScheme.onSurface.withValues(alpha: 0.7),
                fontWeight: activeTheme != null || isFocused
                    ? FontWeight.bold
                    : FontWeight.normal,
                fontSize: 12.r,
              ),
            ),
          ],
        );
      },
    );
  }
}
'''
    if 'class _FullThemeCategoryCard extends StatelessWidget' not in text:
        text = text.rstrip() + card + '\n'

    SETTINGS.write_text(text)


def patch_workflow() -> None:
    text = WORKFLOW.read_text()
    replacements = (
        ('name: NeoStation iOS Build 260', 'name: NeoStation iOS Build 262'),
        (
            'run-name: NeoStation iOS Build 260 (modern in-game UI + Dolphin RA/hacks) • ${{ github.sha }}',
            'run-name: NeoStation iOS Build 262 (Build 260 preserved + Full Theme) • ${{ github.sha }}',
        ),
        ('      - work/ui-dolphin-build260', '      - work/full-theme-build262-sync260'),
        ('  group: neostation-ios-build-260', '  group: neostation-ios-build-262'),
        ("      BUILD_NUMBER: '260'", "      BUILD_NUMBER: '262'"),
        (
            "      IPA_NAME: 'NeoStation-iOS-Build-260-Modern-Dolphin'",
            "      IPA_NAME: 'NeoStation-iOS-Build-262-FullTheme'",
        ),
        (
            "      ARTIFACT_NAME: 'NeoStation-iOS-Build-260-Modern-Dolphin'",
            "      ARTIFACT_NAME: 'NeoStation-iOS-Build-262-FullTheme'",
        ),
    )
    for old, new in replacements:
        text = replace_once(text, old, new, f'workflow identity: {old}')

    test_anchor = '          python3 test/integrated_import_tab_contract_test.py\n'
    if 'test/full_theme_category_contract_test.py' not in text:
        text = replace_once(
            text,
            test_anchor,
            test_anchor + '          python3 test/full_theme_category_contract_test.py\n',
            'full theme contract test insertion',
        )
    WORKFLOW.write_text(text)


def patch_build_identity() -> None:
    text = CORE.read_text()
    if 'BUILD_NUMBER=260' not in text:
        raise SystemExit('Missing RPCS3 build number 260 identity')
    text = text.replace('BUILD_NUMBER=260', 'BUILD_NUMBER=262')
    text = text.replace(
        'NeoStation-iOS-Build-260-Modern-Dolphin',
        'NeoStation-iOS-Build-262-FullTheme',
    )
    CORE.write_text(text)

    text = TUNNEL.read_text()
    text = replace_once(
        text,
        "ENV.fetch('BUILD_NUMBER', '260')",
        "ENV.fetch('BUILD_NUMBER', '262')",
        'local tunnel build identity',
    )
    TUNNEL.write_text(text)


def cleanup_full_theme_service() -> None:
    text = FULL_THEME_SERVICE.read_text()
    text = text.replace("import 'dart:typed_data';\n", '')
    FULL_THEME_SERVICE.write_text(text)


def write_contract() -> None:
    CONTRACT.write_text("""from pathlib import Path

settings = Path('lib/screens/settings_screen/new_settings_options/themes_settings_content.dart').read_text()
workflow = Path('.github/workflows/build-ipa-once.yml').read_text()
dolphin_patch = Path('build-utils/patch_dolphin_internal_core_v2.py').read_text()

def require(text, *markers):
    for marker in markers:
        assert marker in text, marker

require(
    settings,
    'FullThemeLocale.title(context)',
    '_FullThemeCategoryCard',
    'fullThemeIndex',
    \"allowedExtensions: const ['zip']\",
    'FullThemeService.instance.importZip',
    'activeTheme?.name ?? FullThemeLocale.import(context)',
)
require(
    workflow,
    'Build 262',
    'work/full-theme-build262-sync260',
    'patch_rpcs3_build260_modern_menu.py',
    'dolphin_achievements_hacks_menu_test.py',
    'integrated_import_tab_contract_test.py',
    '-DUSE_RETRO_ACHIEVEMENTS=ON',
)
require(
    dolphin_patch,
    'neostation_dolphin_configure_achievements',
    'NEOSTATION_DOLPHIN_HACKS_V1',
)
print('Build 262 Full Theme + Build 260 preservation contract passed')
""")


if __name__ == '__main__':
    patch_settings()
    patch_workflow()
    patch_build_identity()
    cleanup_full_theme_service()
    write_contract()
    print('Build 262 integration patch applied')
