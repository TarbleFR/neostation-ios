#!/usr/bin/env python3
"""Materialize one pinned upstream revision as a hosted iOS frontend.

Edits are checked against a pinned checkout and isolated in the output tree;
no patch stack is replayed against NeoStation's other native emulators.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
PINS = json.loads((Path(__file__).with_name('source.json')).read_text())


def replace_once(text, old, new, name):
    if text.count(old) != 1:
        raise ValueError(f'{name}: expected one source anchor, got {text.count(old)}')
    return text.replace(old, new, 1)


def body_range(text, signature):
    """Find C/ObjC body braces while ignoring strings and comments."""
    start = text.index(signature)
    brace = text.index('{', start)
    depth = 0
    quote = None
    comment = None
    i = brace
    while i < len(text):
        c = text[i]
        n = text[i + 1] if i + 1 < len(text) else ''
        if comment == 'line':
            if c == '\n': comment = None
        elif comment == 'block':
            if c == '*' and n == '/': comment = None; i += 1
        elif quote:
            if c == '\\': i += 1
            elif c == quote: quote = None
        elif c == '/' and n == '/': comment = 'line'; i += 1
        elif c == '/' and n == '*': comment = 'block'; i += 1
        elif c in ('"', "'"): quote = c
        elif c == '{': depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0: return brace, i + 1
        i += 1
    raise ValueError(f'Unterminated source body: {signature}')


def set_body(text, signature, body):
    start, end = body_range(text, signature)
    return text[:start] + '{\n' + body + '\n}' + text[end:]


def prepare(upstream, output):
    actual = subprocess.check_output(['git', '-C', str(upstream), 'rev-parse', 'HEAD'], text=True).strip()
    if actual != PINS['frontend']['commit']:
        raise ValueError(f'Frontend source mismatch: {actual}')
    dirty = subprocess.check_output(['git','-C',str(upstream),'status','--porcelain','--untracked-files=no'],text=True)
    if dirty.strip(): raise ValueError('Upstream checkout has modified tracked files')
    if output.exists(): raise ValueError(f'Output already exists; use a fresh directory: {output}')
    shutil.copytree(upstream, output, ignore=shutil.ignore_patterns('.git'))
    common = output / 'ui/drivers/cocoa/cocoa_common.m'
    text = common.read_text()
    text = 'extern void NeoRetroArch_Tick(void);\n' + text
    text = set_body(text, 'static void rarch_draw_observer(', '   NeoRetroArch_Tick();')
    text = set_body(text, '-(void)step:(CADisplayLink*)target', '   NeoRetroArch_Tick();')
    # Observer fast-forward is replaced by the bounded host display-link.
    text = set_body(text, 'void rarch_start_draw_observer(void)', '   /* The host owns frame scheduling. */')
    if 'exit(0)' in text: raise ValueError('Unreviewed application exit remains in Cocoa scheduling')
    text = set_body(text, '-(void)viewWillAppear:(BOOL)animated',
        '    [super viewWillAppear:animated];\n    /* Embedded sessions never start standalone web/Bonjour services. */')
    common.write_text(text)

    touch = output / 'ui/drivers/ui_cocoatouch.m'
    text = touch.read_text()
    text = replace_once(text,
        '+ (RetroArch_iOS*)get { return (RetroArch_iOS*)[[UIApplication sharedApplication] delegate]; }',
        '+ (RetroArch_iOS*)get { return (RetroArch_iOS*)apple_platform; }', 'embedded platform')
    # A shared singleton may be called from upstream diagnostics. It must never
    # be cast to NeoStation's Flutter UIApplication delegate.
    text = set_body(text, '- (void)applicationDidFinishLaunching:(UIApplication *)application',
        '   /* NeoStation creates and owns its UIApplication and window. */')
    text = set_body(text, '- (void)showGameView',
        '   /* CocoaView is mounted in the session host, never UIApplication.window. */')
    start = text.index('int main(int argc, char *argv[])')
    _, end = body_range(text, 'int main(int argc, char *argv[])')
    text = text[:start] + '/* Standalone UIApplicationMain entry deliberately excluded. */\n' + text[end:]
    if 'UIApplicationMain(' in text: raise ValueError('Standalone iOS application entry remains')
    touch.write_text(text)

    gl = output / 'gfx/drivers/gl2.c'
    text = gl.read_text()
    text = 'extern void NeoRetroArch_FramePresented(void);\n' + text
    text = replace_once(text,
        '    if (gl->ctx_driver->swap_buffers)\n        gl->ctx_driver->swap_buffers(gl->ctx_data);\n\n /* Emscripten',
        '    if (gl->ctx_driver->swap_buffers)\n    {\n        gl->ctx_driver->swap_buffers(gl->ctx_data);\n        if (frame && frame_width && frame_height) NeoRetroArch_FramePresented();\n    }\n\n /* Emscripten',
        'presented game frame')
    gl.write_text(text)

    context = output / 'gfx/drivers_context/cocoa_gl_ctx.m'
    text = context.read_text()
    text += '''\n/* Session teardown, after the driver's context destruction. No drawable
 * allocation survives into another emulator or a later RetroArch session. */
void NeoRetroArch_ReleaseRenderResources(void)
{
   if (glk_view)
   {
      glk_view.context = nil;
      [glk_view removeFromSuperview];
      RELEASE(glk_view);
   }
}
'''
    context.write_text(text)

    retro = output / 'retroarch.c'
    text = retro.read_text()
    text = 'extern void NeoRetroArch_RequestMenu(void);\n' + text
    text = replace_once(text, '      case CMD_EVENT_MENU_TOGGLE:',
        '      case CMD_EVENT_MENU_TOGGLE:\n         NeoRetroArch_RequestMenu();\n         return true;\n      case CMD_EVENT_NONE:', 'unified host menu')
    # CMD_EVENT_NONE already has a switch case upstream. Keep the following old
    # menu body unreachable without inventing or duplicating an enum case.
    text = text.replace('      case CMD_EVENT_NONE:\n', '      /* Standalone menu body is unreachable in the embedded frontend. */\n', 1)
    retro.write_text(text)

    mfi = output / 'input/drivers_joypad/mfi_joypad.m'
    text = mfi.read_text()
    text = '#include <stdint.h>\nextern uint32_t NeoRetroArch_FilterButtons(unsigned port, uint32_t buttons);\n' + text
    signature = 'static void apple_gamecontroller_joypad_poll_internal('
    start, end = body_range(text,signature)
    text = text[:end-1] + '\n    *buttons = NeoRetroArch_FilterButtons(slot, *buttons);\n' + text[end-1:]
    text = replace_once(text, '        mfi_controllers[pad] = nil;',
        '        mfi_controllers[pad] = nil;\n        NeoRetroArch_ControllerDisconnected((unsigned)pad);', 'controller chord reset')
    text = 'extern void NeoRetroArch_ControllerDisconnected(unsigned port);\n' + text
    mfi.write_text(text)
    input_cocoa = output / 'input/drivers/cocoa_input.m'
    text = input_cocoa.read_text()
    text = replace_once(text, 'UIWindow *window = [[UIApplication sharedApplication] delegate].window;',
        'UIWindow *window = [(UIView *)[apple_platform renderView] window];', 'scene-local controller orientation')
    input_cocoa.write_text(text)

    overlay = output / 'input/input_driver.c'
    text = overlay.read_text()
    text = 'extern void NeoRetroArch_OverlayFailed(const char *detail);\n' + text
    start, end = body_range(text,'static void input_overlay_loaded(retro_task_t *task,')
    body = text[start:end]
    body = replace_once(body,'   if (err)\n      return;',
        '   if (err)\n   {\n      NeoRetroArch_OverlayFailed(err);\n      return;\n   }','overlay actual failure')
    text = text[:start]+body+text[end:]
    overlay.write_text(text)

    runloop = output / 'runloop.c'
    text = runloop.read_text()
    text = '#include <stdbool.h>\nextern const char *NeoRetroArch_ForcedOption(const char *key);\nextern bool NeoRetroArch_HardwareRenderingAllowed(void);\n' + text
    text = replace_once(text, '            var->value = NULL;\n\n            if (!runloop_st->core_options)',
        '            var->value = NeoRetroArch_ForcedOption(var->key);\n            if (var->value) return true;\n\n            if (!runloop_st->core_options)', 'pre-load forced core profile')
    text = replace_once(text,
        '         RARCH_LOG("[Environ] SET_HW_RENDER, context type: %s.\\n", hw_render_context_name(cb->context_type, cb->version_major, cb->version_minor));',
        '         /* iOS GL2 supports GLES2/GLES3.0, not desktop GL, Vulkan or GLES3.1+. */\n'
        '         if (!NeoRetroArch_HardwareRenderingAllowed()) return false;\n'
        '         if (cb->context_type != RETRO_HW_CONTEXT_OPENGLES2 && cb->context_type != RETRO_HW_CONTEXT_OPENGLES3\n'
        '               && !(cb->context_type == RETRO_HW_CONTEXT_OPENGLES_VERSION && cb->version_major >= 2 && cb->version_major <= 3 && cb->version_minor == 0))\n'
        '            return false;\n'
        '         RARCH_LOG("[Environ] SET_HW_RENDER, context type: %s.\\n", hw_render_context_name(cb->context_type, cb->version_major, cb->version_minor));',
        'supported iOS GPU contexts')
    runloop.write_text(text)

    adapter = output / 'neostation'
    adapter.mkdir()
    for name in ['NeoRetroArchCore.m','NeoRetroArchNoJIT.c','NeoRetroArchStateImport.c','NeoRetroArchStateImport.h']:
        shutil.copy2(ROOT / 'native/retroarch' / name,adapter / name)
    for name in ['NeoRetroArchCoreAPI.h','RetroArchMenuInput.h']:
        shutil.copy2(ROOT / 'packages/retroarch_internal_bridge/ios/Classes' / name,adapter / name)
    (adapter / 'psp').mkdir()
    shutil.copy2(ROOT / 'native/retroarch/psp/NeoPPSSPPProfile.h', adapter / 'psp/NeoPPSSPPProfile.h')
    (adapter / 'exports.txt').write_text('_NeoRetroArch_GetAPI\n')
    (adapter / 'prepared-source.json').write_text(json.dumps({
        'frontendCommit':actual,'adapterAbiVersion':1,'driver':'gl',
        'sourceIpaSha256':PINS['sourceIpa']['sha256'],
        'standaloneApplicationEntry':False,'updaterEnabled':False,'jitEnabled':False,
    },indent=2)+'\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--upstream',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    prepare(args.upstream.resolve(),args.output.resolve())
    print(f'Prepared pinned embedded frontend: {args.output}')

if __name__ == '__main__': main()
