#!/usr/bin/env python3
"""Build 262 integration patch.

Keeps Build 260 as the source baseline while applying the converged Build 262
runtime fixes before Flutter/Xcode compilation. The patch is intentionally
idempotent because the existing CI applies host patchers twice to detect drift.
"""
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def write(relative: str, text: str) -> None:
    (ROOT / relative).write_text(text, encoding="utf-8")


def replace_once(relative: str, old: str, new: str, marker: str) -> None:
    text = read(relative)
    if marker in text:
        return
    if old not in text:
        raise SystemExit(f"Build 262 patch anchor drifted in {relative}: {old[:80]!r}")
    write(relative, text.replace(old, new, 1))


def patch_vpn_provider() -> None:
    relative = "native/local_jit_tunnel/PacketTunnelProvider.swift"
    text = read(relative)
    # LocalDevVPN's working provider deliberately leaves MTU selection to iOS.
    # Keeping the provider as close as possible to that proven packet-reflection
    # path removes one unnecessary variable from tunnel startup on iOS 27.
    text = text.replace("    settings.mtu = 1500\n", "")
    write(relative, text)


def patch_vpn_manager() -> None:
    relative = (
        "packages/stikjit_bridge/ios/Classes/NeoStationLocalTunnelManager.swift"
    )
    text = read(relative)

    text = text.replace("static let schemaVersion = 1", "static let schemaVersion = 2")
    if "initialConnectionGrace" not in text:
        anchor = "    static let connectionPollInterval: TimeInterval = 0.25\n"
        if anchor not in text:
            raise SystemExit("Build 262 VPN timing anchor drifted")
        text = text.replace(
            anchor,
            anchor
            + "    static let initialConnectionGrace: TimeInterval = 3\n"
            + "    static let recoveryStopTimeout: TimeInterval = 5\n",
            1,
        )

    old_on_demand = """    let onDemand = NEOnDemandRuleConnect()\n    onDemand.interfaceTypeMatch = .any\n    manager.onDemandRules = [onDemand]\n"""
    new_on_demand = """    // Do not use an unconditional NEOnDemandRuleConnect here. On a freshly\n    // saved profile iOS can move the connection to .connecting before our\n    // explicit startVPNTunnel call, leaving the provider waiting forever.\n    // LocalDevVPN uses EvaluateConnection for the same RemotePairing route.\n    let onDemand = NEOnDemandRuleEvaluateConnection()\n    onDemand.interfaceTypeMatch = .any\n    onDemand.connectionRules = [\n      NEEvaluateConnectionRule(\n        matchDomains: [\n          Constants.interfaceAddress,\n          Constants.peerAddress,\n        ],\n        andAction: .connectIfNeeded\n      ),\n    ]\n    manager.onDemandRules = [onDemand]\n"""
    if "NEOnDemandRuleEvaluateConnection()" not in text:
        if old_on_demand not in text:
            raise SystemExit("Build 262 VPN on-demand anchor drifted")
        text = text.replace(old_on_demand, new_on_demand, 1)

    old_start = """  private func start(_ manager: NETunnelProviderManager) {\n    if manager.connection.status == .connected {\n      finishEnsure(.success(response(for: manager)))\n      return\n    }\n    if !Self.isActive(manager.connection.status) {\n      do {\n        try manager.connection.startVPNTunnel(options: [\n          Constants.interfaceAddressKey: Constants.interfaceAddress as NSString,\n          Constants.peerAddressKey: Constants.peerAddress as NSString,\n        ])\n      } catch {\n        finishEnsure(.failure(.start(error.localizedDescription)))\n        return\n      }\n    }\n    waitUntilConnected(\n      manager,\n      deadline: Date().addingTimeInterval(Constants.connectionTimeout)\n    )\n  }\n"""
    new_start = """  private func start(_ manager: NETunnelProviderManager) {\n    switch manager.connection.status {\n    case .connected:\n      finishEnsure(.success(response(for: manager)))\n    case .connecting, .reasserting:\n      // A freshly saved on-demand profile may transiently enter .connecting.\n      // Give it a short chance to complete, then recover by stopping the stale\n      // attempt and issuing the explicit start that launches our provider.\n      waitForExistingConnectionOrRestart(\n        manager,\n        deadline: Date().addingTimeInterval(Constants.initialConnectionGrace)\n      )\n    default:\n      startExplicitly(manager)\n    }\n  }\n\n  private func waitForExistingConnectionOrRestart(\n    _ manager: NETunnelProviderManager,\n    deadline: Date\n  ) {\n    switch manager.connection.status {\n    case .connected:\n      finishEnsure(.success(response(for: manager)))\n      return\n    case .invalid:\n      finishEnsure(\n        .failure(.configuration(\"The saved VPN configuration is invalid.\"))\n      )\n      return\n    case .disconnected:\n      startExplicitly(manager)\n      return\n    default:\n      break\n    }\n\n    guard Date() < deadline else {\n      manager.connection.stopVPNTunnel()\n      waitUntilStoppedThenStart(\n        manager,\n        deadline: Date().addingTimeInterval(Constants.recoveryStopTimeout)\n      )\n      return\n    }\n    DispatchQueue.main.asyncAfter(\n      deadline: .now() + Constants.connectionPollInterval\n    ) {\n      self.waitForExistingConnectionOrRestart(manager, deadline: deadline)\n    }\n  }\n\n  private func waitUntilStoppedThenStart(\n    _ manager: NETunnelProviderManager,\n    deadline: Date\n  ) {\n    switch manager.connection.status {\n    case .disconnected:\n      startExplicitly(manager)\n      return\n    case .invalid:\n      finishEnsure(\n        .failure(.configuration(\"The saved VPN configuration became invalid during recovery.\"))\n      )\n      return\n    default:\n      break\n    }\n\n    guard Date() < deadline else {\n      finishEnsure(\n        .failure(\n          .start(\n            \"A stale VPN connection could not be reset. Final iOS status: \"\n              + Self.statusName(manager.connection.status)\n          )\n        )\n      )\n      return\n    }\n    DispatchQueue.main.asyncAfter(\n      deadline: .now() + Constants.connectionPollInterval\n    ) {\n      self.waitUntilStoppedThenStart(manager, deadline: deadline)\n    }\n  }\n\n  private func startExplicitly(_ manager: NETunnelProviderManager) {\n    do {\n      try manager.connection.startVPNTunnel(options: [\n        Constants.interfaceAddressKey: Constants.interfaceAddress as NSString,\n        Constants.peerAddressKey: Constants.peerAddress as NSString,\n      ])\n    } catch {\n      finishEnsure(.failure(.start(error.localizedDescription)))\n      return\n    }\n    waitUntilConnected(\n      manager,\n      deadline: Date().addingTimeInterval(Constants.connectionTimeout)\n    )\n  }\n"""
    if "waitForExistingConnectionOrRestart" not in text:
        if old_start not in text:
            raise SystemExit("Build 262 VPN start anchor drifted")
        text = text.replace(old_start, new_start, 1)

    text = text.replace(
        "      finishEnsure(.failure(.timeout))",
        "      finishEnsure(.failure(.timeout(Self.statusName(manager.connection.status))))",
    )

    text = text.replace("  case timeout\n", "  case timeout(String)\n")
    text = text.replace(
        "    case .timeout: return \"connection_timeout\"",
        "    case .timeout(_): return \"connection_timeout\"",
    )
    text = text.replace(
        "    case .timeout:\n      return \"The NeoStation local JIT tunnel did not become ready before the timeout.\"",
        "    case .timeout(let status):\n      return \"The NeoStation local JIT tunnel did not become ready before the timeout. Final iOS status: \\(status).\"",
    )
    write(relative, text)


def patch_vpn_build_configuration() -> None:
    relative = "build-utils/configure_local_jit_tunnel.py"
    text = read(relative)
    # NETunnelProviderManager uses the Network Extension capability. The
    # Personal VPN entitlement (`vpn.api` / `allow-vpn`) belongs to the separate
    # NEVPNManager contract and must not be mixed into Packet Tunnel signing.
    if "com.apple.developer.networking.vpn.api" in text or "allow-vpn" in text:
        raise SystemExit("Build 262 must not mix Personal VPN and Packet Tunnel")
    text = text.replace("ENV.fetch('BUILD_NUMBER', '260')", "ENV.fetch('BUILD_NUMBER', '262')")
    write(relative, text)


def patch_vpn_contract_test() -> None:
    relative = "test/local_jit_tunnel_contract_test.py"
    text = read(relative)
    text = text.replace(
        "self.assertIn('NEOnDemandRuleConnect()', manager)",
        "self.assertIn('NEOnDemandRuleEvaluateConnection()', manager)\n        self.assertIn('NEEvaluateConnectionRule(', manager)\n        self.assertIn('waitForExistingConnectionOrRestart', manager)",
    )
    write(relative, text)


def patch_full_theme_service() -> None:
    relative = "lib/services/full_theme_service.dart"
    text = read(relative)
    if "arcadePlanetRevision" not in text:
        anchor = "  static const _manifestFileName = 'neostation_full_theme.json';\n"
        if anchor not in text:
            raise SystemExit("Build 262 full-theme constant anchor drifted")
        constants = """  static const arcadePlanetRevision =\n      '4314e02ad7fdc0abec4cfba17ddfc1ea735b6fbf';\n  static final Uri arcadePlanetArchiveUri = Uri.parse(\n    'https://codeload.github.com/EvilDindon/ES-THEME-ARCADEPLANET/zip/$arcadePlanetRevision',\n  );\n  static const int _maxRemoteArchiveBytes = 700 * 1024 * 1024;\n"""
        text = text.replace(anchor, anchor + constants, 1)

    if "Future<FullThemeDefinition> downloadArcadePlanet" not in text:
        anchor = "  Future<void> removeActiveTheme() async {\n"
        if anchor not in text:
            raise SystemExit("Build 262 full-theme method anchor drifted")
        method = r'''  /// Downloads the curated Arcade Planet package from its original GitHub
  /// repository. The revision is pinned so an upstream change cannot silently
  /// alter the interface users receive between NeoStation releases.
  Future<FullThemeDefinition> downloadArcadePlanet({
    void Function(double progress)? onProgress,
  }) async {
    final temporaryRoot = Directory(
      p.join(Directory.systemTemp.path, 'neostation_full_theme_downloads'),
    );
    await temporaryRoot.create(recursive: true);
    final archive = File(
      p.join(
        temporaryRoot.path,
        'arcade_planet_${DateTime.now().microsecondsSinceEpoch}.zip',
      ),
    );

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30)
      ..idleTimeout = const Duration(seconds: 90);
    try {
      onProgress?.call(0);
      final request = await client.getUrl(arcadePlanetArchiveUri);
      request.headers.set(HttpHeaders.userAgentHeader, 'NeoStation-iOS');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'Arcade Planet download failed with HTTP ${response.statusCode}',
          uri: arcadePlanetArchiveUri,
        );
      }
      final expected = response.contentLength;
      if (expected > _maxRemoteArchiveBytes) {
        throw const FileSystemException('Arcade Planet archive is too large');
      }

      var received = 0;
      final sink = archive.openWrite();
      try {
        await for (final chunk in response) {
          received += chunk.length;
          if (received > _maxRemoteArchiveBytes) {
            throw const FileSystemException('Arcade Planet archive is too large');
          }
          sink.add(chunk);
          if (expected > 0) {
            onProgress?.call((received / expected).clamp(0.0, 1.0));
          }
        }
      } finally {
        await sink.close();
      }
      if (received == 0) {
        throw const FileSystemException('Arcade Planet download was empty');
      }
      onProgress?.call(1);
      final installed = await importZip(archive);
      _log.i(
        '[FullTheme] Downloaded Arcade Planet revision $arcadePlanetRevision.',
      );
      return installed;
    } finally {
      client.close(force: true);
      try {
        if (await archive.exists()) await archive.delete();
      } catch (_) {}
      try {
        if (await temporaryRoot.exists() &&
            await temporaryRoot.list(followLinks: false).isEmpty) {
          await temporaryRoot.delete();
        }
      } catch (_) {}
    }
  }

'''
        text = text.replace(anchor, method + anchor, 1)
    write(relative, text)


def patch_full_theme_locale() -> None:
    relative = "lib/l10n/full_theme_locale.dart"
    text = read(relative)
    if "_downloadArcadePlanet" not in text:
        anchor = "  static const Map<String, String> _replace = {\n"
        if anchor not in text:
            raise SystemExit("Build 262 full-theme locale anchor drifted")
        maps = """  static const Map<String, String> _downloadArcadePlanet = {\n    'de': 'Arcade Planet herunterladen',\n    'en': 'Download Arcade Planet',\n    'es': 'Descargar Arcade Planet',\n    'fr': 'Télécharger Arcade Planet',\n    'id': 'Unduh Arcade Planet',\n    'it': 'Scarica Arcade Planet',\n    'ja': 'Arcade Planetをダウンロード',\n    'ko': 'Arcade Planet 다운로드',\n    'pt': 'Baixar Arcade Planet',\n    'ru': 'Скачать Arcade Planet',\n    'zh': '下载 Arcade Planet',\n    'zh_Hant': '下載 Arcade Planet',\n  };\n\n  static const Map<String, String> _downloading = {\n    'de': 'Arcade Planet wird heruntergeladen…',\n    'en': 'Downloading Arcade Planet…',\n    'es': 'Descargando Arcade Planet…',\n    'fr': 'Téléchargement d’Arcade Planet…',\n    'id': 'Mengunduh Arcade Planet…',\n    'it': 'Download di Arcade Planet…',\n    'ja': 'Arcade Planetをダウンロード中…',\n    'ko': 'Arcade Planet 다운로드 중…',\n    'pt': 'Baixando Arcade Planet…',\n    'ru': 'Загрузка Arcade Planet…',\n    'zh': '正在下载 Arcade Planet…',\n    'zh_Hant': '正在下載 Arcade Planet…',\n  };\n\n  static const Map<String, String> _downloadError = {\n    'de': 'Arcade Planet konnte nicht heruntergeladen werden.',\n    'en': 'Arcade Planet could not be downloaded.',\n    'es': 'No se pudo descargar Arcade Planet.',\n    'fr': 'Impossible de télécharger Arcade Planet.',\n    'id': 'Arcade Planet tidak dapat diunduh.',\n    'it': 'Impossibile scaricare Arcade Planet.',\n    'ja': 'Arcade Planetをダウンロードできませんでした。',\n    'ko': 'Arcade Planet을 다운로드할 수 없습니다.',\n    'pt': 'Não foi possível baixar Arcade Planet.',\n    'ru': 'Не удалось скачать Arcade Planet.',\n    'zh': '无法下载 Arcade Planet。',\n    'zh_Hant': '無法下載 Arcade Planet。',\n  };\n\n"""
        text = text.replace(anchor, maps + anchor, 1)

    static_anchor = "  static String replace(BuildContext context) => _lookup(_replace, context);\n"
    if "static String downloadArcadePlanet" not in text:
        if static_anchor not in text:
            raise SystemExit("Build 262 full-theme locale method anchor drifted")
        methods = """  static String downloadArcadePlanet(BuildContext context) =>\n      _lookup(_downloadArcadePlanet, context);\n  static String downloading(BuildContext context) =>\n      _lookup(_downloading, context);\n  static String downloadError(BuildContext context) =>\n      _lookup(_downloadError, context);\n"""
        text = text.replace(static_anchor, methods + static_anchor, 1)
    write(relative, text)


def patch_full_theme_settings() -> None:
    relative = (
        "lib/screens/settings_screen/new_settings_options/themes_settings_content.dart"
    )
    text = read(relative)

    if "_fullThemeDownloadInProgress" not in text:
        old = "  final _log = LoggerService.instance;\n  final ScrollController _scrollController = ScrollController();\n"
        new = "  final _log = LoggerService.instance;\n  final ScrollController _scrollController = ScrollController();\n  bool _fullThemeDownloadInProgress = false;\n"
        if old not in text:
            raise SystemExit("Build 262 settings state anchor drifted")
        text = text.replace(old, new, 1)

    old_null = """    if (active == null) {\n      await _pickFullTheme();\n      return;\n    }\n"""
    new_null = """    if (active == null) {\n      await _showFullThemeInstallActions();\n      return;\n    }\n"""
    if "await _showFullThemeInstallActions();" not in text:
        if old_null not in text:
            raise SystemExit("Build 262 full-theme empty-state anchor drifted")
        text = text.replace(old_null, new_null, 1)

    if "Future<void> _showFullThemeInstallActions()" not in text:
        anchor = "  Future<void> _showFullThemeActions() async {\n"
        if anchor not in text:
            raise SystemExit("Build 262 full-theme actions anchor drifted")
        method = r'''  Future<void> _showFullThemeInstallActions() async {
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
              Text(FullThemeLocale.description(dialogContext)),
              SizedBox(height: 14.r),
              ListTile(
                leading: const Icon(Symbols.download_rounded),
                title: Text(
                  FullThemeLocale.downloadArcadePlanet(dialogContext),
                ),
                onTap: _fullThemeDownloadInProgress
                    ? null
                    : () {
                        Navigator.of(dialogContext).pop();
                        _downloadArcadePlanet();
                      },
              ),
              ListTile(
                leading: const Icon(Symbols.folder_open_rounded),
                title: Text(FullThemeLocale.import(dialogContext)),
                onTap: () {
                  Navigator.of(dialogContext).pop();
                  _pickFullTheme();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

'''
        text = text.replace(anchor, method + anchor, 1)

    if "FullThemeLocale.downloadArcadePlanet(dialogContext)" in text and text.count(
        "FullThemeLocale.downloadArcadePlanet(dialogContext)"
    ) == 1:
        old = """              ListTile(\n                leading: const Icon(Symbols.folder_open_rounded),\n                title: Text(FullThemeLocale.replace(dialogContext)),\n"""
        new = """              ListTile(\n                leading: const Icon(Symbols.download_rounded),\n                title: Text(\n                  FullThemeLocale.downloadArcadePlanet(dialogContext),\n                ),\n                onTap: _fullThemeDownloadInProgress\n                    ? null\n                    : () {\n                        Navigator.of(dialogContext).pop();\n                        _downloadArcadePlanet();\n                      },\n              ),\n              ListTile(\n                leading: const Icon(Symbols.folder_open_rounded),\n                title: Text(FullThemeLocale.replace(dialogContext)),\n"""
        if old not in text:
            raise SystemExit("Build 262 active full-theme action anchor drifted")
        text = text.replace(old, new, 1)

    if "Future<void> _downloadArcadePlanet()" not in text:
        anchor = "  Future<void> _pickFullTheme() async {\n"
        if anchor not in text:
            raise SystemExit("Build 262 full-theme picker anchor drifted")
        method = r'''  Future<void> _downloadArcadePlanet() async {
    if (_fullThemeDownloadInProgress) return;
    setState(() => _fullThemeDownloadInProgress = true);
    AppNotification.showNotification(
      context,
      FullThemeLocale.downloading(context),
      type: NotificationType.info,
    );
    try {
      final imported = await FullThemeService.instance.downloadArcadePlanet();
      if (!mounted) return;
      setState(() {});
      AppNotification.showNotification(
        context,
        FullThemeLocale.success(context, imported.name),
        type: NotificationType.success,
      );
    } catch (e) {
      _log.e('Arcade Planet download failed: $e');
      if (!mounted) return;
      AppNotification.showNotification(
        context,
        FullThemeLocale.downloadError(context),
        type: NotificationType.error,
      );
    } finally {
      if (mounted) {
        setState(() => _fullThemeDownloadInProgress = false);
      }
    }
  }

'''
        text = text.replace(anchor, method + anchor, 1)

    text = text.replace(
        "activeTheme?.name ?? FullThemeLocale.import(context)",
        "activeTheme?.name ?? FullThemeLocale.downloadArcadePlanet(context)",
    )
    write(relative, text)


def main() -> None:
    patch_vpn_provider()
    patch_vpn_manager()
    patch_vpn_build_configuration()
    patch_vpn_contract_test()
    patch_full_theme_service()
    patch_full_theme_locale()
    patch_full_theme_settings()
    print("NeoStation Build 262 VPN/full-theme integration patch applied")


if __name__ == "__main__":
    main()
