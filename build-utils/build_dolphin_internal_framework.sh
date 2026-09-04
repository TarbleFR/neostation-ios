#!/bin/bash
set -euo pipefail

PINNED_DOLPHIN_SHA="7cac54161659421ed95c2cd1c0b0746539a4cd38"
WORK_ROOT="${1:-${RUNNER_TEMP:-/tmp}/neostation-dolphin-internal}"
SRC="$WORK_ROOT/source"
BUILD="$WORK_ROOT/build"
FRAMEWORK="$GITHUB_WORKSPACE/packages/dolphin_internal_bridge/ios/Frameworks/DolphinCore.framework"
LOG_DIR="$GITHUB_WORKSPACE/build/dolphin-internal"
LOG_FILE="$LOG_DIR/dolphin-core-build.log"

mkdir -p "$WORK_ROOT" "$LOG_DIR"
rm -rf "$SRC" "$BUILD" "$FRAMEWORK"
mkdir -p "$SRC" "$BUILD" "$(dirname "$FRAMEWORK")"

{
  echo "Pinned Dolphin revision: $PINNED_DOLPHIN_SHA"
  git -C "$SRC" init
  git -C "$SRC" remote add origin https://github.com/OatmealDome/dolphin-ios.git
  git -C "$SRC" fetch --depth 1 origin "$PINNED_DOLPHIN_SHA"
  git -C "$SRC" checkout --detach FETCH_HEAD
  git -C "$SRC" submodule update --init --recursive --depth 1

  python3 "$GITHUB_WORKSPACE/build-utils/patch_dolphin_internal_core.py" "$SRC"
  python3 "$GITHUB_WORKSPACE/build-utils/refine_dolphin_internal_core_v2.py" "$SRC"

  cmake -S "$SRC" -B "$BUILD" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$SRC/Externals/ios-cmake/ios.toolchain.cmake" \
    -DPLATFORM=OS64 \
    -DDEPLOYMENT_TARGET=17.4 \
    -DENABLE_VISIBILITY=ON \
    -DENABLE_BITCODE=OFF \
    -DENABLE_ARC=ON \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_FLAGS="-fPIC" \
    -DIOS=ON \
    -DENABLE_ANALYTICS=NO \
    -DUSE_SYSTEM_LIBS=OFF \
    -DENABLE_TESTS=OFF \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5

  cmake --build "$BUILD" --target dolphin --parallel 3

  DYLIB="$(find "$BUILD" -type f -name 'libdolphin.dylib' -print -quit)"
  test -n "$DYLIB"
  test -s "$DYLIB"

  mkdir -p "$FRAMEWORK"
  cp "$DYLIB" "$FRAMEWORK/DolphinCore"
  chmod 755 "$FRAMEWORK/DolphinCore"
  install_name_tool -id '@rpath/DolphinCore.framework/DolphinCore' "$FRAMEWORK/DolphinCore"

  cat > "$FRAMEWORK/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>DolphinCore</string>
  <key>CFBundleIdentifier</key><string>com.neogamelab.neostation.DolphinCore</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>DolphinCore</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
  <key>MinimumOSVersion</key><string>17.4</string>
  <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
</dict></plist>
PLIST

  plutil -lint "$FRAMEWORK/Info.plist"
  lipo -info "$FRAMEWORK/DolphinCore"
  file "$FRAMEWORK/DolphinCore"
  test "$(stat -f%z "$FRAMEWORK/DolphinCore")" -gt 5000000

  for symbol in \
    _neostation_dolphin_bridge_version \
    _neostation_dolphin_initialize \
    _neostation_dolphin_validate_image \
    _neostation_dolphin_prepare_legacy_jit \
    _neostation_dolphin_launch \
    _neostation_dolphin_is_running \
    _neostation_dolphin_set_paused \
    _neostation_dolphin_stop; do
    nm -gU "$FRAMEWORK/DolphinCore" | grep -q " $symbol$"
  done

  otool -L "$FRAMEWORK/DolphinCore"
  nm -gU "$FRAMEWORK/DolphinCore" | grep -q _neostation_dolphin_prepare_legacy_jit

  rm -rf "$LOG_DIR/Sys"
  test -d "$SRC/Data/Sys"
  ditto "$SRC/Data/Sys" "$LOG_DIR/Sys"
  test -f "$LOG_DIR/Sys/GC/dsp_rom.bin"
  echo "$PINNED_DOLPHIN_SHA" > "$LOG_DIR/dolphin-revision.txt"
  echo "DolphinCore framework built and symbol-validated."
} 2>&1 | tee "$LOG_FILE"
