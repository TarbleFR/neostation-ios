#!/usr/bin/env python3
"""Idempotent Build 267 host-only fix, applied before host tests/scaffolding.

Dolphin's game token is NOT the dashboard Web API key. Account changes are
validated and staged for the next full game launch; never reconfigure a live
AchievementManager or silently discard unsaved game progress.
"""
from pathlib import Path
import json
import re

ROOT = Path(__file__).resolve().parents[1]
CLASSES = ROOT / 'packages/dolphin_internal_bridge/ios/Classes'


def replace(path, old, new):
    text = path.read_text()
    if new in text:
        return
    if text.count(old) != 1:
        raise RuntimeError(f'{path.name}: expected one source anchor, found {text.count(old)}: {old[:90]}')
    path.write_text(text.replace(old, new, 1))


serializer = r'''
// Shared by the menu and bridge so native callers cannot bypass validation.
NSData* DOLSerializeMenuRequest(id request) {
  @try {
    if (![request isKindOfClass:NSDictionary.class] ||
        ![request[@"kind"] isKindOfClass:NSString.class] ||
        ![request[@"kind"] length] || ![NSJSONSerialization isValidJSONObject:request]) return nil;
    NSError* error = nil;
    NSData* data = [NSJSONSerialization dataWithJSONObject:request options:0 error:&error];
    return error ? nil : data;
  } @catch (NSException* exception) {
    // Never log requests: callers might accidentally include credentials.
    return nil;
  }
}
'''
replace(CLASSES / 'DolphinRetroAchievementsAccount.h', 'NS_ASSUME_NONNULL_BEGIN',
        'NS_ASSUME_NONNULL_BEGIN\nFOUNDATION_EXPORT NSData* _Nullable DOLSerializeMenuRequest(id _Nullable request);')
replace(CLASSES / 'DolphinRetroAchievementsAccount.mm', '#import <Security/Security.h>',
        '#import <Security/Security.h>\n' + serializer)

menu = CLASSES / 'DolphinSessionMenu.mm'
replace(menu, '#import "DolphinSessionMenu.h"',
        '#import "DolphinSessionMenu.h"\n#import "DolphinRetroAchievementsAccount.h"')
replace(menu, '''- (void)apply:(NSDictionary*)request thenReturn:(BOOL)returnToBindings {
  if (self.loading || !self.applySettings) return;''', '''- (void)apply:(NSDictionary*)request thenReturn:(BOOL)returnToBindings {
  if (self.loading || !self.applySettings) return;
  if (!DOLSerializeMenuRequest(request)) { [self showFailure]; return; }''')
replace(menu, '''  NSInteger row = indexPath.row;
  if (self.page == DOLMenuRoot) {
    NSString* key = self.rootKeys[row];
    if ([key isEqual:@"resume"])''', '''  NSInteger row = indexPath.row;
  if (indexPath.section < 0 || indexPath.section >= [self numberOfSectionsInTableView:tableView] ||
      row < 0 || row >= [self tableView:tableView numberOfRowsInSection:indexPath.section]) return;
  // Account is navigation, never a core-setting request. Status/mode are read-only.
  if (self.page == DOLMenuAchievements) {
    if (row == 0 && self.navigationController.topViewController == self) {
      DolphinRetroAchievementsAccount* account = [[DolphinRetroAchievementsAccount alloc]
          initWithLabels:self.labels];
      [self.navigationController pushViewController:account animated:YES];
    }
    return;
  }
  if (self.page == DOLMenuRoot) {
    NSString* key = self.rootKeys[row];
    if ([key isEqual:@"resume"])''')
replace(menu, '''  } else {
    NSDictionary* choice = self.choices[row];
    if (choice[@"wii"] || choice[@"slot"])''', '''  } else if (self.page == DOLMenuChoices) {
    if (row < 0 || row >= self.choices.count) return;
    NSDictionary* choice = self.choices[row];
    if (![choice isKindOfClass:NSDictionary.class]) { [self showFailure]; return; }
    if (choice[@"wii"] || choice[@"slot"])''')
start = '''  } else if (self.page == DOLMenuAchievements) {
    NSDictionary* achievements = self.snapshot[@"achievements"];'''
end = '''  } else if (self.page == DOLMenuControls) {
    if (indexPath.section == 0) {'''
text = menu.read_text()
new_achievements = '''  } else if (self.page == DOLMenuAchievements) {
    // NEOSTATION_DOLPHIN_ACCOUNT_267: keychain identity and runtime status differ.
    NSDictionary* achievements = [self.snapshot[@"achievements"] isKindOfClass:NSDictionary.class]
        ? self.snapshot[@"achievements"] : @{};
    NSString* key = @[@"raAccount", @"raStatus", @"raMode"][row];
    cell.textLabel.text = [self text:key];
    cell.accessoryType = row == 0 ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    cell.selectionStyle = row == 0 ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    cell.userInteractionEnabled = row == 0;
    if (row == 0) {
      NSString* username = [DolphinRetroAchievementsAccount credentials][@"username"];
      cell.detailTextLabel.text = username.length ? username : [self text:@"notConnected"];
    } else if (row == 1) {
      if ([DolphinRetroAchievementsAccount hasPendingChanges])
        cell.detailTextLabel.text = [self text:@"raRestartRequired"];
      else cell.detailTextLabel.text = [self text:
          [achievements[@"enabled"] respondsToSelector:@selector(boolValue)] && [achievements[@"enabled"] boolValue]
            ? ([achievements[@"gameLoaded"] respondsToSelector:@selector(boolValue)] && [achievements[@"gameLoaded"] boolValue]
                ? @"active" : @"enabled") : @"disabled"];
    } else cell.detailTextLabel.text = [self text:
        [achievements[@"hardcore"] respondsToSelector:@selector(boolValue)] && [achievements[@"hardcore"] boolValue]
          ? @"hardcore" : @"standard"];
'''
if 'NEOSTATION_DOLPHIN_ACCOUNT_267' not in text:
    if text.count(start) != 1 or text.count(end) != 1:
        raise RuntimeError('Unexpected achievements cell source')
    begin = text.index(start)
    finish = text.index(end, begin)
    menu.write_text(text[:begin] + new_achievements + text[finish:])

host = CLASSES / 'DolphinInternalBridgePlugin.mm'
replace(host, '#import "DolphinSessionMenu.h"',
        '#import "DolphinSessionMenu.h"\n#import "DolphinRetroAchievementsAccount.h"')
replace(host, '''  NSString* raUsername = [arguments[@"raUsername"] isKindOfClass:NSString.class]
                              ? arguments[@"raUsername"] : @"";
  NSString* raApiToken = [arguments[@"raApiToken"] isKindOfClass:NSString.class]
                              ? arguments[@"raApiToken"] : @"";''', '''  // Only a validated emulator token is accepted. Do not use the Web API key.
  NSDictionary* raCredentials = [DolphinRetroAchievementsAccount credentials];
  NSString* raUsername = raCredentials[@"username"] ?: @"";
  NSString* raApiToken = raCredentials[@"token"] ?: @"";''')
replace(host, '''    // Configure the core without ever logging or persisting credentials in the
    // Objective-C host. Missing credentials simply disable achievements.''', '''    // Take account changes only at a fresh launch, before booting the game.
    // The password is never persisted; the emulator token is read from Keychain.
    [DolphinRetroAchievementsAccount beginSession];''')
replace(host, '''          NSData* data = [NSJSONSerialization dataWithJSONObject:request options:0 error:nil];
          NSString* text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
          const BOOL success = text && neostation_dolphin_menu_apply(text.UTF8String) != 0;''', '''          NSData* data = DOLSerializeMenuRequest(request);
          NSString* text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
          BOOL success = NO;
          @try {
            if (text && !bridge.stopInProgress && bridge.dolphinController == owner)
              success = neostation_dolphin_menu_apply(text.UTF8String) != 0;
          } @catch (NSException* exception) {
            success = NO;
          }
          if (!data) DOLAppendJSONLog(bridge.activeLogPath ?: @"", @"menu.request_rejected",
              @"Invalid Dolphin settings request rejected safely.", nil);''')

# All new visible strings are supplied for the 12 app locales. The account
# Help overrides the old claim that a dashboard Web API key signs into Dolphin.
keys = ('raAccount raUsername raPassword raLink raUnlink raLoginHelp raLoginBusy '
        'raLoginFailed raNetworkFailed raStorageFailed raLinked raUnlinked '
        'raRestartRequired raStatus raMode notConnected enabled disabled active standard hardcore').split()
rows = {
'en': ['Account', 'Username', 'Password', 'Link account', 'Unlink account', 'Sign in with your RetroAchievements username and password, not a Web API key. Your password is not saved. Changes apply after quitting and launching the game again.', 'Signing in…', 'Sign-in failed. Check your username and password.', 'Connection failed. Check your network and try again.', 'The account could not be saved securely. Unlock the device and try again.', 'Account linked. Quit and launch the game again to use it.', 'Account unlinked. Quit and launch the game again to apply this change.', 'Quit and launch the game again to apply account changes.', 'Game status', 'Mode', 'Not connected', 'Enabled', 'Disabled', 'Active for this game', 'Standard', 'Hardcore'],
'fr': ['Compte', 'Nom d’utilisateur', 'Mot de passe', 'Lier le compte', 'Délier le compte', 'Connectez-vous avec votre nom d’utilisateur et votre mot de passe RetroAchievements, pas avec une clé API web. Le mot de passe n’est pas enregistré. Les changements s’appliquent après avoir quitté puis relancé le jeu.', 'Connexion…', 'Échec de connexion. Vérifiez le nom d’utilisateur et le mot de passe.', 'Connexion impossible. Vérifiez le réseau puis réessayez.', 'Impossible d’enregistrer le compte de façon sécurisée. Déverrouillez l’appareil puis réessayez.', 'Compte lié. Quittez puis relancez le jeu pour l’utiliser.', 'Compte délié. Quittez puis relancez le jeu pour appliquer ce changement.', 'Quittez puis relancez le jeu pour appliquer les changements de compte.', 'État du jeu', 'Mode', 'Non connecté', 'Activé', 'Désactivé', 'Actif pour ce jeu', 'Standard', 'Hardcore'],
'de': ['Konto', 'Benutzername', 'Passwort', 'Konto verknüpfen', 'Konto trennen', 'Melde dich mit deinem RetroAchievements-Benutzernamen und Passwort an, nicht mit einem Web-API-Schlüssel. Das Passwort wird nicht gespeichert. Änderungen gelten nach dem Beenden und erneuten Starten des Spiels.', 'Anmeldung läuft…', 'Anmeldung fehlgeschlagen. Prüfe Benutzername und Passwort.', 'Verbindung fehlgeschlagen. Prüfe das Netzwerk und versuche es erneut.', 'Das Konto konnte nicht sicher gespeichert werden. Entsperre das Gerät und versuche es erneut.', 'Konto verknüpft. Beende das Spiel und starte es erneut.', 'Konto getrennt. Beende das Spiel und starte es erneut.', 'Beende das Spiel und starte es erneut, um Kontoänderungen anzuwenden.', 'Spielstatus', 'Modus', 'Nicht verbunden', 'Aktiviert', 'Deaktiviert', 'Für dieses Spiel aktiv', 'Standard', 'Hardcore'],
'es': ['Cuenta', 'Nombre de usuario', 'Contraseña', 'Vincular cuenta', 'Desvincular cuenta', 'Inicia sesión con tu usuario y contraseña de RetroAchievements, no con una clave de API web. La contraseña no se guarda. Los cambios se aplican al salir del juego y volver a iniciarlo.', 'Iniciando sesión…', 'Error de inicio de sesión. Comprueba el usuario y la contraseña.', 'Error de conexión. Comprueba la red y vuelve a intentarlo.', 'No se pudo guardar la cuenta de forma segura. Desbloquea el dispositivo y vuelve a intentarlo.', 'Cuenta vinculada. Sal del juego y vuelve a iniciarlo.', 'Cuenta desvinculada. Sal del juego y vuelve a iniciarlo.', 'Sal del juego y vuelve a iniciarlo para aplicar los cambios de cuenta.', 'Estado del juego', 'Modo', 'Sin conexión', 'Activado', 'Desactivado', 'Activo para este juego', 'Estándar', 'Hardcore'],
'it': ['Account', 'Nome utente', 'Password', 'Collega account', 'Scollega account', 'Accedi con nome utente e password di RetroAchievements, non con una chiave API web. La password non viene salvata. Le modifiche si applicano dopo aver chiuso e riavviato il gioco.', 'Accesso in corso…', 'Accesso non riuscito. Controlla nome utente e password.', 'Connessione non riuscita. Controlla la rete e riprova.', 'Impossibile salvare l’account in modo sicuro. Sblocca il dispositivo e riprova.', 'Account collegato. Chiudi e riavvia il gioco.', 'Account scollegato. Chiudi e riavvia il gioco.', 'Chiudi e riavvia il gioco per applicare le modifiche all’account.', 'Stato del gioco', 'Modalità', 'Non connesso', 'Attivato', 'Disattivato', 'Attivo per questo gioco', 'Standard', 'Hardcore'],
'pt': ['Conta', 'Nome de utilizador', 'Palavra-passe', 'Associar conta', 'Desassociar conta', 'Inicie sessão com o nome de utilizador e a palavra-passe do RetroAchievements, não com uma chave de API web. A palavra-passe não é guardada. As alterações aplicam-se depois de sair do jogo e voltar a iniciá-lo.', 'A iniciar sessão…', 'Falha no início de sessão. Verifique o utilizador e a palavra-passe.', 'Falha de ligação. Verifique a rede e tente novamente.', 'Não foi possível guardar a conta em segurança. Desbloqueie o dispositivo e tente novamente.', 'Conta associada. Saia do jogo e volte a iniciá-lo.', 'Conta desassociada. Saia do jogo e volte a iniciá-lo.', 'Saia do jogo e volte a iniciá-lo para aplicar as alterações da conta.', 'Estado do jogo', 'Modo', 'Não ligado', 'Ativado', 'Desativado', 'Ativo neste jogo', 'Normal', 'Hardcore'],
'ru': ['Учётная запись', 'Имя пользователя', 'Пароль', 'Привязать учётную запись', 'Отвязать учётную запись', 'Войдите с именем пользователя и паролем RetroAchievements, а не с ключом веб-API. Пароль не сохраняется. Изменения применятся после выхода из игры и её повторного запуска.', 'Вход…', 'Не удалось войти. Проверьте имя пользователя и пароль.', 'Ошибка подключения. Проверьте сеть и повторите попытку.', 'Не удалось безопасно сохранить учётную запись. Разблокируйте устройство и повторите попытку.', 'Учётная запись привязана. Выйдите из игры и запустите её снова.', 'Учётная запись отвязана. Выйдите из игры и запустите её снова.', 'Для применения изменений выйдите из игры и запустите её снова.', 'Состояние игры', 'Режим', 'Нет подключения', 'Включено', 'Выключено', 'Активно для этой игры', 'Обычный', 'Хардкор'],
'id': ['Akun', 'Nama pengguna', 'Kata sandi', 'Tautkan akun', 'Putuskan tautan akun', 'Masuk dengan nama pengguna dan kata sandi RetroAchievements, bukan kunci API web. Kata sandi tidak disimpan. Perubahan berlaku setelah keluar dari game dan menjalankannya kembali.', 'Sedang masuk…', 'Gagal masuk. Periksa nama pengguna dan kata sandi.', 'Koneksi gagal. Periksa jaringan lalu coba lagi.', 'Akun tidak dapat disimpan dengan aman. Buka kunci perangkat lalu coba lagi.', 'Akun ditautkan. Keluar dari game lalu jalankan kembali.', 'Tautan akun diputus. Keluar dari game lalu jalankan kembali.', 'Keluar dari game lalu jalankan kembali untuk menerapkan perubahan akun.', 'Status game', 'Mode', 'Belum terhubung', 'Diaktifkan', 'Dinonaktifkan', 'Aktif untuk game ini', 'Standar', 'Hardcore'],
'ja': ['アカウント', 'ユーザー名', 'パスワード', 'アカウントを連携', '連携を解除', 'Web APIキーではなく、RetroAchievementsのユーザー名とパスワードでログインしてください。パスワードは保存されません。変更はゲームを終了して再度起動すると反映されます。', 'ログイン中…', 'ログインできません。ユーザー名とパスワードを確認してください。', '接続できません。ネットワークを確認して再試行してください。', 'アカウントを安全に保存できません。端末のロックを解除して再試行してください。', 'アカウントを連携しました。ゲームを終了して再度起動してください。', '連携を解除しました。ゲームを終了して再度起動してください。', 'アカウントの変更を反映するにはゲームを終了して再度起動してください。', 'ゲームの状態', 'モード', '未接続', '有効', '無効', 'このゲームで有効', '標準', 'ハードコア'],
'ko': ['계정', '사용자 이름', '비밀번호', '계정 연결', '계정 연결 해제', '웹 API 키가 아닌 RetroAchievements 사용자 이름과 비밀번호로 로그인하세요. 비밀번호는 저장되지 않습니다. 변경 사항은 게임을 종료한 후 다시 실행하면 적용됩니다.', '로그인 중…', '로그인에 실패했습니다. 사용자 이름과 비밀번호를 확인하세요.', '연결에 실패했습니다. 네트워크를 확인하고 다시 시도하세요.', '계정을 안전하게 저장할 수 없습니다. 기기 잠금을 해제하고 다시 시도하세요.', '계정이 연결되었습니다. 게임을 종료한 후 다시 실행하세요.', '계정 연결이 해제되었습니다. 게임을 종료한 후 다시 실행하세요.', '계정 변경 사항을 적용하려면 게임을 종료한 후 다시 실행하세요.', '게임 상태', '모드', '연결되지 않음', '활성화', '비활성화', '이 게임에서 활성화됨', '일반', '하드코어'],
'zh': ['账户', '用户名', '密码', '关联账户', '解除关联', '请使用RetroAchievements用户名和密码登录，而不是Web API密钥。密码不会被保存。退出游戏并重新启动后，账户更改才会生效。', '正在登录…', '登录失败。请检查用户名和密码。', '连接失败。请检查网络后重试。', '无法安全保存账户。请解锁设备后重试。', '账户已关联。请退出游戏并重新启动。', '账户已解除关联。请退出游戏并重新启动。', '请退出游戏并重新启动以应用账户更改。', '游戏状态', '模式', '未连接', '已启用', '已禁用', '对此游戏生效', '标准', '硬核'],
'zh_Hant': ['帳戶', '使用者名稱', '密碼', '連結帳戶', '解除連結', '請使用RetroAchievements使用者名稱和密碼登入，而不是Web API金鑰。密碼不會被儲存。離開遊戲並重新啟動後，帳戶變更才會生效。', '正在登入…', '登入失敗。請檢查使用者名稱和密碼。', '連線失敗。請檢查網路後重試。', '無法安全儲存帳戶。請解鎖裝置後重試。', '帳戶已連結。請離開遊戲並重新啟動。', '帳戶已解除連結。請離開遊戲並重新啟動。', '請離開遊戲並重新啟動以套用帳戶變更。', '遊戲狀態', '模式', '未連線', '已啟用', '已停用', '對此遊戲生效', '標準', '硬派'],
}
assert len(rows) == 12
translations = {}
for language, values in rows.items():
    assert len(values) == len(keys), (language, len(values), len(keys))
    translations[language] = dict(zip(keys, values))
    translations[language]['achievementsHelp'] = values[keys.index('raLoginHelp')]
locale = ROOT / 'lib/l10n/dolphin_import_locale.dart'
block = '  static const _accountMenu = <String, Map<String, String>>' + json.dumps(translations, ensure_ascii=False, indent=4) + ';\n\n'
replace(locale, '  static const _modernMenuEn = <String, String>{', block + '  static const _modernMenuEn = <String, String>{')
replace(locale, "      if (key == 'fr') ..._modernMenuFr,", "      if (key == 'fr') ..._modernMenuFr,\n      ..._accountMenu['en']!,\n      ...?_accountMenu[key],")
print('Build 267 Dolphin account flow, safe settings requests and 12 locales applied.')
