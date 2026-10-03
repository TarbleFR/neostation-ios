#!/usr/bin/env bash
# Apple SDK verification of production host/menu code and isolated UIKit
# lifecycle behavior. The fake backend proves host lifecycle only; it does not
# substitute for the separate real RetroArch frontend/gameplay validation.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$PROJECT_DIR"
EVIDENCE_DIR="${1:-$PWD/build/retroarch-apple-checks}"
mkdir -p "$EVIDENCE_DIR"
git rev-parse HEAD > "$EVIDENCE_DIR/source.txt"
BRIDGE_DIR="$PWD/packages/retroarch_internal_bridge"
PROBE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/retroarch-host-probe.XXXXXX")"
APP_DIR="$PROBE_DIR/Probe.app"
mkdir -p "$APP_DIR/Frameworks" "$APP_DIR/RetroArchResources/overlays"
DEVICE_ID=""
cleanup() {
  if [[ -n "$DEVICE_ID" ]]; then
    xcrun simctl spawn "$DEVICE_ID" log show --last 3m --style compact \
      --predicate 'process == "Probe"' > "$EVIDENCE_DIR/simulator-system.log" 2>&1 || true
    xcrun simctl shutdown "$DEVICE_ID" >/dev/null 2>&1 || true
    xcrun simctl delete "$DEVICE_ID" >/dev/null 2>&1 || true
  fi
  rm -rf "$PROBE_DIR"
}
trap cleanup EXIT
SDK_DIR="$(xcrun --sdk iphonesimulator --show-sdk-path)"
ARCH="$(uname -m)"
# Compile and execute the shared production ABI and menu chord policy.
xcrun clang++ -std=c++20 -Wall -Wextra -Werror \
  "$BRIDGE_DIR/test/runtime_policy_test.cpp" -o "$PROBE_DIR/runtime-policy"
"$PROBE_DIR/runtime-policy" | tee "$EVIDENCE_DIR/runtime-policy.log"
# C input driver consumes the exact same chord helper.
printf '#include "RetroArchMenuInput.h"\nint main(void){NeoRetroArchMenuInputState s={0};uint16_t b=12;return NeoRetroArchMenuInputConsume(&s,&b,1)!=1;}\n' > "$PROBE_DIR/input.c"
xcrun clang -std=c11 -Wall -Wextra -Werror -I"$BRIDGE_DIR/ios/Classes" "$PROBE_DIR/input.c" -o "$PROBE_DIR/input"
"$PROBE_DIR/input"
COMMON=( -target "$ARCH-apple-ios18.0-simulator" -isysroot "$SDK_DIR"
  -std=c++20 -fobjc-arc -fblocks -Wall -Werror -Wno-unused-parameter -Wno-deprecated-declarations )
xcrun clang++ "${COMMON[@]}" -dynamiclib -install_name @rpath/libRetroArchCore.dylib \
  -framework UIKit -framework Foundation "$BRIDGE_DIR/ci/FakeRetroArchCore.mm" \
  -o "$APP_DIR/Frameworks/libRetroArchCore.dylib" 2>&1 | tee "$EVIDENCE_DIR/fake-runtime-build.log"
SOURCE_SHA="$(git rev-parse HEAD)"
xcrun clang++ "${COMMON[@]}" -I"$BRIDGE_DIR/ci" -DPROBE_SOURCE_SHA="\"$SOURCE_SHA\"" \
  -DNEO_RETROARCH_FIRST_FRAME_TIMEOUT=0.3 -DNEO_RETROARCH_STOP_TIMEOUT=0.3 \
  -framework UIKit -framework Foundation -framework GameController -framework UniformTypeIdentifiers -framework QuartzCore \
  "$BRIDGE_DIR/ios/Classes/RetroArchInternalBridgePlugin.mm" \
  "$BRIDGE_DIR/ios/Classes/RetroArchSessionMenu.mm" \
  "$BRIDGE_DIR/ci/HostLifecycleProbe.mm" -o "$APP_DIR/Probe" \
  2>&1 | tee "$EVIDENCE_DIR/production-host-build.log"
python3 - "$APP_DIR" <<'PY'
import json, pathlib, plistlib, shutil, sys
app = pathlib.Path(sys.argv[1])
plistlib.dump({'CFBundleIdentifier':'com.neostation.retroarch.host-probe',
    'CFBundleExecutable':'Probe','CFBundleName':'RetroArch Host Probe',
    'CFBundlePackageType':'APPL','CFBundleVersion':'1','CFBundleShortVersionString':'1.0',
    'LSRequiresIPhoneOS':True,'MinimumOSVersion':'18.0','UIDeviceFamily':[1,2],
    'UIApplicationSceneManifest':{'UIApplicationSupportsMultipleScenes':False,
        'UISceneConfigurations':{'UIWindowSceneSessionRoleApplication':[
            {'UISceneConfigurationName':'Probe','UISceneDelegateClassName':'ProbeSceneDelegate'}]}},
    'UILaunchScreen':{},'UISupportedInterfaceOrientations':['UIInterfaceOrientationPortrait',
    'UIInterfaceOrientationLandscapeLeft','UIInterfaceOrientationLandscapeRight']},open(app/'Info.plist','wb'))
(app/'Frameworks'/'probe.libretro').write_text('test-only controlled backend core entry\n')
(app/'retroarch-core-manifest.json').write_text(json.dumps({'cores':[{'id':'probe',
    'binary':'Frameworks/probe.libretro','systemIds':['nes']}]}))
(app/'RetroArchResources'/'overlays'/'probe.cfg').write_text('bundled overlay\n')
shutil.copyfile('native/retroarch/localizations.json', app/'probe-localizations.json')
PY
codesign --force --sign - "$APP_DIR/Frameworks/libRetroArchCore.dylib"
codesign --force --sign - "$APP_DIR"
xcrun simctl list runtimes --json > "$EVIDENCE_DIR/runtimes.json"
xcrun simctl list devicetypes --json > "$EVIDENCE_DIR/device-types.json"
read -r RUNTIME_ID TYPE_ID < <(python3 - "$EVIDENCE_DIR" <<'PY'
import json, pathlib, sys
p=pathlib.Path(sys.argv[1])
runtimes=[r for r in json.load(open(p/'runtimes.json'))['runtimes'] if r.get('isAvailable') and 'iOS' in r['name'] and tuple(map(int,r['version'].split('.'))) >= (18,0)]
if not runtimes: raise SystemExit('No iOS 18+ simulator runtime installed')
runtime=max(runtimes,key=lambda r:tuple(map(int,r['version'].split('.'))))
devices=json.load(open(p/'device-types.json'))['devicetypes']
type_id=next(d['identifier'] for d in reversed(devices) if d['name'].startswith('iPhone'))
print(runtime['identifier'],type_id)
PY
)
DEVICE_ID="$(xcrun simctl create RetroArchHostProbe "$TYPE_ID" "$RUNTIME_ID")"
xcrun simctl boot "$DEVICE_ID"
xcrun simctl bootstatus "$DEVICE_ID" -b
xcrun simctl install "$DEVICE_ID" "$APP_DIR"
DATA_DIR="$(xcrun simctl get_app_container "$DEVICE_ID" com.neostation.retroarch.host-probe data)"
xcrun simctl launch --console "$DEVICE_ID" com.neostation.retroarch.host-probe > "$EVIDENCE_DIR/probe-console.log" 2>&1 &
for attempt in $(seq 1 60); do
  if [[ -f "$DATA_DIR/Documents/retroarch-host-probe.json" ]]; then break; fi
  sleep 1
done
cp "$DATA_DIR/Documents/retroarch-host-probe.json" "$EVIDENCE_DIR/host-probe.json"
python3 - "$EVIDENCE_DIR/host-probe.json" "$SOURCE_SHA" <<'PY'
import json,sys
report=json.load(open(sys.argv[1]))
assert report['sourceSHA']==sys.argv[2],report
assert report['success'],report
assert report['testRuntimeOnly'] and not report['realRetroArchGameplayValidated'],report
assert report['cycles']==10 and report['starts']==12 and report['stops']==12 and report['endedEvents']==12,report
assert report['firstFrameTimeoutRetainedOwnership'] and report['lateCallbackIgnored'] and report['stopAcknowledgementRequired'],report
print(json.dumps(report,indent=2))
PY
