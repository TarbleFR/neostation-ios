#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
UPSTREAM=""
IPA=""
OUTPUT="$ROOT/dist/retroarch-embedded"
WORK=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --upstream) UPSTREAM="$2"; shift 2 ;;
    --ipa) IPA="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --work) WORK="$2"; shift 2 ;;
    *) echo "usage: $0 --upstream PATH --ipa PATH [--output PATH] [--work PATH]" >&2; exit 64 ;;
  esac
done
[[ -d "$UPSTREAM" && -f "$IPA" ]] || { echo "Missing upstream source or supplied IPA" >&2; exit 66; }
[[ "$(uname -s)" == Darwin ]] || { echo "Apple iPhoneOS SDK is required to compile the embedded frontend" >&2; exit 69; }
xcrun --sdk iphoneos --show-sdk-path >/dev/null
ruby -e 'require "xcodeproj"' || { echo "The xcodeproj Ruby gem is required" >&2; exit 69; }
if [[ -z "$WORK" ]]; then WORK="$(mktemp -d "${TMPDIR:-/tmp}/neostation-retroarch.XXXXXX")"; fi
mkdir -p "$WORK"
python3 "$ROOT/build-utils/retroarch/package_ipa.py" --ipa "$IPA" --upstream "$UPSTREAM" --output "$OUTPUT"
python3 "$ROOT/build-utils/retroarch/prepare_source.py" --upstream "$UPSTREAM" --output "$WORK/source"
ruby "$ROOT/build-utils/retroarch/configure_project.rb" "$WORK/source"
xcodebuild -project "$WORK/source/pkg/apple/RetroArch_iOS11.xcodeproj" \
  -target RetroArchCore -configuration Release -sdk iphoneos \
  CONFIGURATION_BUILD_DIR="$WORK/products" OBJROOT="$WORK/objects" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  2>&1 | tee "$WORK/frontend-build.log"
BINARY="$WORK/products/libRetroArchCore.dylib"
[[ -f "$BINARY" ]] || { echo "Embedded frontend dylib was not produced" >&2; exit 65; }
[[ "$(lipo -archs "$BINARY")" == arm64 ]] || { echo "Frontend must contain exactly arm64" >&2; exit 65; }
nm -gU "$BINARY" | grep -q ' _NeoRetroArch_GetAPI$' || { echo "Frontend host ABI export missing" >&2; exit 65; }
# No second application entry may survive source adaptation and linking.
if nm -gU "$BINARY" | grep -Eq ' _main$| _UIApplicationMain$'; then
  echo "Standalone app entry unexpectedly present" >&2; exit 65
fi
cp "$BINARY" "$OUTPUT/Frameworks/libRetroArchCore.dylib"
python3 "$ROOT/build-utils/retroarch/validate_backend.py" --package "$OUTPUT" --host-commit "$(git -C "$ROOT" rev-parse HEAD)"
# The exact modified source accompanies the GPL frontend artifact. It can be
# rebuilt without depending on an unrecorded patch or a moving nightly source.
COPYFILE_DISABLE=1 tar -czf "$OUTPUT/retroarch-frontend-corresponding-source.tar.gz" -C "$WORK" source
cp "$WORK/frontend-build.log" "$OUTPUT/frontend-build.log"
cp "$ROOT/build-utils/retroarch/source.json" "$OUTPUT/source-pins.json"
printf 'Embedded RetroArch stage 1 package ready: %s\n' "$OUTPUT"
