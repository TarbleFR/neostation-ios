#!/usr/bin/env bash
# Verify the production generated-host configurator with the actual xcodeproj
# gem. No application, emulator or JIT core is compiled/replaced by this check.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$PROJECT_DIR"
EVIDENCE_DIR="${1:-$PWD/build/retroarch-host-configuration-checks}"
mkdir -p "$EVIDENCE_DIR"
FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/retroarch-host-config.XXXXXX")"
trap 'rm -rf "$FIXTURE_DIR"' EXIT
ruby -rxcodeproj -e 'puts "ruby=#{RUBY_VERSION}"; puts "xcodeproj=#{Xcodeproj::VERSION}"; puts "gem=#{Gem.loaded_specs.fetch("xcodeproj").full_gem_path}"' \
  | tee "$EVIDENCE_DIR/ruby-toolchain.log"
ruby build-utils/retroarch/ci/host_configuration_fixture.rb create "$FIXTURE_DIR" \
  | tee "$EVIDENCE_DIR/fixture-create.log"
python3 - "$FIXTURE_DIR" <<'PY'
from pathlib import Path
import plistlib,sys
p=Path(sys.argv[1])
info={'CFBundleIdentifier':'com.neogamelab.neostation','CFBundleExecutable':'Runner',
      'MinimumOSVersion':'17.4','CFBundleDisplayName':'Existing NeoStation name',
      'UIBackgroundModes':['audio'],'NSLocalNetworkUsageDescription':'Existing native metadata',
      'CFBundleURLTypes':[{'CFBundleURLSchemes':['neostation']}],
      'UIFileSharingEnabled':False,'LSSupportsOpeningDocumentsInPlace':False}
(p/'Runner'/'Info.plist').write_bytes(plistlib.dumps(info,fmt=plistlib.FMT_XML))
(p/'Runner'/'Runner.entitlements').write_bytes(plistlib.dumps({'get-task-allow':True,'existing.native.entitlement':True}))
(p/'Podfile').write_text("platform :ios, '17.4'\n\n# Existing native targets retained\ntarget 'Runner' do\n  use_frameworks!\nend\ntarget 'OtherEmulator' do\n  use_frameworks!\nend\n")
(p/'info-before.plist').write_bytes((p/'Runner'/'Info.plist').read_bytes())
(p/'entitlements-before.plist').write_bytes((p/'Runner'/'Runner.entitlements').read_bytes())
(p/'podfile-before.txt').write_bytes((p/'Podfile').read_bytes())
PY
python3 build-utils/retroarch/configure_host.py --ios-root "$FIXTURE_DIR" \
  | tee "$EVIDENCE_DIR/configure-first.log"
cp "$FIXTURE_DIR/Runner.xcodeproj/project.pbxproj" "$EVIDENCE_DIR/project-after-first.pbxproj"
cp "$FIXTURE_DIR/Runner/Info.plist" "$EVIDENCE_DIR/info-after-first.plist"
cp "$FIXTURE_DIR/Podfile" "$EVIDENCE_DIR/podfile-after-first.txt"
python3 build-utils/retroarch/configure_host.py --ios-root "$FIXTURE_DIR" \
  | tee "$EVIDENCE_DIR/configure-second.log"
ruby build-utils/retroarch/ci/host_configuration_fixture.rb verify "$FIXTURE_DIR" "$EVIDENCE_DIR/host-configuration.json" \
  | tee "$EVIDENCE_DIR/project-verification.log"
python3 - "$FIXTURE_DIR" "$EVIDENCE_DIR" <<'PY'
from pathlib import Path
import json,plistlib,sys
p,e=map(Path,sys.argv[1:])
expected=plistlib.loads((p/'info-before.plist').read_bytes())
expected.update({'MinimumOSVersion':'18.0','UIFileSharingEnabled':True,'LSSupportsOpeningDocumentsInPlace':True})
assert plistlib.loads((p/'Runner'/'Info.plist').read_bytes())==expected,'Unrelated host plist metadata changed'
assert (p/'Runner'/'Runner.entitlements').read_bytes()==(p/'entitlements-before.plist').read_bytes(),'Existing native signing capabilities changed'
assert (p/'Podfile').read_text()==(p/'podfile-before.txt').read_text().replace("'17.4'","'18.0'",1),'Unrelated Podfile content/target changed'
for actual,evidence in [(p/'Runner.xcodeproj'/'project.pbxproj',e/'project-after-first.pbxproj'),
                        (p/'Runner'/'Info.plist',e/'info-after-first.plist'),
                        (p/'Podfile',e/'podfile-after-first.txt')]:
    assert actual.read_bytes()==evidence.read_bytes(),f'Configurator is not idempotent: {actual.name}'
report=json.loads((e/'host-configuration.json').read_text())
report.update({'documentsShared':True,'documentsEditableInPlace':True,'hostEntitlementsUnchanged':True,
               'unrelatedPlistMetadataUnchanged':True,'unrelatedPodTargetsUnchanged':True,'idempotent':True})
(e/'host-configuration.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
PY
