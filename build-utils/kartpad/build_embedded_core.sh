#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
PINS="$ROOT/build-utils/kartpad/source.json"

usage() {
  echo "usage: $0 --upstream PATH --translation PATH --dawn ARCHIVE --discio-source PATH --discio-build PATH [--output PATH]" >&2
  exit 64
}

UPSTREAM=""
TRANSLATION=""
DAWN=""
DISCIO_SOURCE=""
DISCIO_BUILD=""
OUTPUT="$ROOT/dist/kartpad-native"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --upstream) UPSTREAM="$2"; shift 2 ;;
    --translation) TRANSLATION="$2"; shift 2 ;;
    --dawn) DAWN="$2"; shift 2 ;;
    --discio-source) DISCIO_SOURCE="$2"; shift 2 ;;
    --discio-build) DISCIO_BUILD="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$UPSTREAM" && -n "$TRANSLATION" && -n "$DAWN" &&
   -n "$DISCIO_SOURCE" && -n "$DISCIO_BUILD" ]] || usage

for p in "$UPSTREAM" "$TRANSLATION" "$DISCIO_SOURCE" "$DISCIO_BUILD"; do
  [[ -d "$p" ]] || { echo "ERROR: missing directory: $p" >&2; exit 66; }
done
[[ -f "$DAWN" ]] || { echo "ERROR: missing Dawn archive: $DAWN" >&2; exit 66; }
[[ -f "$TRANSLATION/build_shards/shards.cmake" ]] || {
  echo "ERROR: missing authorized RMCP01 translation graph" >&2
  exit 66
}

eval "$(python3 - "$PINS" <<'PY'
import json, shlex, sys
p=json.load(open(sys.argv[1]))
values={
  "UPSTREAM_SHA":p["releaseTagCommit"],
  "RUNTIME_SHA":p["iosRuntimeCommit"],
  "EXPECTED_FUNCTIONS":str(p["discProfile"]["expectedTranslatedFunctions"]),
  "ABI_VERSION":str(p["neoStationAbi"]),
  "RUNTIME_IDENTITY":p["runtimeIdentity"],
}
for key,value in values.items():
    print(f"{key}={shlex.quote(value)}")
PY
)"

actual_upstream="$(git -C "$UPSTREAM" rev-parse HEAD)"
[[ "$actual_upstream" == "$UPSTREAM_SHA" ]] || {
  echo "ERROR: KartPad source mismatch: $actual_upstream" >&2
  exit 65
}
actual_runtime="$(git -C "$UPSTREAM/vendor/runtimes/ios" rev-parse HEAD)"
[[ "$actual_runtime" == "$RUNTIME_SHA" ]] || {
  echo "ERROR: KartPad iOS runtime mismatch: $actual_runtime" >&2
  exit 65
}

actual_functions="$(find "$TRANSLATION/functions" -maxdepth 1 -type f -name 'func_*.cpp' | wc -l | tr -d ' ')"
[[ "$actual_functions" == "$EXPECTED_FUNCTIONS" ]] || {
  echo "ERROR: translated function count $actual_functions != $EXPECTED_FUNCTIONS" >&2
  exit 65
}

[[ -f "$DISCIO_SOURCE/Source/Core/DiscIO/DiscExtractor.h" ]] || {
  echo "ERROR: physical-iOS DiscIO source is incomplete" >&2
  exit 66
}
[[ -f "$DISCIO_BUILD/Source/Core/DiscIO/libdiscio.a" ]] || {
  echo "ERROR: physical-iOS DiscIO build is incomplete" >&2
  exit 66
}

WORK="$ROOT/build/kartpad-embedded"
RUNTIME_SOURCE="$WORK/runtime-source"
XCODE_BUILD="$WORK/xcode"
rm -rf "$WORK" "$OUTPUT"
mkdir -p "$WORK" "$OUTPUT"

python3 "$UPSTREAM/scripts/stage-maintained-runtime.py" ios "$RUNTIME_SOURCE"
python3 "$ROOT/build-utils/kartpad/prepare_embedded_source.py"   "$RUNTIME_SOURCE" "$UPSTREAM" "$ROOT/native/kartpad/core/NeoKartPadCore.mm"

cmake -S "$RUNTIME_SOURCE" -B "$XCODE_BUILD" -G Xcode   -DCMAKE_BUILD_TYPE=Release   -DCMAKE_CONFIGURATION_TYPES=Release   -DCMAKE_SYSTEM_NAME=iOS   -DCMAKE_SYSTEM_PROCESSOR=arm64   -DCMAKE_OSX_SYSROOT=iphoneos   -DCMAKE_OSX_ARCHITECTURES=arm64   -DCMAKE_OSX_DEPLOYMENT_TARGET=17.4   -DMKW_AURORA_DIR="$RUNTIME_SOURCE/aurora-main"   -DAURORA_DAWN_PACKAGE_URL="file://$DAWN"   -DMKW_TRANSLATED_SHARD_MANIFEST="$TRANSLATION/build_shards/shards.cmake"   -DMKW_KARTPAD_RUNTIME_INCLUDE="$UPSTREAM/runtime/include"   -DMKW_KARTPAD_REPO_ROOT="$UPSTREAM"   -DMKW_KARTPAD_DISCIO_SOURCE_DIR="$DISCIO_SOURCE"   -DMKW_KARTPAD_DISCIO_BUILD_DIR="$DISCIO_BUILD"   -DMKW_TRANSLATED_COMPILE_JOBS=2   -DMKW_NEOSTATION_EMBEDDED_CORE=ON   -DMKW_NEOSTATION_CORE_SOURCE="$ROOT/native/kartpad/core/NeoKartPadCore.mm"

cmake --build "$XCODE_BUILD" --config Release --target WiiCompiled --   -sdk iphoneos CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO

FRAMEWORK="$(find "$XCODE_BUILD" -type d -name KartPadCore.framework -path '*Release*' | head -n 1)"
[[ -n "$FRAMEWORK" && -f "$FRAMEWORK/KartPadCore" ]] || {
  echo "ERROR: KartPadCore.framework was not produced" >&2
  exit 65
}

BINARY="$FRAMEWORK/KartPadCore"
[[ "$(lipo -archs "$BINARY")" == "arm64" ]] || {
  echo "ERROR: KartPadCore must contain exactly arm64" >&2
  exit 65
}
xcrun vtool -show-build "$BINARY" | grep -q 'platform IOS' || {
  echo "ERROR: KartPadCore is not an iphoneos binary" >&2
  exit 65
}
nm -gU "$BINARY" | grep -q ' _NeoKartPad_GetAPI$' || {
  echo "ERROR: KartPadCore does not export NeoKartPad_GetAPI" >&2
  exit 65
}
if otool -L "$BINARY" | grep -Eq '/opt/homebrew|/usr/local'; then
  echo "ERROR: KartPadCore contains a host-only dependency" >&2
  exit 65
fi

ditto "$FRAMEWORK" "$OUTPUT/KartPadCore.framework"
CORE_SHA="$(shasum -a 256 "$OUTPUT/KartPadCore.framework/KartPadCore" | awk '{print $1}')"
SHARDS_SHA="$(shasum -a 256 "$TRANSLATION/build_shards/shards.cmake" | awk '{print $1}')"
HOST_SHA="$(git -C "$ROOT" rev-parse HEAD)"

python3 - "$OUTPUT/identity.json" <<PY
import json, pathlib, sys
out = pathlib.Path(sys.argv[1])
data = {
  "schemaVersion": 1,
  "host_commit": "$HOST_SHA",
  "upstream_commit": "$UPSTREAM_SHA",
  "ios_runtime_commit": "$RUNTIME_SHA",
  "disc_profile": "mkwii-rmcp01-rev0",
  "translated_function_count": int("$actual_functions"),
  "translation_manifest_sha256": "$SHARDS_SHA",
  "abi_version": int("$ABI_VERSION"),
  "runtime_identity": "$RUNTIME_IDENTITY",
  "architectures": ["arm64"],
  "sha256": "$CORE_SHA",
}
out.write_text(json.dumps(data, indent=2) + "\n")
PY

python3 "$ROOT/build-utils/kartpad/validate_embedded_core.py"   "$OUTPUT/KartPadCore.framework" "$OUTPUT/identity.json"

echo "KartPadCore.framework ready: $OUTPUT"
