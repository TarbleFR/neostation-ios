#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/neoswap-relay.XXXXXX")"
trap 'rm -rf "$work"' EXIT
app="$work/NeoSwapRelayProbe.app"
service="$app/Contents/XPCServices/NeoSwapPageRelay.xpc"
mkdir -p "$app/Contents/MacOS" "$service/Contents/MacOS"
python3 - "$app" "$service" <<'PY'
import pathlib, plistlib, sys
app, service = map(pathlib.Path, sys.argv[1:])
for bundle, payload in [
    (app, {'CFBundleIdentifier':'com.neogamelab.neostation.relay-probe',
           'CFBundleExecutable':'NeoSwapRelayProbe','CFBundlePackageType':'APPL',
           'CFBundleVersion':'1','CFBundleName':'NeoSwapRelayProbe'}),
    (service, {'CFBundleIdentifier':'com.neogamelab.neostation.relay-probe.NeoSwapPageRelay',
               'CFBundleExecutable':'NeoSwapPageRelay','CFBundlePackageType':'XPC!',
               'CFBundleVersion':'1','NeoSwapRelayProbeService':True,
               'XPCService':{'ServiceType':'Application','RunLoopType':'NSRunLoop'}}),
]:
    (bundle/'Contents/Info.plist').write_bytes(plistlib.dumps(payload))
PY
xcrun clang++ -x objective-c++ -std=c++20 -O1 -g -Wall -Wextra -Werror -fobjc-arc \
  -DNEOSWAP_RELAY_PROBE=1 -mmacosx-version-min=13.0 -framework Foundation -framework Security \
  "$root/../neoswap-donation/Broker.cpp" "$root/Backend.cpp" \
  "$root/NeoSwapPageRelay.mm" "$root/NeoSwapPageRelayHandler.mm" "$root/relay_macos_probe.mm" \
  -o "$app/Contents/MacOS/NeoSwapRelayProbe"
xcrun clang++ -x objective-c++ -std=c++20 -O1 -g -Wall -Wextra -Werror -fobjc-arc \
  -DNEOSWAP_RELAY_PROBE=1 -DNEOSWAP_RELAY_EXTENSION=1 -mmacosx-version-min=13.0 -framework Foundation -framework Security \
  "$root/../neoswap-donation/Broker.cpp" \
  "$root/NeoSwapPageRelay.mm" "$root/NeoSwapPageRelayHandler.mm" "$root/relay_macos_probe.mm" \
  -o "$service/Contents/MacOS/NeoSwapPageRelay"
codesign --force --sign - "$service"
codesign --force --sign - "$app"
"$app/Contents/MacOS/NeoSwapRelayProbe" "$@"
