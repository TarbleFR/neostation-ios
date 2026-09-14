#!/usr/bin/env python3
"""One-time tracked-source integration; never writes to another branch or feature."""
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def replace(text: str, old: str, new: str) -> str:
    if new in text:
        return text
    if text.count(old) != 1:
        raise RuntimeError(f'Unexpected source anchor: {old[:100]!r}')
    return text.replace(old, new, 1)


def main() -> None:
    subprocess.run([sys.executable, str(ROOT / 'build-utils/retire_theme_importer.py')], check=True)
    file = ROOT / 'lib/screens/settings_screen/new_settings_options/themes_settings_content.dart'
    text = file.read_text().replace('Native System Theme + Registered Theme Variants + Custom Background + Import.',
                                   'System theme + built-in variants + custom background + menu music.')
    text = text.replace('    }\n\n  }\n\n  @override\n  Widget build', '    }\n  }\n\n  @override\n  Widget build')
    file.write_text(text)

    file = ROOT / 'build-utils/build_rpcs3_embedded_core.sh'
    text = file.read_text()
    text = replace(text, 'echo "BUILD_NUMBER=264"', 'echo "BUILD_NUMBER=265"')
    text = text.replace('NeoStation-iOS-Build-264-RPCS3-ARM64-LTO', 'NeoStation-iOS-Build-265-RSX-SPU-Video')
    anchor = 'python3 "$PWD/build-utils/patch_rpcs3_build264_gow3_core.py" "$SRC"\n' * 2
    addition = ('python3 "$PWD/build-utils/patch_rpcs3_build265_core.py" "$SRC"\n' * 2 +
                'python3 "$PWD/test/rpcs3_build265_core_test.py" "$SRC"\n')
    if addition not in text:
        text = replace(text, anchor, anchor + addition)
    file.write_text(text)

    file = ROOT / 'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm'
    text = file.read_text()
    text = replace(text, '#import <errno.h>\n', '#import <errno.h>\n#import <string.h>\n')
    text = replace(text, '  if (!bridge || !message || level > 5) return;', '''  if (!bridge || !message) return;
  // NEOSTATION_BUILD265_COREPROF_LOG: retain the sampled profiler summaries
  // without enabling the high-volume debug/trace stream or any Dart events.
  if (level > 5 && strstr(message, "COREPROF ") == nullptr &&
      strstr(message, "COREPROF_RESILIENCE ") == nullptr) return;''')
    file.write_text(text)
    print('Build 265 tracked sources integrated')

if __name__ == '__main__':
    main()
