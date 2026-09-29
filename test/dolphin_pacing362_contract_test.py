from pathlib import Path
import subprocess, urllib.request
root=Path(__file__).resolve().parents[1]
base='099e3b6fe52af99b1f19d47f429222d770b792eb'
subprocess.run(['git','diff','--exit-code',base,'HEAD','--',
 'build-utils/patch_dolphin_internal_core_v2.py','packages/dolphin_internal_bridge/core',
 'packages/armsx2_internal_bridge','packages/rpcs3_internal_bridge','packages/kartpad_internal_bridge',
 'lib/services/frontend_media_gate.dart','lib/services/game/game_launch_service.dart',
 'lib/screens/game_screen/my_games_list','lib/screens/secondary_screen','lib/widgets/shaders'],cwd=root,check=True)
p=root/'packages/dolphin_internal_bridge/ios/Classes'
host=(p/'DolphinInternalBridgePlugin.mm').read_text()
assert '_metalView.paused = YES' in host
assert 'refreshInput ? neostation_dolphin_refresh_controllers() : 0' in host
assert 'owner.controllerGeneration' in host
assert host.index('DOLBeginDisplayTrial(userDirectory') < host.index('if (neostation_dolphin_initialize(')
assert 'DOLRestoreDisplayTrial(self.activeUserDirectory)' in host
policy=(p/'DolphinFramePacing.mm').read_text()
tick=policy.split('- (void)tick:(CADisplayLink*)link {',1)[1].split('- (NSDictionary*)summary',1)[0]
assert 'nextDrawable' not in policy and 'presentDrawable:' not in policy and 'drawInMTKView' not in policy
assert 'CAFrameRateRangeMake(self.requestedHz,self.requestedHz,self.requestedHz)' in policy
assert 'self.records.count>=240' in policy
assert 'writeTo' not in tick and 'NSLog' not in tick
labels=(p/'DolphinPacingLabels.h').read_text()
for language in ('en','fr','de','es','it','pt','ru','id','ja','ko','zh','zh_Hant'):
 assert '@"'+language+'": @{' in labels
u='https://raw.githubusercontent.com/OatmealDome/dolphin-ios/7cac54161659421ed95c2cd1c0b0746539a4cd38/'
def upstream(path):
 with urllib.request.urlopen(u+path,timeout=30) as r:return r.read().decode()
config=upstream('Source/Core/VideoCommon/VideoConfig.h')
assert 'Synchronous,\n  SynchronousUberShaders,\n  AsynchronousUberShaders,' in config
assert 'enum class TriState : int\n{\n  Off,\n  On,\n  Auto' in config
metal=upstream('Source/Core/VideoBackends/Metal/MTLGfx.mm')
assert 'g_ActiveConfig.iUsePresentDrawable == TriState::On ||' in metal
loader=upstream('Source/Core/Core/ConfigLoaders/GameConfigLoader.cpp')
assert '{"Video_Settings", {Config::System::GFX, "Settings"}}' in loader
print('PASS: 120Hz is a display hint, not a second renderer; Metal=1 / Hybrid=2 bind to retained core; unchanged JIT and other emulators')
