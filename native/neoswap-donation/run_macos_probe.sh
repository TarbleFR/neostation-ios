#!/bin/sh
set -eu
if [ "$(uname -s)" != Darwin ]; then
  echo "UNSUPPORTED: real Mach donation probe requires macOS; exit 77 is not a passing test." >&2
  exit 77
fi
task_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
task_output=$(mktemp -d "${TMPDIR:-/tmp}/neoswap-donation.XXXXXX")
trap 'rm -rf -- "$task_output"' EXIT HUP INT TERM
ln -s "$task_dir" "$task_output/Donation"
xcrun --sdk macosx clang++ -std=c++20 -Wall -Wextra -Werror -pthread \
  -DNEOSWAP_DONATION=1 -DNEOSWAP_DONATION_ROUTING_PROBE=1 -DNEOSWAP_TESTING=1 \
  -I "$task_output" -I "$task_dir/../../packages/neo_swap/ios/Classes" \
  "$task_dir/Broker.cpp" "$task_dir/Pool.cpp" "$task_dir/macOS_probe.cpp" \
  "$task_dir/../../packages/neo_swap/ios/Classes/NeoSwap.cpp" \
  -o "$task_output/neoswap-donation-probe"
"$task_output/neoswap-donation-probe"
