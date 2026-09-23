#!/usr/bin/env python3
"""Keep Dolphin's Gecko/WiiRD HTTPS trust resource in every build path."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
workflow = (ROOT / '.github/workflows/dolphin-core.yml').read_text()
ios_workflow = (ROOT / '.github/workflows/ios-ci.yml').read_text()
configurator = (ROOT / 'build-utils/configure_dolphin_ios_v2.py').read_text()
builder = (ROOT / 'packages/dolphin_internal_bridge/ci/build_support.py').read_text()
validator = (ROOT / 'packages/dolphin_internal_bridge/ci/verify_ipa.py').read_text()

assert 'Source/iOS/App/Project/Assets/cacert.pem' in workflow
assert 'dist/dolphin/cacert.pem' in workflow
assert 'dist/dolphin-native/cacert.pem' in ios_workflow
assert 'ios/Runner/cacert.pem' in ios_workflow
assert "runner_group.new_file('cacert.pem')" in configurator
assert "ROOT / 'ios/Runner/cacert.pem'" in builder
assert "app + '/cacert.pem'" in validator
assert "b'BEGIN CERTIFICATE'" in validator

print('PASS: Dolphin HTTPS CA bundle is materialized, embedded and IPA-validated')
