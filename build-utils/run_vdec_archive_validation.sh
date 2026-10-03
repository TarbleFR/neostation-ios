#!/usr/bin/env bash
# Real host execution against the SAME FFmpeg release used by the iOS Core.
set -euo pipefail
test "$#" -eq 1
SOURCE_ROOT="$1"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROOF_ROOT="$(mktemp -d "${RUNNER_TEMP:-/tmp}/neoswap-vdec-ffmpeg.XXXXXX")"
PROOF_DIAGNOSTICS="${VDEC_PROOF_DIAGNOSTICS_DIR:-$REPO_ROOT/build/rpcs3-core-diagnostics}"
mkdir -p "$PROOF_DIAGNOSTICS"
save_proof_logs() {
  local proof_status=$?
  local config_log="$PROOF_ROOT/ffmpeg-8.1.1/ffbuild/config.log"
  if test -f "$config_log"; then
    cp "$config_log" "$PROOF_DIAGNOSTICS/vdec-ffmpeg-config.log"
    if test "$proof_status" -ne 0; then tail -n 100 "$config_log"; fi
  fi
  return "$proof_status"
}
trap save_proof_logs EXIT
VERSION=8.1.1
DIGEST=b6863adde98898f42602017462871b5f6333e65aec803fdd7a6308639c52edf3
curl -fL --retry 3 "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz" -o "$PROOF_ROOT/ffmpeg.tar.xz"
printf '%s  %s\n' "$DIGEST" "$PROOF_ROOT/ffmpeg.tar.xz" | shasum -a 256 -c -
tar -xJf "$PROOF_ROOT/ffmpeg.tar.xz" -C "$PROOF_ROOT"
HOST_CXX="${CXX:-$(xcrun --sdk macosx --find clang++)}"
HOST_CC="$(xcrun --sdk macosx --find clang)"
HOST_SDK="$(xcrun --sdk macosx --show-sdk-path)"
(
  cd "$PROOF_ROOT/ffmpeg-$VERSION"
  env -u SDKROOT ./configure --prefix="$PROOF_ROOT/host" --cc="$HOST_CC" --cxx="$HOST_CXX" \
    --host-cc="$HOST_CC" --host-ld="$HOST_CC" \
    --host-cflags="-isysroot $HOST_SDK" --host-ldflags="-isysroot $HOST_SDK" \
    --extra-cflags="-isysroot $HOST_SDK" --extra-cxxflags="-isysroot $HOST_SDK" \
    --extra-ldflags="-isysroot $HOST_SDK" \
    --disable-everything --disable-autodetect --disable-programs --disable-doc --disable-debug \
    --disable-network --disable-avformat --disable-avdevice --disable-avfilter --disable-swresample \
    --disable-x86asm --disable-shared --enable-static --enable-decoder=h264 --enable-parser=h264
  make -j3
  make install
)
env -u SDKROOT CXX="$HOST_CXX" HOST_MACOS_SDK="$HOST_SDK" \
  FFMPEG_TEST_CFLAGS="-I$PROOF_ROOT/host/include" \
  FFMPEG_TEST_LIBS="$PROOF_ROOT/host/lib/libavcodec.a $PROOF_ROOT/host/lib/libswscale.a $PROOF_ROOT/host/lib/libavutil.a -framework VideoToolbox -framework CoreFoundation -framework CoreVideo -framework CoreMedia -framework AudioToolbox" \
  python3 "$REPO_ROOT/test/rpcs3_video_frame_archive_test.py" "$SOURCE_ROOT"
# Keep the bounded temporary dependency/proof available for failure inspection.
