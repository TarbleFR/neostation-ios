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
# Bash 3.2 treats an empty array expansion as unset under nounset. Keep the
# common compiler arguments in this array so the non-Metal path is nonempty.
probe_flags=(-DNEOSWAP_DONATION_PROBE=1 -DNEOSWAP_TESTING=1 -mmacosx-version-min=13.0 -framework Foundation -framework Security)
case "${NEOSWAP_METAL_PROBE:-0}" in
  0) ;;
  1) probe_flags+=(-DNEOSWAP_METAL_PROBE=1 -framework Metal) ;;
  *) echo 'ERROR: NEOSWAP_METAL_PROBE must be 0 or 1' >&2; exit 64 ;;
esac
case "${NEOSWAP_VULKAN_PROBE:-0}" in
  0) ;;
  1)
    : "${NEOSWAP_RPCS3_SOURCE:?Materialized canonical RPCS3 source is required}"
    : "${NEOSWAP_MOLTENVK_ROOT:?Verified MoltenVK package root is required}"
    api="$root/../../packages/neo_swap/ios/Classes"
    library="$NEOSWAP_MOLTENVK_ROOT/dynamic/dylib/macOS"
    test -f "$NEOSWAP_RPCS3_SOURCE/rpcs3/ios/NeoSwapVulkanBuffer.h"
    test -f "$library/libMoltenVK.dylib"
    ln -s "$root" "$work/Donation"
    sources+=("$root/Pool.cpp" "$api/NeoSwap.cpp")
    probe_flags+=(-DNEOSWAP_VULKAN_PROBE=1 -DNEOSWAP_DONATION=1
      -Wno-missing-field-initializers -pthread -I"$api" -I"$work"
      -I"$NEOSWAP_RPCS3_SOURCE" -I"$NEOSWAP_MOLTENVK_ROOT/include"
      -L"$library" -lMoltenVK -Wl,-rpath,"$library")
    ;;
  *) echo 'ERROR: NEOSWAP_VULKAN_PROBE must be 0 or 1' >&2; exit 64 ;;
esac
xcrun clang++ -x objective-c++ -std=c++20 -O1 -g -Wall -Wextra -Werror -fobjc-arc \
  "${probe_flags[@]}" "${sources[@]}" -o "$app/Contents/MacOS/NeoSwapIPC"
cp "$app/Contents/MacOS/NeoSwapIPC" "$service/Contents/MacOS/NeoSwapDonor"
codesign --force --sign - "$service"
codesign --force --sign - "$app"
"$app/Contents/MacOS/NeoSwapIPC" "$@"
