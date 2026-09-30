#!/usr/bin/env python3
"""Materialize the canonical NeoSwap page-relay host and extension sources."""
from __future__ import annotations

import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
HOST_SOURCES = ('Backend.cpp', 'NeoSwapPageRelay.mm')
EXTENSION_SOURCES = ('NeoSwapPageRelay.mm', 'NeoSwapPageRelayHandler.mm', 'Broker.cpp')
EXTENSION_DEPENDENCIES = ('Broker.cpp', 'Broker.h')
HOST_HEADERS = ('Backend.h', 'NeoSwapPageRelay.h')
EXTENSION_HEADERS = ('NeoSwapPageRelay.h', 'NeoSwapPageRelayHandler.h', 'Broker.h')
HEADERS = tuple(dict.fromkeys(HOST_HEADERS + EXTENSION_HEADERS))
REQUIRED_RELAY_ENTITLEMENTS = {
    'get-task-allow': True,
    'com.apple.developer.kernel.increased-memory-limit': True,
    'com.apple.developer.kernel.increased-debugging-memory-limit': True,
}
RELAY_CONTRACT = {
    'bundleSuffix': '.NeoSwapPageRelay',
    'principalClass': 'NeoSwapPageRelayHandler',
    'marker': 'NeoStationNeoSwapPageRelay',
}
RELAY_BUNDLE = 'NeoSwapPageRelay.appex'
RELAY_CONTRACTS = {RELAY_BUNDLE: RELAY_CONTRACT}


def materialize(root: Path = ROOT) -> None:
    source = root / 'native/neoswap-relay'
    names = set(HOST_SOURCES + EXTENSION_SOURCES + HEADERS +
                ('Info.plist', 'NeoSwapPageRelay.entitlements'))
    for name in sorted(names | set(EXTENSION_DEPENDENCIES)):
        canonical = root / 'native/neoswap-donation' / name if name in EXTENSION_DEPENDENCIES else source / name
        if not canonical.is_file():
            raise SystemExit('Missing canonical page-relay source: ' + str(canonical))
    if not (root / 'packages/neo_swap/ios/Classes/NeoSwapRelay.h').is_file():
        raise SystemExit('Missing canonical public NeoSwapRelay ABI')
    capabilities = plistlib.loads((source / 'NeoSwapPageRelay.entitlements').read_bytes())
    if (set(capabilities) != set(REQUIRED_RELAY_ENTITLEMENTS) or
            any(capabilities[key] is not True for key in REQUIRED_RELAY_ENTITLEMENTS)):
        raise SystemExit('Unexpected page-relay entitlements')
    destinations = (
        (root / 'packages/neo_swap/ios/Classes/Relay', HOST_SOURCES + HOST_HEADERS),
        (root / 'ios/NeoSwapPageRelay', EXTENSION_SOURCES + EXTENSION_HEADERS +
         ('Info.plist', 'NeoSwapPageRelay.entitlements')),
    )
    # Check every destination before replacing any generated source. Unrelated
    # work must survive even if only the second destination is inconsistent.
    for destination, expected in destinations:
        if destination.exists():
            unexpected = {path.name for path in destination.iterdir()} - set(expected)
            if unexpected:
                raise SystemExit(f'Unexpected generated page-relay files in {destination}: {sorted(unexpected)}')
    for destination, expected in destinations:
        destination.mkdir(parents=True, exist_ok=True)
        for name in expected:
            canonical = root / 'native/neoswap-donation' / name if name in EXTENSION_DEPENDENCIES else source / name
            shutil.copy2(canonical, destination / name)


RUBY = r'''
require 'xcodeproj'
require 'json'
project = Xcodeproj::Project.open(ARGV.fetch(0))
contract = JSON.parse(ARGV.fetch(1))
name = 'NeoSwapPageRelay'
product = name + '.appex'
runner = project.targets.find { |target| target.name == 'Runner' }
raise 'Runner target missing' unless runner
def snapshot(target)
  [target.to_hash, target.build_phases.map { |phase| [phase.to_hash, phase.files.map(&:to_hash)] },
   target.build_configurations.map(&:to_hash), target.dependencies.map(&:to_hash)]
end
candidates = project.targets.select { |target| target.name == name || target.product_reference&.path == product }
raise 'Ambiguous page-relay target' if candidates.length > 1
raise 'Unknown page-relay target' if project.targets.any? { |target| target.name.start_with?(name) && target.name != name }
protected = project.targets.reject { |target| target.name == 'Runner' || candidates.include?(target) }
before = protected.to_h { |target| [target.uuid, snapshot(target)] }
runner_phases = runner.build_phases.to_h { |phase| [phase.uuid, phase.to_hash] }
runner_settings = runner.build_configurations.map(&:to_hash)
runner_dependencies = runner.dependencies.map(&:to_hash)
framework_group = project.main_group.groups.find { |group| group.display_name == 'Frameworks' } || project.main_group.new_group('Frameworks')
foundation_path = 'System/Library/Frameworks/Foundation.framework'
foundation = project.files.find { |file| file.path == foundation_path && file.source_tree == 'SDKROOT' } || framework_group.new_file(foundation_path, 'SDKROOT')
embeds = runner.copy_files_build_phases.select { |phase| phase.name == 'Embed App Extensions' }
raise 'Ambiguous app-extension embed phase' if embeds.length > 1
embed = embeds.first
raise 'Wrong app-extension embed destination' if embed && embed.dst_subfolder_spec.to_s != '13'
embed ||= runner.new_copy_files_build_phase('Embed App Extensions')
embed.dst_subfolder_spec = '13'
embedded_before = embed.files.map(&:to_hash)
relay = candidates.first || project.new_target(:app_extension, name, :ios, '18.0')
raise 'Unexpected page-relay product type' unless relay.product_type == 'com.apple.product-type.app-extension'
raise 'Unexpected page-relay product' unless relay.product_reference&.path == product
group = project.main_group.find_subpath(name, true)
group.path = name
group.set_source_tree('<group>')
sources = ['NeoSwapPageRelay.mm', 'NeoSwapPageRelayHandler.mm', 'Broker.cpp']
sources.each do |filename|
  reference = group.files.find { |file| file.path == filename } || group.new_file(filename)
  raise "Unresolved page-relay source: #{filename}" unless File.file?(reference.real_path)
  relay.source_build_phase.add_file_reference(reference, true) unless relay.source_build_phase.files.any? { |file| file.file_ref == reference }
end
raise 'Unrelated source in page-relay target' unless relay.source_build_phase.files.map { |file| file.file_ref.path }.sort == sources.sort
relay.frameworks_build_phase.add_file_reference(foundation, true) unless relay.frameworks_build_phase.files.any? { |file| file.file_ref == foundation }
relay.build_configurations.each do |configuration|
  settings = configuration.build_settings
  settings['APPLICATION_EXTENSION_API_ONLY'] = 'YES'
  settings['CLANG_ENABLE_MODULES'] = 'YES'
  settings['CLANG_ENABLE_OBJC_ARC'] = 'YES'
  settings['CLANG_CXX_LANGUAGE_STANDARD'] = 'c++20'
  settings['GCC_PREPROCESSOR_DEFINITIONS'] = '$(inherited) NEOSWAP_RELAY_EXTENSION=1'
  settings['CODE_SIGN_STYLE'] = 'Automatic'
  settings['CODE_SIGN_ENTITLEMENTS'] = name + '/NeoSwapPageRelay.entitlements'
  settings['CURRENT_PROJECT_VERSION'] = ENV.fetch('BUILD_NUMBER', '372')
  settings['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
  settings['GENERATE_INFOPLIST_FILE'] = 'NO'
  settings['INFOPLIST_FILE'] = name + '/Info.plist'
  settings['IPHONEOS_DEPLOYMENT_TARGET'] = '18.0'
  settings['LD_RUNPATH_SEARCH_PATHS'] = '$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks'
  settings['MARKETING_VERSION'] = '0.0.2'
  host_id = runner.build_configurations.find { |item| item.name == configuration.name }&.build_settings&.fetch('PRODUCT_BUNDLE_IDENTIFIER', nil)
  raise 'Concrete Runner bundle identifier missing' unless host_id.is_a?(String) && !host_id.empty? && !host_id.include?('$(')
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = host_id + contract.fetch('bundleSuffix')
  settings['PRODUCT_NAME'] = '$(TARGET_NAME)'
  settings['SKIP_INSTALL'] = 'YES'
  settings['TARGETED_DEVICE_FAMILY'] = '1,2'
end
runner.add_dependency(relay) unless runner.dependencies.any? { |dependency| dependency.target == relay }
unless embed.files.any? { |file| file.file_ref == relay.product_reference }
  file = embed.add_file_reference(relay.product_reference, true)
  file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
end
raise 'Relay modified unrelated targets' unless before == protected.to_h { |target| [target.uuid, snapshot(target)] }
raise 'Relay modified Runner settings' unless runner_settings == runner.build_configurations.map(&:to_hash)
raise 'Relay removed or modified an existing dependency' unless (runner_dependencies - runner.dependencies.map(&:to_hash)).empty?
raise 'Relay removed or modified an existing embedded product' unless (embedded_before - embed.files.map(&:to_hash)).empty?
runner.build_phases.each do |phase|
  next if phase == embed
  previous = runner_phases[phase.uuid]
  raise "Relay modified Runner phase #{phase.display_name}" if previous && previous != phase.to_hash
end
project.save
reopened = Xcodeproj::Project.open(ARGV.fetch(0))
raise 'Relay target missing or duplicated after save' unless reopened.targets.count { |target| target.name == name } == 1
puts 'NeoSwap page-relay extension saved; existing donor, emulator and JIT targets preserved.'
'''


def configure_project() -> None:
    script = ROOT / 'ios/.configure_neoswap_relay.rb'
    script.write_text(RUBY)
    try:
        environment = dict(os.environ, BUNDLE_GEMFILE=str(ROOT / 'build-utils/Gemfile.dolphin'))
        subprocess.run(['bundle', 'exec', 'ruby', str(script), str(ROOT / 'ios/Runner.xcodeproj'),
                        json.dumps(RELAY_CONTRACT)], cwd=ROOT, env=environment, check=True)
    finally:
        script.unlink(missing_ok=True)


if __name__ == '__main__':
    if not (ROOT / 'ios/Runner.xcodeproj').is_dir():
        raise SystemExit('Generate the Flutter iOS project first')
    materialize()
    configure_project()
