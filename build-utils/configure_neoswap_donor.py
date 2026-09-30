#!/usr/bin/env python3
"""Materialize the canonical donor sources and add only its own iOS target."""
from __future__ import annotations

import os
import plistlib
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'native/neoswap-donation'
HOST_SOURCES = ('Broker.cpp', 'Pool.cpp', 'NeoSwapMachHandle.mm', 'NeoSwapDonorIPC.mm')
DONOR_SOURCES = ('Broker.cpp', 'NeoSwapMachHandle.mm', 'NeoSwapDonorRequestHandler.mm')
HEADERS = ('Broker.h', 'Pool.h', 'NeoSwapMachHandle.h', 'NeoSwapDonorIPC.h', 'NeoSwapDonorRequestHandler.h')
REQUIRED_DONOR_ENTITLEMENTS = {
    'get-task-allow': True,
    'com.apple.developer.kernel.increased-memory-limit': True,
    'com.apple.developer.kernel.increased-debugging-memory-limit': True,
}
DONOR_CONTRACT = {
    'bundleSuffix': '.neoswapdonor',
    'principalClass': 'NeoSwapDonorRequestHandler',
    'marker': 'NeoStationNeoSwapDonor',
}


def materialize(root: Path = ROOT) -> None:
    source = root / 'native/neoswap-donation'
    host = root / 'packages/neo_swap/ios/Classes/Donation'
    helper = root / 'ios/NeoSwapDonor'
    for name in set(HOST_SOURCES + DONOR_SOURCES + HEADERS + ('Info.plist', 'NeoSwapDonor.entitlements')):
        if not (source / name).is_file():
            raise SystemExit('Missing canonical donation source: ' + str(source / name))
    entitlements = plistlib.loads((source / 'NeoSwapDonor.entitlements').read_bytes())
    if set(entitlements) != set(REQUIRED_DONOR_ENTITLEMENTS) or not all(
            entitlements[key] is True for key in REQUIRED_DONOR_ENTITLEMENTS):
        raise SystemExit('Unexpected donation entitlements; no private transfer or app-group capability is authorized')
    # These directories contain generated copies only. Refuse unknown files
    # rather than deleting unrelated work or constructing a second source chain.
    for destination, names in (
        (host, HOST_SOURCES + HEADERS),
        (helper, DONOR_SOURCES + HEADERS + ('Info.plist', 'NeoSwapDonor.entitlements')),
    ):
        destination.mkdir(parents=True, exist_ok=True)
        unexpected = {p.name for p in destination.iterdir()} - set(names)
        if unexpected:
            raise SystemExit(f'Unexpected generated donor files in {destination}: {sorted(unexpected)}')
        for name in names:
            shutil.copy2(source / name, destination / name)


RUBY = r'''
require 'xcodeproj'
project = Xcodeproj::Project.open(ARGV.fetch(0))
runner = project.targets.find { |target| target.name == 'Runner' }
raise 'Runner target missing' unless runner
def snapshot(target)
  [target.to_hash, target.build_phases.map { |phase| [phase.to_hash, phase.files.map(&:to_hash)] },
   target.build_configurations.map(&:to_hash), target.dependencies.map(&:to_hash)]
end
protected = project.targets.reject { |target| ['Runner', 'NeoSwapDonor'].include?(target.name) }
before = protected.to_h { |target| [target.uuid, snapshot(target)] }
runner_phases = runner.build_phases.to_h { |phase| [phase.uuid, phase.to_hash] }
candidates = project.targets.select { |target| target.name == 'NeoSwapDonor' || target.product_reference&.path == 'NeoSwapDonor.appex' }
raise 'Ambiguous donor target' if candidates.length > 1
donor = candidates.first || project.new_target(:app_extension, 'NeoSwapDonor', :ios, '17.4')
raise 'Unexpected donor product type' unless donor.product_type == 'com.apple.product-type.app-extension'
raise 'Unexpected donor product' unless donor.product_reference&.path == 'NeoSwapDonor.appex'
group = project.main_group.find_subpath('NeoSwapDonor', true)
group.path = 'NeoSwapDonor'
group.set_source_tree('<group>')
['Broker.cpp', 'NeoSwapMachHandle.mm', 'NeoSwapDonorRequestHandler.mm'].each do |name|
  ref = group.files.find { |file| file.path == name } || group.new_file(name)
  raise "Unresolved donor source: #{name}" unless File.file?(ref.real_path)
  donor.source_build_phase.add_file_reference(ref, true) unless donor.source_build_phase.files.any? { |file| file.file_ref == ref }
end
expected = ['Broker.cpp', 'NeoSwapMachHandle.mm', 'NeoSwapDonorRequestHandler.mm']
raise 'Unrelated source in donor target' unless donor.source_build_phase.files.map { |file| file.file_ref.path }.sort == expected.sort
framework_group = project.main_group.groups.find { |g| g.display_name == 'Frameworks' } || project.main_group.new_group('Frameworks')
foundation_path = 'System/Library/Frameworks/Foundation.framework'
foundation = project.files.find { |file| file.path == foundation_path && file.source_tree == 'SDKROOT' } || framework_group.new_file(foundation_path, 'SDKROOT')
donor.frameworks_build_phase.add_file_reference(foundation, true) unless donor.frameworks_build_phase.files.any? { |file| file.file_ref == foundation }
donor.build_configurations.each do |configuration|
  s = configuration.build_settings
  s['APPLICATION_EXTENSION_API_ONLY'] = 'YES'
  s['CLANG_ENABLE_MODULES'] = 'YES'
  s['CLANG_ENABLE_OBJC_ARC'] = 'YES'
  s['CLANG_CXX_LANGUAGE_STANDARD'] = 'c++20'
  s['CODE_SIGN_STYLE'] = 'Automatic'
  s['CODE_SIGN_ENTITLEMENTS'] = 'NeoSwapDonor/NeoSwapDonor.entitlements'
  s['CURRENT_PROJECT_VERSION'] = ENV.fetch('BUILD_NUMBER', '368')
  s['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
  s['GENERATE_INFOPLIST_FILE'] = 'NO'
  s['INFOPLIST_FILE'] = 'NeoSwapDonor/Info.plist'
  s['IPHONEOS_DEPLOYMENT_TARGET'] = '17.4'
  s['LD_RUNPATH_SEARCH_PATHS'] = '$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks'
  s['MARKETING_VERSION'] = '0.0.2'
  host_id = runner.build_configurations.find { |c| c.name == configuration.name }&.build_settings&.fetch('PRODUCT_BUNDLE_IDENTIFIER', nil)
  raise 'Concrete Runner bundle identifier missing' unless host_id.is_a?(String) && !host_id.empty? && !host_id.include?('$(')
  s['PRODUCT_BUNDLE_IDENTIFIER'] = host_id + '.neoswapdonor'
  s['PRODUCT_NAME'] = '$(TARGET_NAME)'
  s['SKIP_INSTALL'] = 'YES'
  s['TARGETED_DEVICE_FAMILY'] = '1,2'
end
runner.add_dependency(donor) unless runner.dependencies.any? { |dependency| dependency.target == donor }
embed = runner.copy_files_build_phases.find { |phase| phase.name == 'Embed App Extensions' } || runner.new_copy_files_build_phase('Embed App Extensions')
embed.dst_subfolder_spec = '13'
unless embed.files.any? { |file| file.file_ref == donor.product_reference }
  file = embed.add_file_reference(donor.product_reference, true)
  file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
end
raise 'Donor modified an unrelated target' unless before == protected.to_h { |target| [target.uuid, snapshot(target)] }
runner.build_phases.each do |phase|
  next if phase == embed
  previous = runner_phases[phase.uuid]
  raise "Donor modified Runner phase #{phase.display_name}" if previous && previous != phase.to_hash
end
project.save
reopened = Xcodeproj::Project.open(ARGV.fetch(0))
raise 'Donor target missing after save' unless reopened.targets.count { |target| target.name == 'NeoSwapDonor' } == 1
puts 'NeoSwap donor target saved; all existing emulator and JIT targets preserved.'
'''


def configure_project() -> None:
    script = ROOT / 'ios/.configure_neoswap_donor.rb'
    script.write_text(RUBY)
    try:
        env = os.environ.copy()
        env['BUNDLE_GEMFILE'] = str(ROOT / 'build-utils/Gemfile.dolphin')
        subprocess.run(['bundle', 'exec', 'ruby', str(script), str(ROOT / 'ios/Runner.xcodeproj')], cwd=ROOT, env=env, check=True)
    finally:
        script.unlink(missing_ok=True)


if __name__ == '__main__':
    if not (ROOT / 'ios/Runner.xcodeproj').is_dir():
        raise SystemExit('Generate the Flutter iOS project first')
    materialize()
    configure_project()
