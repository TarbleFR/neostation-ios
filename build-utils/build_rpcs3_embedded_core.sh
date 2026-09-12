#!/usr/bin/env bash
set -euo pipefail

# Build XITRIX/rpcs3's iOS RPCS3Core only. The source and mobile dependencies
# are pinned so device regressions can be compared with NeoStation embedded builds.
RPCS3_REPOSITORY="${RPCS3_REPOSITORY:-https://github.com/XITRIX/rpcs3.git}"
RPCS3_COMMIT="${RPCS3_COMMIT:-22f1152783cef1f7e04af7b1c895173e28fd5b03}"
RPCS3_IOS_ABI="${RPCS3_IOS_ABI:-30}"
IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-16.3}"
MOLTENVK_VERSION="${MOLTENVK_VERSION:-1.4.2}"
MOLTENVK_SHA256="${MOLTENVK_SHA256:-b5d947b1660e6e9fed40b9cd2387e160aaab9e80b775c0cef7e14059405178c1}"
FFMPEG_VERSION="${FFMPEG_VERSION:-8.1.1}"
FFMPEG_SHA256="${FFMPEG_SHA256:-b6863adde98898f42602017462871b5f6333e65aec803fdd7a6308639c52edf3}"
WORK_ROOT="${WORK_ROOT:-${RUNNER_TEMP:-/tmp}/neostation-rpcs3-embedded}"
OUTPUT_DIR="${OUTPUT_DIR:-$PWD/build/rpcs3-embedded-core}"
BUILD_JOBS="${BUILD_JOBS:-3}"

SRC="$WORK_ROOT/rpcs3"
BUILD="$WORK_ROOT/build"
DEPS="$WORK_ROOT/deps"
MOLTENVK_EXTRACT="$DEPS/moltenvk-$MOLTENVK_VERSION-ios"
FFMPEG_ROOT="$DEPS/ffmpeg-$FFMPEG_VERSION-ios-arm64"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

for tool in git curl shasum tar cmake ninja ccache brew xcrun lipo otool nm vtool install_name_tool; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool is missing: $tool"
done

HOST_LLVM_ROOT="${HOST_LLVM_ROOT:-$(brew --prefix llvm@22 2>/dev/null || true)}"
[[ -n "$HOST_LLVM_ROOT" && -x "$HOST_LLVM_ROOT/bin/clang" ]] || die "Homebrew llvm@22 is required"
[[ -x "$HOST_LLVM_ROOT/bin/llvm-tblgen" ]] || die "Homebrew llvm@22 does not provide llvm-tblgen"
CC="$HOST_LLVM_ROOT/bin/clang"
CXX="$HOST_LLVM_ROOT/bin/clang++"
LLVM_TABLEGEN_HOST="$HOST_LLVM_ROOT/bin/llvm-tblgen"
SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
AR="$(xcrun --sdk iphoneos --find ar)"
RANLIB="$(xcrun --sdk iphoneos --find ranlib)"
STRIP="$(xcrun --sdk iphoneos --find strip)"
NM="$(xcrun --sdk iphoneos --find nm)"
TARGET="arm64-apple-ios${IOS_DEPLOYMENT_TARGET}"
APPLE_CLANG="$(xcrun --sdk iphoneos --find clang)"
APPLE_CLANG_RESOURCE_DIR="$("$APPLE_CLANG" --print-resource-dir)"
IOS_COMPILER_RT="$APPLE_CLANG_RESOURCE_DIR/lib/darwin/libclang_rt.ios.a"
[[ -s "$IOS_COMPILER_RT" ]] || die "Xcode iOS compiler runtime is missing: $IOS_COMPILER_RT"

mkdir -p "$WORK_ROOT" "$DEPS" "$OUTPUT_DIR"
ccache --max-size=3G >/dev/null

# Keep the bundle/artifact version aligned with this release's workflow.
# These values are consumed by all subsequent workflow steps.
if [[ -n "${GITHUB_ENV:-}" ]]; then
  {
    echo "BUILD_NUMBER=253"
    echo "IPA_NAME=NeoStation-iOS-Build-253"
    echo "ARTIFACT_NAME=NeoStation-iOS-Build-253"
  } >> "$GITHUB_ENV"
fi

log "Provision pinned MoltenVK $MOLTENVK_VERSION for iOS"
MOLTENVK_LIB="$(find "$MOLTENVK_EXTRACT" -type f -path '*/MoltenVK/static/MoltenVK.xcframework/ios-arm64/libMoltenVK.a' -print -quit 2>/dev/null || true)"
if [[ -z "$MOLTENVK_LIB" ]]; then
  rm -rf "$MOLTENVK_EXTRACT"
  mkdir -p "$MOLTENVK_EXTRACT"
  ARCHIVE="$WORK_ROOT/MoltenVK-ios-$MOLTENVK_VERSION.tar"
  curl -fL --retry 4 --retry-delay 2 \
    "https://github.com/KhronosGroup/MoltenVK/releases/download/v${MOLTENVK_VERSION}/MoltenVK-ios.tar" \
    -o "$ARCHIVE"
  printf '%s  %s\n' "$MOLTENVK_SHA256" "$ARCHIVE" | shasum -a 256 -c -
  tar -xf "$ARCHIVE" -C "$MOLTENVK_EXTRACT"
  MOLTENVK_LIB="$(find "$MOLTENVK_EXTRACT" -type f -path '*/MoltenVK/static/MoltenVK.xcframework/ios-arm64/libMoltenVK.a' -print -quit)"
fi
[[ -n "$MOLTENVK_LIB" ]] || die "MoltenVK archive does not contain the ios-arm64 static XCFramework library"
MOLTENVK_SUFFIX='/MoltenVK/static/MoltenVK.xcframework/ios-arm64/libMoltenVK.a'
MOLTENVK_ROOT="${MOLTENVK_LIB%$MOLTENVK_SUFFIX}"
test -f "$MOLTENVK_ROOT/MoltenVK/include/vulkan/vulkan.h" || die "MoltenVK headers are missing beside the resolved package root: $MOLTENVK_ROOT"

log "Build pinned FFmpeg $FFMPEG_VERSION statically for iOS arm64"
if [[ ! -f "$FFMPEG_ROOT/lib/libavcodec.a" || ! -f "$FFMPEG_ROOT/include/libavutil/ffversion.h" ]]; then
  rm -rf "$FFMPEG_ROOT"
  ARCHIVE="$WORK_ROOT/ffmpeg-$FFMPEG_VERSION.tar.xz"
  FFMPEG_SOURCE="$WORK_ROOT/ffmpeg-$FFMPEG_VERSION"
  curl -fL --retry 4 --retry-delay 2 "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz" -o "$ARCHIVE"
  printf '%s  %s\n' "$FFMPEG_SHA256" "$ARCHIVE" | shasum -a 256 -c -
  rm -rf "$FFMPEG_SOURCE"
  tar -xJf "$ARCHIVE" -C "$WORK_ROOT"
  pushd "$FFMPEG_SOURCE" >/dev/null
  ./configure \
    --prefix="$FFMPEG_ROOT" \
    --target-os=darwin --arch=arm64 --enable-cross-compile \
    --cc="$CC" --cxx="$CXX" --ar="$AR" --ranlib="$RANLIB" --strip="$STRIP" --nm="$NM" \
    --sysroot="$SDKROOT" \
    --extra-cflags="-target $TARGET -isysroot $SDKROOT -fPIC" \
    --extra-cxxflags="-target $TARGET -isysroot $SDKROOT -fPIC" \
    --extra-ldflags="-target $TARGET -isysroot $SDKROOT" \
    --disable-shared --enable-static --enable-pic \
    --disable-programs --disable-doc --disable-debug \
    --disable-avdevice --disable-avfilter --disable-network --disable-autodetect
  make -j"$BUILD_JOBS"
  make install
  popd >/dev/null
fi
grep -Eq '^#define FFMPEG_VERSION "8\.1\.1"$' "$FFMPEG_ROOT/include/libavutil/ffversion.h" || die "FFmpeg version check failed"
for lib in avformat avcodec swscale swresample avutil; do
  test -s "$FFMPEG_ROOT/lib/lib${lib}.a" || die "missing FFmpeg library lib${lib}.a"
  lipo -archs "$FFMPEG_ROOT/lib/lib${lib}.a" | grep -qw arm64 || die "FFmpeg lib${lib}.a is not arm64"
done

log "Fetch pinned RPCS3 source for the embedded Core"
rm -rf "$SRC" "$BUILD"
git init -q "$SRC"
git -C "$SRC" remote add origin "$RPCS3_REPOSITORY"
git -C "$SRC" fetch --depth 1 origin "$RPCS3_COMMIT"
git -C "$SRC" checkout -q --detach FETCH_HEAD
test "$(git -C "$SRC" rev-parse HEAD)" = "$RPCS3_COMMIT" || die "RPCS3 commit mismatch"
python3 "$PWD/test/rpcs3_embedded_boot_test.py" "$SRC"
python3 "$PWD/test/rpcs3_jit_memory_test.py" "$SRC"
git -C "$SRC" submodule sync --recursive
git -C "$SRC" -c submodule.fetchJobs=8 submodule update --init --recursive --depth 1

UPSTREAM_ABI="$(sed -nE 's/^#define[[:space:]]+RPCS3_IOS_ABI_VERSION[[:space:]]+([0-9]+)u?.*/\1/p' "$SRC/rpcs3/ios/RPCS3IOS.h" | head -n1)"
[[ "$UPSTREAM_ABI" = "$RPCS3_IOS_ABI" ]] || die "upstream iOS ABI is $UPSTREAM_ABI, expected $RPCS3_IOS_ABI"
grep -q 'add_library(RPCS3Core SHARED' "$SRC/rpcs3/CMakeLists.txt" || die "ios-port no longer defines RPCS3Core as a shared target"

log "Apply NeoStation embedded boot fixes (LLVM/ARM64 remains enabled)"
python3 "$PWD/build-utils/patch_rpcs3_embedded_boot.py" "$SRC"
python3 "$PWD/build-utils/patch_rpcs3_jit_memory.py" "$SRC"
python3 "$PWD/build-utils/patch_rpcs3_neostation_session.py" "$SRC"
python3 "$PWD/build-utils/patch_rpcs3_serial_profiles.py" "$SRC"
python3 "$PWD/build-utils/patch_rpcs3_iso_integrity.py" "$SRC"
python3 "$PWD/test/rpcs3_neostation_session_patch_test.py" "$SRC"
python3 "$PWD/test/rpcs3_serial_profile_patch_test.py" "$SRC"
python3 "$PWD/test/rpcs3_iso_integrity_patch_test.py" "$SRC"

log "Configure RPCS3Core for iPhoneOS arm64 with macOS TableGen"
cmake -S "$SRC" -B "$BUILD" -G Ninja \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_SYSTEM_PROCESSOR=arm64 \
  -DCMAKE_OSX_SYSROOT="$SDKROOT" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET" \
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_COMPILER_TARGET="$TARGET" -DCMAKE_CXX_COMPILER_TARGET="$TARGET" \
  -DCMAKE_CXX_STANDARD_LIBRARIES="$IOS_COMPILER_RT" \
  -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
  -DRPCS3_FRONTEND=IOS \
  -DRPCS3_MOLTENVK_ROOT="$MOLTENVK_ROOT" \
  -DRPCS3_FFMPEG_ROOT="$FFMPEG_ROOT" \
  -DBUILD_LLVM=ON -DWITH_LLVM=ON \
  -DLLVM_NATIVE_TOOL_DIR="$HOST_LLVM_ROOT/bin" \
  -DLLVM_TABLEGEN="$LLVM_TABLEGEN_HOST" \
  -DLLVM_INSTALL_TOOLCHAIN_ONLY=ON \
  -DLLVM_BUILD_TOOLS=OFF -DLLVM_BUILD_UTILS=OFF -DLLVM_INCLUDE_UTILS=OFF \
  -DLLVM_TARGETS_TO_BUILD=AArch64 \
  -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF \
  -DBUILD_RPCS3_TESTS=OFF -DRUN_RPCS3_TESTS=OFF \
  -DUSE_PRECOMPILED_HEADERS=OFF -DUSE_NATIVE_INSTRUCTIONS=OFF \
  -DWITH_DISCORD_RPC=OFF -DWITH_FAUDIO=OFF

log "Compile RPCS3Core only"
cmake --build "$BUILD" --target RPCS3Core --parallel "$BUILD_JOBS"
CORE="$(find "$BUILD" -type f \( -name 'libRPCS3Core.dylib' -o -name 'RPCS3Core.dylib' \) -print -quit)"
[[ -n "$CORE" && -s "$CORE" ]] || { find "$BUILD" -maxdepth 6 -name '*RPCS3Core*' -print >&2 || true; die "libRPCS3Core.dylib was not produced"; }

install_name_tool -id '@rpath/libRPCS3Core.dylib' "$CORE"
cp -f "$CORE" "$OUTPUT_DIR/libRPCS3Core.dylib"
chmod 0755 "$OUTPUT_DIR/libRPCS3Core.dylib"

log "Inspect produced iOS Core"
file "$OUTPUT_DIR/libRPCS3Core.dylib"
lipo -archs "$OUTPUT_DIR/libRPCS3Core.dylib"
vtool -show-build "$OUTPUT_DIR/libRPCS3Core.dylib"
otool -L "$OUTPUT_DIR/libRPCS3Core.dylib"
nm -gU "$OUTPUT_DIR/libRPCS3Core.dylib" | grep -E '_rpcs3_ios_(abi_version|build_info|initialize|boot_game|shutdown)$'
shasum -a 256 "$OUTPUT_DIR/libRPCS3Core.dylib" | tee "$OUTPUT_DIR/libRPCS3Core.dylib.sha256"
printf '%s\n' "$RPCS3_COMMIT" > "$OUTPUT_DIR/RPCS3_SOURCE_COMMIT.txt"
printf '%s\n' "$RPCS3_IOS_ABI" > "$OUTPUT_DIR/RPCS3_IOS_ABI.txt"
log "RPCS3 iOS source Core built successfully"
