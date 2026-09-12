#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).resolve().parents[1]
plugin = (
    root / 'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm'
).read_text()
importer = (root / 'lib/services/rpcs3_content_import_service.dart').read_text()

# The menu must expose actual RPCS3 per-game resolution scale values and apply
# them through the Core before rebooting the current title.
for token in [
    'NeoStation Build 251 resolution scale menu',
    'showResolutionScaleMenu',
    'applyResolutionScale:',
    '"gpu.resolution_scale"',
    '_api.set_game_setting',
    '_api.stop_emulation',
    '_api.boot_game',
    '@"Upscale"',
    '@"75"',
    '@"100"',
    '@"125"',
    '@"150"',
    '@"175"',
    '@"200"',
    '@"250"',
    '@"300"',
]:
    assert token in plugin, token

# A structurally truncated ISO is rejected by the embedded Core. Build 251 must
# then release the security scope and immediately ask for a replacement image.
for token in [
    '_isIncompleteIsoFailure',
    "message.contains('truncated or corrupt')",
    "message.contains('incomplete or corrupt')",
    "message.contains('requires iso bytes through')",
    "message.contains('re-import this title from a complete iso')",
    'while (true)',
    'pickGameFilesOpenInPlace()',
    'releaseScopedResources()',
    'pendingIncompleteErrors = incompleteErrors',
    'Duration(milliseconds: 250)',
]:
    assert token in importer, token

print('RPCS3 Build 251 upscale/import contract: OK')
