#!/usr/bin/env python3
"""Apply after the existing Build 243/246/247/251 host patches."""
from pathlib import Path
import re
import sys

root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path.cwd()
classes = root / 'packages/rpcs3_internal_bridge/ios/Classes'
target = classes / 'Rpcs3InternalBridgePlugin.mm'
text = target.read_text()

def replace_once(old, new):
    global text
    if text.count(old) != 1:
        raise SystemExit(f'Savestate UI: expected one anchor: {old[:90]!r}')
    text = text.replace(old, new, 1)

if 'NEOSTATION_SAVESTATE_PROGRESS_V1' not in text:
    replace_once('  LOAD("neostation_rpcs3_ios_save_state", save_state);',
                 '  LOAD("neostation_rpcs3_ios_save_state", save_state);\n'
                 '  LOAD("neostation_rpcs3_ios_get_savestate_status", get_savestate_status);')
    start = text.index('- (void)saveCurrentState {')
    end = text.index('\n- (void)loadSavestateIdentifier:', start)
    text = text[:start] + '''// NEOSTATION_SAVESTATE_PROGRESS_V1
// Keep ownership visible until the native write AND automatic restoration end.
- (void)finishSavestateAlert:(UIAlertController*)alert success:(BOOL)success message:(NSString*)message {
  dispatch_async(dispatch_get_main_queue(), ^{
    alert.message = success ? [self localized:@"stateDone"] :
        [NSString stringWithFormat:@"%@\\n%@", [self localized:@"stateFailed"], message ?: @""];
    [alert addAction:[UIAlertAction actionWithTitle:[self localized:@"ok"]
                                            style:UIAlertActionStyleDefault handler:nil]];
  });
}

- (void)pollSavestateAlert:(UIAlertController*)alert {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), _runtimeQueue, ^{
    uint32_t phase = 0;
    char reason[2048] = {};
    rpcs3_ios_status status = self->_api.get_savestate_status
        ? self->_api.get_savestate_status(&phase, reason, sizeof(reason)) : -1;
    if (status == 0 && phase >= 1 && phase <= 3) {
      [self pollSavestateAlert:alert];
      return;
    }
    NSString* message = status == 0 ? ([NSString stringWithUTF8String:reason] ?: @"") : [self lastError];
    RPCS3Diagnostic(@"savestate_complete", [NSString stringWithFormat:@"phase=%u status=%d %@", phase, status, message]);
    [self finishSavestateAlert:alert success:(status == 0 && phase == 4) message:message];
  });
}

- (void)saveCurrentState {
  dispatch_async(dispatch_get_main_queue(), ^{
    RPCS3GameViewController* controller = self.gameController;
    if (!controller) return;
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:[self localized:@"state"]
        message:[self localized:@"stateStarted"] preferredStyle:UIAlertControllerStyleAlert];
    alert.modalInPresentation = YES;
    void (^start)(void) = ^{
      [controller presentViewController:alert animated:YES completion:^{
        dispatch_async(self->_runtimeQueue, ^{
          rpcs3_ios_status status = self->_api.save_state ? self->_api.save_state() : -1;
          if (status == 0) {
            RPCS3Diagnostic(@"savestate_save", @"requested; waiting for native completion");
            [self pollSavestateAlert:alert];
          } else {
            [self finishSavestateAlert:alert success:NO message:[self lastError]];
          }
        });
      }];
    };
    if (controller.presentedViewController) {
      [controller dismissViewControllerAnimated:NO completion:start];
    } else start();
  });
}
''' + text[end:]
    replace_once('''    BOOL ok = YES;
    if (self->_performanceTimer) {''', '''    BOOL ok = YES;
    if (self.initialized && self->_api.stop_emulation) ok = self->_api.stop_emulation() == 0;
    if (!ok) {
      [self showMessage:[self localized:@"state"] message:[self lastError]];
      dispatch_async(dispatch_get_main_queue(), ^{ if (result) result(@NO); });
      return; // Keep Metal, controls and audio attached while the save owns Emu.
    }
    if (self->_performanceTimer) {''')
    replace_once('''    if (self.initialized && self->_api.stop_emulation) ok = self->_api.stop_emulation() == 0;
    if (self.initialized && self->_api.set_display_surface)''',
                 '''    if (self.initialized && self->_api.set_display_surface)''')
    replace_once('''      if (self->_performanceTimer) { dispatch_source_cancel(self->_performanceTimer); self->_performanceTimer = nil; }
      if (self.gameController && self->_api.stop_emulation) self->_api.stop_emulation();''',
                 '''      rpcs3_ios_status stopStatus = self->_api.stop_emulation ? self->_api.stop_emulation() : 0;
      if (stopStatus != 0) {
        NSDictionary* failure = [self statusPayload:stopStatus];
        dispatch_async(dispatch_get_main_queue(), ^{ result(failure); });
        return;
      }
      if (self->_performanceTimer) { dispatch_source_cancel(self->_performanceTimer); self->_performanceTimer = nil; }''')
    target.write_text(text)

target = classes / 'Rpcs3CoreABI.h'
text = target.read_text()
if '(*get_savestate_status)' not in text:
    replace_once('  rpcs3_ios_status (*save_state)(void);',
                 '  rpcs3_ios_status (*save_state)(void);\n'
                 '  rpcs3_ios_status (*get_savestate_status)(uint32_t*, char*, size_t);')
    target.write_text(text)

labels = {
    'en': ('Save state created and restored.', 'Save-state operation failed.'),
    'fr': ('Savestate créée et rechargée.', 'Échec de l’opération de savestate.'),
    'de': ('Spielstand erstellt und wiederhergestellt.', 'Spielstandvorgang fehlgeschlagen.'),
    'es': ('Estado creado y restaurado.', 'Falló la operación del estado de guardado.'),
    'it': ('Stato creato e ripristinato.', 'Operazione sullo stato non riuscita.'),
    'pt': ('Estado criado e restaurado.', 'A operação do estado falhou.'),
    'ru': ('Состояние сохранено и восстановлено.', 'Операция с сохранением состояния не удалась.'),
    'ja': ('ステートを保存して復元しました。', 'ステート操作に失敗しました。'),
    'ko': ('상태를 저장하고 복원했습니다.', '상태 저장 작업에 실패했습니다.'),
    'zh': ('即时存档已创建并恢复。', '即时存档操作失败。'),
    'zh_Hant': ('即時存檔已建立並還原。', '即時存檔操作失敗。'),
    'id': ('Status permainan dibuat dan dipulihkan.', 'Operasi status permainan gagal.'),
}
target = classes / 'RPCS3InGameLocalization.mm'
text = target.read_text()
if '@"stateDone"' not in text:
    for locale, (done, failed) in labels.items():
        anchor = f'      @"{locale}": @{{\n'
        replace_once(anchor, anchor + f'        @"stateDone": @"{done}", @"stateFailed": @"{failed}",\n')
    target.write_text(text)
print('NeoStation savestate progress/ownership UI patch: OK')
