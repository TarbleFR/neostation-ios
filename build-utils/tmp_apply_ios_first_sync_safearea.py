from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)


# ---------------------------------------------------------------------------
# First-run iOS library linking
# ---------------------------------------------------------------------------
p = Path("lib/widgets/setup_wizard.dart")
s = p.read_text()

s = replace_once(
    s,
    "  bool _finishing = false;\n",
    "  bool _finishing = false;\n\n"
    "  // iOS first-run library linking is kicked off automatically once the app is\n"
    "  // active. This guard prevents duplicate document pickers across lifecycle\n"
    "  // transitions while RetroArch hands the user back to NeoStation.\n"
    "  bool _initialIosLibraryLinkStarted = false;\n",
    "setup guard field",
)

s = replace_once(
    s,
    "    _initializeSteps();\n    _initGamepad();\n    if (Platform.isAndroid) {\n",
    "    _initializeSteps();\n"
    "    _initGamepad();\n"
    "    if (Platform.isIOS) {\n"
    "      WidgetsBinding.instance.addPostFrameCallback((_) async {\n"
    "        await _startInitialIosLibraryLinkIfNeeded();\n"
    "      });\n"
    "    }\n"
    "    if (Platform.isAndroid) {\n",
    "setup init auto link",
)

s = replace_once(
    s,
    "  void didChangeAppLifecycleState(AppLifecycleState state) {\n"
    "    if (state == AppLifecycleState.resumed && Platform.isAndroid) {\n"
    "      _refreshPermissionStates();\n"
    "      // The gamepad was deactivated before we sent the user to Settings; bring\n"
    "      // it back now that we have focus again on the Permissions step.\n"
    "      if (_currentStep == _stepPermissions) _gamepadNav?.activate();\n"
    "    }\n"
    "  }\n",
    "  void didChangeAppLifecycleState(AppLifecycleState state) {\n"
    "    if (state != AppLifecycleState.resumed) return;\n\n"
    "    if (Platform.isAndroid) {\n"
    "      _refreshPermissionStates();\n"
    "      // The gamepad was deactivated before we sent the user to Settings; bring\n"
    "      // it back now that we have focus again on the Permissions step.\n"
    "      if (_currentStep == _stepPermissions) _gamepadNav?.activate();\n"
    "      return;\n"
    "    }\n\n"
    "    // RetroArch's first-run sync temporarily backgrounds NeoStation. Wait for\n"
    "    // the return before presenting the security-scoped folder picker. Manic\n"
    "    // EMU never leaves the app here, so its picker is normally started by the\n"
    "    // initial post-frame callback above.\n"
    "    if (Platform.isIOS) {\n"
    "      _startInitialIosLibraryLinkIfNeeded();\n"
    "    }\n"
    "  }\n",
    "setup lifecycle auto link",
)

auto_method = """  Future<void> _startInitialIosLibraryLinkIfNeeded() async {
    if (!Platform.isIOS ||
        !mounted ||
        _currentStep != _stepFolder ||
        _isSelectingFolder ||
        _initialIosLibraryLinkStarted) {
      return;
    }

    // Do not attempt to present UIDocumentPicker while NeoStation is inactive
    // (notably while RetroArch is still in the foreground for its callback).
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }

    final primary = await IosEmulatorPreferenceService.primary();
    if (!mounted || _currentStep != _stepFolder || _isSelectingFolder) return;

    final existingLink = primary == IosLibraryEmulator.manicEmu
        ? ConfigService.linkedManicEmuFolderPath
        : ConfigService.linkedExternalFolderPath;
    if (existingLink != null && existingLink.trim().isNotEmpty) return;

    _initialIosLibraryLinkStarted = true;
    try {
      // The picker is the one iOS-required user confirmation. Once granted,
      // _selectFolder persists the bookmark, registers the ROM source and runs
      // the real scan immediately, so no trip to Settings > Directories is
      // required on first use.
      await _selectFolder(allowInternalFallback: false);
    } finally {
      // A cancellation leaves the user on the same wizard step, where the main
      // action can retry normally. A successful link advances to Scanning.
      if (mounted && _currentStep == _stepFolder) {
        _initialIosLibraryLinkStarted = false;
      }
    }
  }

  Future<void> _selectFolder({bool allowInternalFallback = true}) async {
"""
s = replace_once(
    s,
    "  Future<void> _selectFolder() async {\n",
    auto_method,
    "setup select folder signature",
)

s = replace_once(
    s,
    "        } else if (mounted) {\n"
    "          // Declined/cancelled the picker — fall back to the internal\n"
    "          // default so onboarding still has somewhere to go.\n"
    "          await configProvider.selectRomFolder(scan: false);\n"
    "          result = configProvider.config.romFolder;\n"
    "        }\n",
    "        } else if (mounted && allowInternalFallback) {\n"
    "          // Manual folder selection retains the historical internal fallback.\n"
    "          // The automatic first-run attempt deliberately stays on this step if\n"
    "          // the picker is cancelled, so it never silently replaces the chosen\n"
    "          // RetroArch/Manic EMU library with NeoStation's private ROM folder.\n"
    "          await configProvider.selectRomFolder(scan: false);\n"
    "          result = configProvider.config.romFolder;\n"
    "        }\n",
    "setup cancel fallback",
)
p.write_text(s)


# ---------------------------------------------------------------------------
# Dynamic Island / landscape safe-area handling in all game playlist views
# ---------------------------------------------------------------------------
p = Path("lib/screens/game_screen/my_games_list.dart")
s = p.read_text()
s = replace_once(
    s,
    "  Widget _buildGamesList() {\n    final availableHeight =\n",
    "  Widget _buildGamesList() {\n"
    "    final safeLeftInset = Platform.isIOS\n"
    "        ? MediaQuery.viewPaddingOf(context).left\n"
    "        : 0.0;\n"
    "    final availableHeight =\n",
    "list safe inset declaration",
)
s = replace_once(
    s,
    "                left: GameLegendVisibility.hidden.value ? 12.r : 72.r,\n",
    "                left:\n"
    "                    safeLeftInset +\n"
    "                    (GameLegendVisibility.hidden.value ? 12.r : 72.r),\n",
    "list sidebar safe inset",
)
s = replace_once(
    s,
    "            left: GameLegendVisibility.hidden.value ? -72.r : 10.r,\n",
    "            left: GameLegendVisibility.hidden.value\n"
    "                ? -(72.r + safeLeftInset)\n"
    "                : safeLeftInset + 10.r,\n",
    "list legend safe inset",
)
p.write_text(s)

p = Path("lib/screens/game_screen/my_games_grid.dart")
s = p.read_text()
s = replace_once(
    s,
    "    _buildSettledChrome();\n\n    return Stack(\n",
    "    _buildSettledChrome();\n"
    "    final safeLeftInset = Platform.isIOS\n"
    "        ? MediaQuery.viewPaddingOf(context).left\n"
    "        : 0.0;\n\n"
    "    return Stack(\n",
    "grid safe inset declaration",
)
s = replace_once(
    s,
    "                  left: GameLegendVisibility.hidden.value ? 0 : 72.r,\n",
    "                  left:\n"
    "                      safeLeftInset +\n"
    "                      (GameLegendVisibility.hidden.value ? 0 : 72.r),\n",
    "grid content safe inset",
)
s = replace_once(
    s,
    "          left: GameLegendVisibility.hidden.value ? -72.r : 10.r,\n",
    "          left: GameLegendVisibility.hidden.value\n"
    "              ? -(72.r + safeLeftInset)\n"
    "              : safeLeftInset + 10.r,\n",
    "grid legend safe inset",
)
p.write_text(s)

p = Path("lib/screens/game_screen/my_games_carousel.dart")
s = p.read_text()
s = replace_once(
    s,
    "    _buildSettledChrome();\n\n    return Stack(\n",
    "    _buildSettledChrome();\n"
    "    final safeLeftInset = Platform.isIOS\n"
    "        ? MediaQuery.viewPaddingOf(context).left\n"
    "        : 0.0;\n"
    "    final safeRightInset = Platform.isIOS\n"
    "        ? MediaQuery.viewPaddingOf(context).right\n"
    "        : 0.0;\n\n"
    "    return Stack(\n",
    "carousel safe inset declaration",
)
s = replace_once(
    s,
    "                padding: EdgeInsets.symmetric(horizontal: 60.r),\n",
    "                padding: EdgeInsets.only(\n"
    "                  left: 60.r + safeLeftInset,\n"
    "                  right: 60.r + safeRightInset,\n"
    "                ),\n",
    "carousel content safe inset",
)
s = replace_once(
    s,
    "          left: GameLegendVisibility.hidden.value ? -72.r : 10.r,\n",
    "          left: GameLegendVisibility.hidden.value\n"
    "              ? -(72.r + safeLeftInset)\n"
    "              : safeLeftInset + 10.r,\n",
    "carousel legend safe inset",
)
p.write_text(s)


# Bump the package built from this complete change set.
p = Path("pubspec.yaml")
s = p.read_text()
s = replace_once(s, "version: 1.0.0+158", "version: 1.0.0+159", "build number")
p.write_text(s)
