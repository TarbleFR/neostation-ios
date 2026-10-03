#!/usr/bin/env bash
# Apple SDK verification of production host/menu code and isolated UIKit
# lifecycle behavior. The fake backend proves host lifecycle only; it does not
# substitute for the separate real RetroArch frontend/gameplay validation.
set -Eeuo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$PROJECT_DIR"
EVIDENCE_DIR="${1:-$PWD/build/retroarch-apple-checks}"
mkdir -p "$EVIDENCE_DIR"
# Never accept evidence left by a previous invocation or interrupted run.
rm -f "$EVIDENCE_DIR/host-probe.json" "$EVIDENCE_DIR/host-checks-complete.json" "$EVIDENCE_DIR/host-checks-failed.json"
git rev-parse HEAD > "$EVIDENCE_DIR/source.txt"
BRIDGE_DIR="$PWD/packages/retroarch_internal_bridge"
PROBE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/retroarch-host-probe.XXXXXX")"
APP_DIR="$PROBE_DIR/Probe.app"
mkdir -p "$APP_DIR/Frameworks" "$APP_DIR/RetroArchResources/overlays"
DEVICE_ID=""
LAUNCH_PID=""
cleanup() {
  local original_status=$?
  if [[ -n "$DEVICE_ID" ]]; then
    xcrun simctl spawn "$DEVICE_ID" log show --last 3m --style compact \
      --predicate 'process == "Probe"' > "$EVIDENCE_DIR/simulator-system.log" 2>&1 || true
    xcrun simctl shutdown "$DEVICE_ID" >/dev/null 2>&1 || true
    xcrun simctl delete "$DEVICE_ID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$LAUNCH_PID" ]] && kill -0 "$LAUNCH_PID" 2>/dev/null; then
    kill "$LAUNCH_PID" >/dev/null 2>&1 || true
    wait "$LAUNCH_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$PROBE_DIR"
  return "$original_status"
}
trap cleanup EXIT
fail() {
  local original_status=$?
  trap - ERR
  printf '{"success":false,"exitStatus":%s,"line":%s}\n' "$original_status" "${BASH_LINENO[0]}" > "$EVIDENCE_DIR/host-checks-failed.json"
  exit "$original_status"
}
trap fail ERR
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
xcrun simctl list devices available --json > "$EVIDENCE_DIR/available-devices.json"
# macOS /bin/bash 3.2 can misparse a heredoc nested in process substitution,
# then exit zero before running the simulator. Keep Python synchronous and
# persist the selection before a separate, status-checked read.
python3 - "$EVIDENCE_DIR" <<'PY'
import json, pathlib, sys
p=pathlib.Path(sys.argv[1])
runtimes={r['identifier']:r for r in json.load(open(p/'runtimes.json'))['runtimes']
          if r.get('isAvailable') and 'iOS' in r['name'] and tuple(map(int,r['version'].split('.'))) >= (18,0)}
types=json.load(open(p/'device-types.json'))['devicetypes']
by_name={d['name']:d['identifier'] for d in types}
pairs=[]
for runtime_id, devices in json.load(open(p/'available-devices.json'))['devices'].items():
    if runtime_id not in runtimes:
        continue
    version=tuple(map(int,runtimes[runtime_id]['version'].split('.')))
    for device in devices:
        if not device.get('isAvailable') or not device['name'].startswith('iPhone'):
            continue
        type_id=device.get('deviceTypeIdentifier') or by_name.get(device['name'])
        if type_id:
            # Copy a pair CoreSimulator already considers compatible. Choosing
            # the newest device type independently can pair an iPhone 17 with
            # iOS 18.5 and fail before any host test executes.
            priority=(version[:2] == (18,5), version[0] == 18,
                      device['name'].startswith('iPhone 16'), version, device['name'])
            pairs.append((priority,runtime_id,type_id,device['name']))
if not pairs:
    raise SystemExit('No compatible available iPhone/iOS 18+ simulator pair installed')
_,runtime_id,type_id,name=max(pairs)
(p/'selected-device.json').write_text(json.dumps({'runtime':runtime_id,'deviceType':type_id,'name':name},indent=2)+'\n')
(p/'selected-device.ids').write_text(runtime_id+' '+type_id+'\n')
print(runtime_id,type_id)
PY
read -r RUNTIME_ID TYPE_ID < "$EVIDENCE_DIR/selected-device.ids"
[[ -n "$RUNTIME_ID" && -n "$TYPE_ID" ]]
DEVICE_ID="$(xcrun simctl create RetroArchHostProbe "$TYPE_ID" "$RUNTIME_ID")"
xcrun simctl boot "$DEVICE_ID"
xcrun simctl bootstatus "$DEVICE_ID" -b
xcrun simctl install "$DEVICE_ID" "$APP_DIR"
DATA_DIR="$(xcrun simctl get_app_container "$DEVICE_ID" com.neostation.retroarch.host-probe data)"
xcrun simctl launch --console "$DEVICE_ID" com.neostation.retroarch.host-probe > "$EVIDENCE_DIR/probe-console.log" 2>&1 &
LAUNCH_PID=$!
for attempt in $(seq 1 60); do
  if [[ -f "$DATA_DIR/Documents/retroarch-host-probe.json" ]]; then break; fi
  if ! kill -0 "$LAUNCH_PID" 2>/dev/null; then
    if wait "$LAUNCH_PID"; then
      echo 'Simulator console exited before the lifecycle report was produced.' >&2
      exit 1
    else
      launch_status=$?
      echo "Simulator launch failed with status $launch_status." >&2
      exit "$launch_status"
    fi
  fi
  sleep 1
done
if [[ ! -s "$DATA_DIR/Documents/retroarch-host-probe.json" ]]; then
  echo 'Simulator lifecycle probe timed out without a report.' >&2
  exit 1
fi
cp "$DATA_DIR/Documents/retroarch-host-probe.json" "$EVIDENCE_DIR/host-probe.json"
python3 "$BRIDGE_DIR/ci/verify_apple_evidence.py" "$EVIDENCE_DIR" "$SOURCE_SHA" --write-completion
exit 0
