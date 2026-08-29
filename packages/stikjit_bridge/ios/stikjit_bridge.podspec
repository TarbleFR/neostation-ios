Pod::Spec.new do |s|
  s.name             = 'stikjit_bridge'
  s.version          = '0.0.1'
  s.summary          = 'Experimental NeoStation bridge for StikJIT.'
  s.description      = <<-DESC
Experimental iOS-only bridge allowing NeoStation to prepare StikJIT and enable JIT for MeloNX without routing through the StikDebug application.
                       DESC
  s.homepage         = 'https://github.com/TarbleFR/neostation-ios'
  s.license          = { :type => 'GPL-3.0' }
  s.author           = { 'NeoStation iOS' => 'TarbleFR' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.vendored_frameworks = 'Frameworks/StikJIT.xcframework'
  s.dependency 'Flutter'
  s.platform = :ios, '17.4'
  s.ios.deployment_target = '17.4'
  s.swift_version = '5.0'
  s.frameworks = 'JavaScriptCore', 'Network', 'Security', 'CFNetwork', 'SystemConfiguration', 'IOKit'
  s.libraries = 'z', 'bz2', 'iconv', 'compression'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES'
  }

  # StikJIT 1.5.0 was distributed with BUILD_LIBRARY_FOR_DISTRIBUTION=YES
  # while its module and its main public enum share the name `StikJIT`.
  # Swift can therefore resolve module-qualified top-level types as members of
  # enum StikJIT (Swift #56573). The released iOS framework also lacks the
  # framework-level Info.plist required by installd. Patch both issues in every
  # source/intermediate/product copy before the bridge compiles.
  s.script_phase = {
    :name => 'Prepare StikJIT framework',
    :execution_position => :before_compile,
    :script => <<-'SCRIPT'
set -euo pipefail
python3 - <<'PY'
import os
import plistlib
from pathlib import Path

root_candidates = []
for key in (
    'PODS_TARGET_SRCROOT',
    'PODS_XCFRAMEWORKS_BUILD_DIR',
    'CONFIGURATION_BUILD_DIR',
    'BUILD_DIR',
):
    value = os.environ.get(key, '')
    if value:
        path = Path(value)
        if path.exists():
            root_candidates.append(path)

interfaces = []
frameworks = []
seen_interfaces = set()
seen_frameworks = set()

for root in root_candidates:
    for interface in root.rglob('*.swiftinterface'):
        if 'StikJIT.swiftmodule' not in str(interface):
            continue
        resolved = str(interface.resolve())
        if resolved in seen_interfaces:
            continue
        seen_interfaces.add(resolved)
        interfaces.append(interface)

    for framework in root.rglob('StikJIT.framework'):
        if not framework.is_dir() or not (framework / 'StikJIT').is_file():
            continue
        resolved = str(framework.resolve())
        if resolved in seen_frameworks:
            continue
        seen_frameworks.add(resolved)
        frameworks.append(framework)

if not interfaces:
    raise SystemExit('No StikJIT Swift interface found before bridge compilation.')
if not frameworks:
    raise SystemExit('No StikJIT.framework bundle found before bridge compilation.')

top_level_types = (
    'DDIPaths',
    'DeveloperDiskImageService',
    'StikJITError',
)

patched_files = 0
for interface in interfaces:
    text = interface.read_text(encoding='utf-8')
    patched = text
    for type_name in top_level_types:
        patched = patched.replace(f'StikJIT.{type_name}', type_name)
    # Nested public types belong to enum StikJIT; only remove the module prefix.
    patched = patched.replace('StikJIT.StikJIT.', 'StikJIT.')

    if patched != text:
        interface.write_text(patched, encoding='utf-8')
        patched_files += 1
        print(f'Patched Swift #56573 interface: {interface}')

invalid = []
for interface in interfaces:
    text = interface.read_text(encoding='utf-8')
    bad_refs = [
        ref
        for ref in (
            *(f'StikJIT.{name}' for name in top_level_types),
            'StikJIT.StikJIT.',
        )
        if ref in text
    ]
    if bad_refs:
        invalid.append(f'{interface}: {", ".join(bad_refs)}')

if invalid:
    raise SystemExit(
        'Invalid StikJIT module-qualified references remain: ' + '; '.join(invalid)
    )

required_plist = {
    'CFBundleDevelopmentRegion': 'en',
    'CFBundleExecutable': 'StikJIT',
    'CFBundleIdentifier': 'com.stik.StikJIT',
    'CFBundleInfoDictionaryVersion': '6.0',
    'CFBundleName': 'StikJIT',
    'CFBundlePackageType': 'FMWK',
    'CFBundleShortVersionString': '1.5.0',
    'CFBundleVersion': '1',
    'CFBundleSupportedPlatforms': ['iPhoneOS'],
    'MinimumOSVersion': '17.4',
    'UIDeviceFamily': [1, 2],
}

plist_updates = 0
for framework in frameworks:
    info = framework / 'Info.plist'
    payload = {}
    if info.is_file():
        try:
            with info.open('rb') as handle:
                payload = plistlib.load(handle)
        except Exception:
            payload = {}

    changed = False
    for key, value in required_plist.items():
        if payload.get(key) != value:
            payload[key] = value
            changed = True

    if changed or not info.is_file():
        with info.open('wb') as handle:
            plistlib.dump(payload, handle, fmt=plistlib.FMT_XML, sort_keys=False)
        plist_updates += 1
        print(f'Created/updated framework Info.plist: {info}')

    with info.open('rb') as handle:
        verified = plistlib.load(handle)
    for key, value in required_plist.items():
        if verified.get(key) != value:
            raise SystemExit(f'Invalid StikJIT Info.plist {info}: {key}')

print(
    f'Validated {len(interfaces)} StikJIT interface(s); '
    f'patched {patched_files} interface file(s); '
    f'validated {len(frameworks)} framework bundle(s); '
    f'updated {plist_updates} Info.plist file(s).'
)
PY
SCRIPT
  }
end
