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
  # enum StikJIT (Swift #56573). Codemagic patches the downloaded source copy,
  # but Xcode also creates an XCFrameworkIntermediates copy; patch both just
  # before this pod compiles so the client never sees the invalid interface.
  s.script_phase = {
    :name => 'Patch StikJIT Swift interfaces',
    :execution_position => :before_compile,
    :script => <<-'SCRIPT'
set -euo pipefail
python3 - <<'PY'
import os
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
seen = set()
for root in root_candidates:
    for interface in root.rglob('*.swiftinterface'):
        if 'StikJIT.swiftmodule' not in str(interface):
            continue
        resolved = str(interface.resolve())
        if resolved in seen:
            continue
        seen.add(resolved)
        interfaces.append(interface)

if not interfaces:
    raise SystemExit('No StikJIT Swift interface found before bridge compilation.')

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

print(
    f'Validated {len(interfaces)} StikJIT interface(s); '
    f'patched {patched_files} during CocoaPods build phase.'
)
PY
SCRIPT
  }
end
