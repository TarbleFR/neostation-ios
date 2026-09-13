import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/local_jit_tunnel_locale.dart';

void main() {
  test('local JIT VPN copy is complete in all 12 supported languages', () {
    expect(LocalJitTunnelLocale.supportedLocaleKeys, hasLength(12));

    for (final locale in LocalJitTunnelLocale.supportedLocaleKeys) {
      expect(
        LocalJitTunnelLocale.missingKeysForLocale(locale),
        isEmpty,
        reason: 'Missing local JIT VPN text for $locale',
      );
      for (final key in LocalJitTunnelLocale.allKeys) {
        final value = LocalJitTunnelLocale.getForLocale(locale, key).trim();
        expect(value, isNotEmpty, reason: '$locale/$key is empty');
        expect(value, isNot(key), reason: '$locale/$key used a key fallback');
      }
    }
  });

  test('French VPN flow exposes every required action and state', () {
    String fr(String key) => LocalJitTunnelLocale.getForLocale('fr', key);

    expect(fr(LocalJitTunnelLocale.authorizeAction), 'Autoriser le VPN');
    expect(fr(LocalJitTunnelLocale.enableAction), 'Activer le VPN');
    expect(fr(LocalJitTunnelLocale.disableAction), 'Désactiver le VPN');
    expect(fr(LocalJitTunnelLocale.notAuthorized), 'VPN non autorisé');
    expect(fr(LocalJitTunnelLocale.authorized), 'VPN autorisé');
    expect(fr(LocalJitTunnelLocale.active), 'VPN activé');
    expect(fr(LocalJitTunnelLocale.inactive), 'VPN désactivé');
    expect(
      fr(LocalJitTunnelLocale.connecting),
      contains('Activation en cours'),
    );
    expect(fr(LocalJitTunnelLocale.errorStatus), 'Erreur VPN');
  });
}
