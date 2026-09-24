#!/usr/bin/env python3
"""Exercise production audio suspension and reusable host-frame ownership."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
audio = (ROOT / 'native/dusklight/upstream/src/dusk/audio/DuskAudioSystem.cpp').read_text()
start = audio.index('extern "C" void NeoDusklight_SetAudioSuspended')
end = audio.index('\n}\n', start) + 3
production = audio[start:end]
prefix = r'''
#include <cassert>
using SDL_AudioStream = int;
static SDL_AudioStream device = 1;
static SDL_AudioStream* PlaybackStream = nullptr;
static bool HostAudioSuspended = false, HostHadAudio = false;
static int opens = 0, closes = 0, pauses = 0, resumes = 0;
void SDL_PauseAudioStreamDevice(SDL_AudioStream* value) { assert(value); ++pauses; }
void SDL_ResumeAudioStreamDevice(SDL_AudioStream* value) { assert(value); ++resumes; }
bool InitSDL3Output() { assert(!PlaybackStream); PlaybackStream = &device; ++opens; return true; }
namespace dusk::audio {
void Shutdown() { assert(PlaybackStream); PlaybackStream = nullptr; ++closes; }
}
'''
test = r'''
int main() {
  // Backgrounding before audio initialization must not create a second DSP.
  NeoDusklight_SetAudioSuspended(1);
  NeoDusklight_SetAudioSuspended(0);
  assert(opens == 0 && closes == 0);
  InitSDL3Output();
  for (int session = 0; session < 100; ++session) {
    NeoDusklight_SetAudioSuspended(1);
    assert(!PlaybackStream); // NeoStation/another core owns the audio device.
    int previousCloses = closes;
    NeoDusklight_SetAudioSuspended(1);
    assert(closes == previousCloses);
    NeoDusklight_SetAudioSuspended(0);
    assert(PlaybackStream);
    int previousOpens = opens;
    NeoDusklight_SetAudioSuspended(0);
    assert(opens == previousOpens);
  }
  assert(opens == 101 && closes == 100 && pauses == 100 && resumes == 100);
}
'''
with tempfile.TemporaryDirectory() as directory:
    cpp = Path(directory) / 'audio.cpp'
    binary = Path(directory) / 'audio-test'
    cpp.write_text(prefix + production + test)
    subprocess.run(['c++', '-std=c++20', '-Wall', '-Wextra', '-Werror', str(cpp), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=10)

core = (ROOT / 'native/dusklight/core/NeoDusklightCore.mm').read_text()
game = (ROOT / 'native/dusklight/upstream/src/m_Do/m_Do_main.cpp').read_text()
window = (ROOT / 'native/dusklight/upstream/extern/aurora/lib/window.cpp').read_text()
adapter = (ROOT / 'native/dusklight/core/NeoDusklightGame.cpp').read_text()
assert 'SDL_SetiOSEventPump(false)' in core
assert 'if (inNativeCall) return;' in core
assert 'if (!NEO_DUSKLIGHT_EMBEDDED && is_paused())' in window
assert 'NeoDusklight_RuntimeReady();' in game
assert 'enableTouchControls.setValue(true)' in game
assert game.index('load_from_user_preferences()') < game.index('NeoDusklight_ShouldEnableTouch()')
assert 'NeoDusklightTouchDefaultV1' in core
assert 'NeoDusklight_OpenMenu();' in core and 'menu->show();' in adapter
assert 'PauseReason::Host' in adapter
assert 'touch->hide(false)' in adapter
start_body = core[core.index('int Start('):core.index('int IsRunning()')]
assert 'session.entered()' not in start_body
assert 'candidate.st_ino != discIdentity.st_ino' in start_body
assert 'Resuming the retained native runtime.' in start_body
assert 'UIApplicationWillResignActiveNotification' in core
assert 'SDL_HideWindow(sdlWindow)' in core and 'connectedScenes' not in core
finish = core[core.index('void FinishReturn()'):core.index('void TerminalShutdown(')]
assert 'NeoDusklight_ReleaseFrameResources()' in finish
assert 'NeoDusklight_ShutdownRuntime()' not in finish
terminal = core[core.index('void TerminalShutdown('):core.index('void Stop()')]
assert 'NeoDusklight_ShutdownRuntime()' in terminal
assert 'session.terminate()' in terminal
display = (ROOT / 'native/dusklight/upstream/libs/JSystem/src/JFramework/JFWDisplay.cpp').read_text()
tick = display[display.index('static void waitForTick(u32 p1, u16 p2) {'):]
assert tick.index('NEO_DUSKLIGHT_EMBEDDED') < tick.index('return;') < tick.index('static Limiter')
print('PASS: production audio suspension supports warm resume while fatal failures retain terminal teardown')
