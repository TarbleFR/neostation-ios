#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SOURCE="${1:?Expected upstream checkout}"
SOURCE="$(cd "$SOURCE" && pwd)"
BUILD="$ROOT/build/armsx2-core"
REVISION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["revision"])' "$ROOT/build-utils/armsx2/source.json")"
mkdir -p "$BUILD" "$ROOT/dist/armsx2"
python3 "$ROOT/build-utils/armsx2/prepare_source.py" "$SOURCE"

# Make the native artifact independent from GitHub runner/workspace paths.
# These flags cover normal debug/source records and __FILE__-style macro paths
# across the upstream C/C++/Objective-C/Objective-C++ objects linked into Core.
PREFIX_MAP_FLAGS="-ffile-prefix-map=$ROOT=/neostation -fdebug-prefix-map=$ROOT=/neostation -fmacro-prefix-map=$ROOT=/neostation -ffile-prefix-map=$SOURCE=/armsx2 -fdebug-prefix-map=$SOURCE=/armsx2 -fmacro-prefix-map=$SOURCE=/armsx2 -ffile-prefix-map=$BUILD=/build -fdebug-prefix-map=$BUILD=/build -fmacro-prefix-map=$BUILD=/build"

cmake -S "$SOURCE/platforms/ios/app/src/main/cpp" -B "$BUILD" -G Xcode \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_C_FLAGS="$PREFIX_MAP_FLAGS" \
  -DCMAKE_CXX_FLAGS="$PREFIX_MAP_FLAGS" \
  -DCMAKE_OBJC_FLAGS="$PREFIX_MAP_FLAGS" \
  -DCMAKE_OBJCXX_FLAGS="$PREFIX_MAP_FLAGS" \
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
