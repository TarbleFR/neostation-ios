#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/neoswap-ipc.XXXXXX")"
trap 'rm -rf "$work"' EXIT
app="$work/NeoSwapIPC.app"
service="$app/Contents/XPCServices/NeoSwapDonor.xpc"
mkdir -p "$app/Contents/MacOS" "$service/Contents/MacOS"
python3 - "$app" "$service" <<'PY'
import pathlib, plistlib, sys
app, service = map(pathlib.Path, sys.argv[1:])
for bundle, payload in [
    (app, {'CFBundleIdentifier':'com.neogamelab.neostation.neoswap-ipc-probe',
           'CFBundleExecutable':'NeoSwapIPC', 'CFBundlePackageType':'APPL',
           'CFBundleVersion':'1', 'CFBundleName':'NeoSwapIPC'}),
    (service, {'CFBundleIdentifier':'com.neogamelab.neostation.neoswap-ipc-probe.donor',
               'CFBundleExecutable':'NeoSwapDonor', 'CFBundlePackageType':'XPC!',
               'CFBundleVersion':'1', 'NeoSwapIPCProbeService':True,
               'XPCService':{'ServiceType':'Application','RunLoopType':'NSRunLoop'}}),
]:
    (bundle/'Contents/Info.plist').write_bytes(plistlib.dumps(payload))
PY
sources=("$root/Broker.cpp" "$root/NeoSwapMachHandle.mm" "$root/NeoSwapDonorIPC.mm"
         "$root/NeoSwapDonorRequestHandler.mm" "$root/ipc_macos_probe.mm")
xcrun clang++ -x objective-c++ -std=c++20 -O1 -g -Wall -Wextra -Werror -fobjc-arc \
  -DNEOSWAP_DONATION_PROBE=1 -mmacosx-version-min=13.0 -framework Foundation -framework Security \
  "${sources[@]}" -o "$app/Contents/MacOS/NeoSwapIPC"
cp "$app/Contents/MacOS/NeoSwapIPC" "$service/Contents/MacOS/NeoSwapDonor"
codesign --force --sign - "$service"
codesign --force --sign - "$app"
"$app/Contents/MacOS/NeoSwapIPC" "$@"
