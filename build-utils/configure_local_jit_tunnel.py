#!/usr/bin/env python3
"""Materialize NeoStation's system-managed, device-local JIT packet tunnel."""
from __future__ import annotations

import os
import plistlib
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / 'ios'
RUNNER = IOS / 'Runner'
TUNNEL = IOS / 'NeoStationLocalTunnel'
NATIVE = ROOT / 'native' / 'local_jit_tunnel'

HOST_ENTITLEMENTS = {
    'com.apple.developer.networking.vpn.api': ['allow-vpn'],
    'com.apple.developer.networking.networkextension': [
        'packet-tunnel-provider',
    ],
}


def write_plist(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(
        plistlib.dumps(payload, fmt=plistlib.FMT_XML, sort_keys=False)
    )


def configure_files() -> None:
    TUNNEL.mkdir(parents=True, exist_ok=True)
    for name in (
        'PacketTunnelProvider.swift',
        'Info.plist',
        'NeoStationLocalTunnel.entitlements',
    ):
        source = NATIVE / name
        if not source.is_file():
            raise SystemExit(f'Missing local tunnel source: {source}')
        shutil.copy2(source, TUNNEL / name)


def configure_host_entitlements() -> None:
    path = RUNNER / 'Runner.entitlements'
    payload = plistlib.loads(path.read_bytes()) if path.is_file() else {}
    if not isinstance(payload, dict):
        raise SystemExit('Existing Runner entitlements are not a dictionary')
    payload.update(HOST_ENTITLEMENTS)
    write_plist(path, payload)


def configure_xcode_project() -> None:
    ruby = r'''
require 'xcodeproj'

project_path = ARGV.fetch(0)
project = Xcodeproj::Project.open(project_path)
runner = project.targets.find { |target| target.name == 'Runner' }
raise 'Runner target not found' unless runner

def target_snapshot(target)
  {
    'target' => target.to_hash,
    'phases' => target.build_phases.map { |phase| [phase.to_hash, phase.files.map(&:to_hash)] },
    'configurations' => target.build_configurations.map(&:to_hash),
    'dependencies' => target.dependencies.map(&:to_hash)
  }
end

owned_names = ['Runner', 'NeoStationLocalTunnel']
protected = project.targets.reject { |target| owned_names.include?(target.name) }
protected_before = protected.to_h { |target| [target.uuid, target_snapshot(target)] }
runner_phase_before = runner.build_phases.to_h { |phase| [phase.uuid, phase.to_hash] }

bundle_id = 'com.neogamelab.neostation.localtunnel'
candidates = project.targets.select do |target|
  target.name == 'NeoStationLocalTunnel' ||
    target.product_reference&.path == 'NeoStationLocalTunnel.appex' ||
    target.build_configurations.any? do |configuration|
      configuration.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] == bundle_id
    end
end
raise "Ambiguous local tunnel identity: #{candidates.map(&:name).inspect}" if candidates.length > 1
tunnel = candidates.first
tunnel ||= project.new_target(:app_extension, 'NeoStationLocalTunnel', :ios, '17.4')
unless tunnel.product_type == 'com.apple.product-type.app-extension' && tunnel.product_reference
  raise 'NeoStationLocalTunnel is not an app extension'
end
unless tunnel.product_reference.path == 'NeoStationLocalTunnel.appex'
  raise "Unexpected local tunnel product #{tunnel.product_reference.path.inspect}"
end

group = project.main_group.find_subpath('NeoStationLocalTunnel', true)
group.set_source_tree('<group>')
group.path = 'NeoStationLocalTunnel'
entry = group.files.find { |file| file.path == 'PacketTunnelProvider.swift' }
entry ||= group.new_file('PacketTunnelProvider.swift')
unless tunnel.source_build_phase.files.any? { |file| file.file_ref == entry }
  tunnel.source_build_phase.add_file_reference(entry, true)
end
raise "Local tunnel source does not resolve: #{entry.real_path}" unless File.file?(entry.real_path)

framework_phases = tunnel.build_phases.select do |phase|
  phase.is_a?(Xcodeproj::Project::Object::PBXFrameworksBuildPhase)
end
raise "Local tunnel has #{framework_phases.length} Frameworks phases" if framework_phases.length > 1
framework_phase = framework_phases.first
unless framework_phase
  framework_phase = project.new(Xcodeproj::Project::Object::PBXFrameworksBuildPhase)
  tunnel.build_phases << framework_phase
end
framework_group = project.main_group.groups.find { |item| item.display_name == 'Frameworks' }
framework_group ||= project.main_group.new_group('Frameworks')
framework_path = 'System/Library/Frameworks/NetworkExtension.framework'
network_extension = project.files.find do |file|
  file.path == framework_path && file.source_tree == 'SDKROOT'
end
network_extension ||= framework_group.new_file(framework_path, 'SDKROOT')
unless framework_phase.files.any? { |file| file.file_ref == network_extension }
  framework_phase.add_file_reference(network_extension, true)
end

tunnel.build_configurations.each do |configuration|
  settings = configuration.build_settings
  settings['APPLICATION_EXTENSION_API_ONLY'] = 'YES'
  settings['CLANG_ENABLE_MODULES'] = 'YES'
  settings['CODE_SIGN_ENTITLEMENTS'] = 'NeoStationLocalTunnel/NeoStationLocalTunnel.entitlements'
  settings['CODE_SIGN_STYLE'] = 'Automatic'
  settings['CURRENT_PROJECT_VERSION'] = ENV.fetch('BUILD_NUMBER', '258')
  settings['DEFINES_MODULE'] = 'YES'
  settings['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
  settings['GENERATE_INFOPLIST_FILE'] = 'NO'
  settings['INFOPLIST_FILE'] = 'NeoStationLocalTunnel/Info.plist'
  settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.4'
  settings['LD_RUNPATH_SEARCH_PATHS'] = '$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks'
  settings['MARKETING_VERSION'] = '1.0.0'
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = bundle_id
  settings['PRODUCT_MODULE_NAME'] = 'NeoStationLocalTunnel'
  settings['PRODUCT_NAME'] = '$(TARGET_NAME)'
  settings['SKIP_INSTALL'] = 'YES'
  settings['SWIFT_VERSION'] = '5.0'
  settings['TARGETED_DEVICE_FAMILY'] = '1,2'
end

runner.build_configurations.each do |configuration|
  configuration.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'Runner/Runner.entitlements'
end
unless runner.dependencies.any? { |dependency| dependency.target == tunnel }
  runner.add_dependency(tunnel)
end
embed = runner.copy_files_build_phases.find { |phase| phase.name == 'Embed App Extensions' }
embed ||= runner.new_copy_files_build_phase('Embed App Extensions')
embed.dst_subfolder_spec = '13'
unless embed.files.any? { |file| file.file_ref == tunnel.product_reference }
  build_file = embed.add_file_reference(tunnel.product_reference, true)
  build_file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
end

protected_after = protected.to_h { |target| [target.uuid, target_snapshot(target)] }
raise 'Local tunnel modified an unrelated Xcode target' unless protected_before == protected_after
runner.build_phases.each do |phase|
  next if phase == embed
  previous = runner_phase_before[phase.uuid]
  raise "Local tunnel modified Runner phase #{phase.display_name}" if previous && previous != phase.to_hash
end

project.save
reopened = Xcodeproj::Project.open(project_path)
unless reopened.targets.count { |target| target.name == 'NeoStationLocalTunnel' } == 1
  raise 'Saved NeoStationLocalTunnel target missing'
end
puts 'local_tunnel.target=NeoStationLocalTunnel'
puts "local_tunnel.bundle=#{bundle_id}"
puts "local_tunnel.protected_targets=#{protected.map(&:name).join(',')}"
puts 'local_tunnel.xcode.save_reopen=passed'
'''
    script = IOS / '.configure_local_jit_tunnel.rb'
    script.write_text(ruby, encoding='utf-8')
    try:
        env = os.environ.copy()
        gemfile = Path(
            env.get(
                'BUNDLE_GEMFILE',
                str(ROOT / 'build-utils/Gemfile.dolphin'),
            )
        )
        if not gemfile.is_file():
            raise SystemExit('Pinned xcodeproj Gemfile is missing')
        env['BUNDLE_GEMFILE'] = str(gemfile)
        subprocess.run(
            [
                'bundle',
                'exec',
                'ruby',
                str(script),
                str(IOS / 'Runner.xcodeproj'),
            ],
            cwd=ROOT,
            check=True,
            env=env,
        )
    finally:
        script.unlink(missing_ok=True)


def main() -> None:
    if not (IOS / 'Runner.xcodeproj').is_dir():
        raise SystemExit('Generate the Flutter iOS host before configuring the tunnel')
    configure_files()
    configure_host_entitlements()
    configure_xcode_project()
    print('Configured NeoStation system-managed local JIT tunnel.')


if __name__ == '__main__':
    main()
