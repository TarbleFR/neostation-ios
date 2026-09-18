#!/usr/bin/env python3
"""Retain sampled core profiles after applying the established host patch stack."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FILE = ROOT / 'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm'
MARKER = 'NEOSTATION_BUILD265_COREPROF_LOG'


def main() -> None:
    text = FILE.read_text()
    if MARKER in text:
        print('Build 265 host diagnostics already applied')
        return
    old = '  if (!bridge || !message || level > 5) return;'
    assert text.count(old) == 1, 'Unexpected RPCS3Log filter'
    text = text.replace(old, '''  if (!bridge || !message) return;
  // NEOSTATION_BUILD265_COREPROF_LOG: retain the sampled profiler summaries
  // without enabling the high-volume debug/trace stream or any Dart events.
  if (level > 5 && strstr(message, "COREPROF ") == nullptr &&
      strstr(message, "COREPROF_RESILIENCE ") == nullptr) return;''', 1)
    if '#import <string.h>' not in text:
        text = '#import <string.h>\n' + text
    FILE.write_text(text)
    print('Build 265 host diagnostics applied')

if __name__ == '__main__':
    main()
