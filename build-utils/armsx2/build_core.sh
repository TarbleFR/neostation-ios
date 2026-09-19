#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SOURCE="${1:?Expected upstream checkout}"
SOURCE="$(cd "$SOURCE" && pwd)"
BUILD="$ROOT/build/armsx2-core"
REVISION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["revision"])' "$ROOT/build-utils/armsx2/source.json")"
mkdir -p "$BUILD" "$ROOT/dist/armsx2"
python3 "$ROOT/build-utils/armsx2/prepare_source.py" "$SOURCE"
cmake -S "$SOURCE/platforms/ios/app/src/main/cpp" -B "$BUILD" -G Xcode \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DARMSX2_REAL_DEVICE=ON -DLTO_PCSX2_CORE=OFF \
  -DNEO_ARMSX2_ADAPTER_DIR="$ROOT/packages/armsx2_internal_bridge" \
  -DNEO_ARMSX2_SOURCE_REVISION="$REVISION" \
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO \
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO \
  2>&1 | tee "$BUILD/configure.log"
cmake --build "$BUILD" --config Release --target ARMSX2Core -- \
  -sdk iphoneos -jobs 4 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  COMPILER_INDEX_STORE_ENABLE=NO \
  2>&1 | tee "$BUILD/compile.log"
python3 "$ROOT/build-utils/armsx2/verify_core.py" "$BUILD" "$ROOT/dist/armsx2"
