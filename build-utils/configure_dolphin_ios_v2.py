#!/usr/bin/env python3
"""Idempotent configuration of the generated iOS host and Dolphin-only helper."""
from __future__ import annotations

import os
import plistlib
import re
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / 'ios'
RUNNER = IOS / 'Runner'
HELPER = IOS / 'DolphinJITHelper'


def write_plist(path: Path, payload: dict) -> None:
    path.write_bytes(plistlib.dumps(payload, fmt=plistlib.FMT_XML, sort_keys=False))


def configure_info_plist() -> None:
    path = RUNNER / 'Info.plist'
    payload = plistlib.loads(path.read_bytes())
    payload['UIFileSharingEnabled'] = True
    payload['LSSupportsOpeningDocumentsInPlace'] = True
    # Match the established landscape host configuration. No audio, controller
    # or emulator-specific settings are changed here.
    orientations = ['UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight']
    payload['UISupportedInterfaceOrientations'] = orientations
    payload['UISupportedInterfaceOrientations~ipad'] = orientations
    retired = {'dolphin', 'dolphinios', 'dolphin-emu'}
    schemes = payload.get('LSApplicationQueriesSchemes', [])
    if not isinstance(schemes, list):
        raise SystemExit('Invalid existing LSApplicationQueriesSchemes; refusing to overwrite it')
    schemes = [value for value in schemes if not isinstance(value, str) or value.lower() not in retired]
    for required in ('retroarch', 'shortcuts', 'armsx2', 'melonx'):
        if required not in schemes:
            schemes.append(required)
    payload['LSApplicationQueriesSchemes'] = schemes
    types = payload.get('CFBundleURLTypes', [])
    if not isinstance(types, list):
        raise SystemExit('Invalid existing CFBundleURLTypes; refusing to overwrite it')
    for entry in types:
        if isinstance(entry, dict) and isinstance(entry.get('CFBundleURLSchemes'), list):
            entry['CFBundleURLSchemes'] = [value for value in entry['CFBundleURLSchemes']
                if not isinstance(value, str) or value.lower() not in retired]
    if not any(isinstance(entry, dict) and 'neostation' in entry.get('CFBundleURLSchemes', []) for entry in types):
        types.append({'CFBundleURLName': 'com.neogamelab.neostation', 'CFBundleURLSchemes': ['neostation']})
    payload['CFBundleURLTypes'] = types
    write_plist(path, payload)


def configure_entitlements() -> None:
    path = RUNNER / 'Runner.entitlements'
    # Never replace an existing malformed entitlement document with an empty
    # dictionary: that would silently remove capabilities of other engines.
    payload = plistlib.loads(path.read_bytes()) if path.is_file() else {}
    if not isinstance(payload, dict):
        raise SystemExit('Existing Runner entitlements are not a dictionary')
    payload['get-task-allow'] = True
    write_plist(path, payload)


def configure_helper_files() -> None:
    HELPER.mkdir(parents=True, exist_ok=True)
    for name in ('DolphinJITExtensionEntry.swift', 'Info.plist'):
        shutil.copy2(ROOT / 'native/dolphin_internal_helper' / name, HELPER / name)


def configure_podfile() -> None:
    path = IOS / 'Podfile'
    text = path.read_text(encoding='utf-8')
    text = re.sub(r"^\s*#?\s*platform\s+:ios,\s*'[^']+'\s*$", "platform :ios, '17.4'", text, count=1, flags=re.MULTILINE)
    block = """
# NeoStation-owned helper used only for Dolphin's legacy BRK #0x69 handshake.
target 'DolphinJITHelper' do
  use_frameworks!
  use_modular_headers!
  pod 'dolphin_jit_helper', :path => '../packages/dolphin_jit_helper/ios'
end

"""
    if "target 'DolphinJITHelper' do" not in text:
        anchor = 'post_install do |installer|'
        text = text.replace(anchor, block + anchor, 1) if anchor in text else text + '\n' + block
    else:
        # Only repair the dedicated helper stanza; never change Runner or the
        # linkage mode used by another existing emulator target.
        pattern = r"(?ms)^target 'DolphinJITHelper' do\n.*?^end$"
        matches = list(re.finditer(pattern, text))
        if len(matches) != 1:
            raise SystemExit('Expected exactly one DolphinJITHelper Podfile stanza')
        current = matches[0].group(0)
        if 'use_frameworks!' not in current:
            repaired = current.replace("target 'DolphinJITHelper' do\n", "target 'DolphinJITHelper' do\n  use_frameworks!\n", 1)
            text = text[:matches[0].start()] + repaired + text[matches[0].end():]
    path.write_text(text, encoding='utf-8')


def configure_xcode_project() -> None:
    ruby = r'''
require 'xcodeproj'
require 'json'

project_path = ARGV.fetch(0)
project = Xcodeproj::Project.open(project_path)
runner = project.targets.find { |target| target.name == 'Runner' }
raise 'Runner target not found' unless runner

# Capture all unrelated targets, including their configurations, phases and
# dependency graphs. Dolphin is not permitted to edit these existing targets.
def target_snapshot(target)
  {
    'target' => target.to_hash,
    'phases' => target.build_phases.map { |phase| [phase.to_hash, phase.files.map(&:to_hash)] },
    'configurations' => target.build_configurations.map(&:to_hash),
    'dependencies' => target.dependencies.map(&:to_hash)
  }
end
protected = project.targets.reject { |target| ['Runner', 'DolphinJITHelper'].include?(target.name) }
protected_before = protected.to_h { |target| [target.uuid, target_snapshot(target)] }
runner_phase_before = runner.build_phases.to_h { |phase| [phase.uuid, phase.to_hash] }

candidates = project.targets.select do |target|
  target.name == 'DolphinJITHelper' || target.product_reference&.path == 'DolphinJITHelper.appex' ||
    target.build_configurations.any? { |c| c.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] == 'com.neogamelab.neostation.dolphinjithelper' }
end
if candidates.length > 1
  raise "Ambiguous helper identity: #{candidates.map { |t| [t.name, t.product_type, t.product_reference&.path] }.inspect}"
end
helper = candidates.first
if helper && helper.name != 'DolphinJITHelper'
  raise "Helper product belongs to unexpected target #{helper.name}; refusing a duplicate target"
end
# Initial scaffolding has no helper. Repeated configuration must find exactly
# this target; an existing mismatched identity is never silently replaced.
helper ||= project.new_target(:app_extension, 'DolphinJITHelper', :ios, '17.4')
expected_type = 'com.apple.product-type.app-extension'
unless helper.product_type == expected_type && helper.product_reference
  raise "Expected DolphinJITHelper app-extension; targets=#{project.targets.map { |t| [t.name, t.product_type] }.inspect}"
end
unless helper.product_reference.path == 'DolphinJITHelper.appex'
  raise "Unexpected helper product #{helper.product_reference.path.inspect}"
end
helper.build_configurations.each do |configuration|
  existing = configuration.build_settings['PRODUCT_BUNDLE_IDENTIFIER']
  if existing && existing != 'com.neogamelab.neostation.dolphinjithelper'
    raise "Unexpected helper bundle identifier #{existing.inspect}"
  end
end

phases = helper.build_phases.select { |phase| phase.is_a?(Xcodeproj::Project::Object::PBXFrameworksBuildPhase) }
raise "Helper has #{phases.length} Frameworks phases" if phases.length > 1
phase = phases.first
unless phase
  phase = project.new(Xcodeproj::Project::Object::PBXFrameworksBuildPhase)
  helper.build_phases << phase
end
references = phase.files.map(&:file_ref).compact
raise 'Duplicate framework references in helper' unless references.map(&:uuid).uniq.length == references.length

puts "xcodeproj.version=#{Xcodeproj::VERSION}"
puts "xcodeproj.path=#{Gem.loaded_specs.fetch('xcodeproj').full_gem_path}"
puts "helper.class=#{helper.class.name}"
puts "helper.name=#{helper.name}"
puts "helper.product_type=#{helper.product_type}"
puts "helper.product_reference=#{helper.product_reference.path}"
puts "helper.build_phases=#{helper.build_phases.map { |item| item.class.name }.join(',')}"
puts "helper.respond_to.frameworks_build_phase=#{helper.respond_to?(:frameworks_build_phase)}"
puts "helper.respond_to.frameworks_build_phases=#{helper.respond_to?(:frameworks_build_phases)}"
puts "helper.framework_phase=#{phase.uuid}"
puts "helper.stikjit.direct_references=#{references.count { |ref| ref.path.to_s.end_with?('StikJIT.framework') }}"
puts 'helper.stikjit.linkage=CocoaPods dolphin_jit_helper dependency; verified after pod install and in Mach-O'

helper_group = project.main_group.find_subpath('DolphinJITHelper', true)
helper_group.set_source_tree('<group>')
helper_group.path = 'DolphinJITHelper'
entry = helper_group.files.find { |file| file.path == 'DolphinJITExtensionEntry.swift' }
entry ||= helper_group.new_file('DolphinJITExtensionEntry.swift')
unless helper.source_build_phase.files.any? { |file| file.file_ref == entry }
  helper.source_build_phase.add_file_reference(entry, true)
end
raise "Helper source does not resolve: #{entry.real_path}" unless File.file?(entry.real_path)

helper.build_configurations.each do |configuration|
  settings = configuration.build_settings
  settings['APPLICATION_EXTENSION_API_ONLY'] = 'NO'
  settings['CLANG_ENABLE_MODULES'] = 'YES'
  settings['CODE_SIGN_STYLE'] = 'Automatic'
  settings['CURRENT_PROJECT_VERSION'] = ENV.fetch('BUILD_NUMBER', '194')
  settings['DEFINES_MODULE'] = 'YES'
  settings['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
  settings['GENERATE_INFOPLIST_FILE'] = 'NO'
  settings['INFOPLIST_FILE'] = 'DolphinJITHelper/Info.plist'
  settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.4'
  settings['LD_RUNPATH_SEARCH_PATHS'] = '$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks'
  settings['MARKETING_VERSION'] = '1.0.0'
  settings['OTHER_LDFLAGS'] = '$(inherited) -ObjC -all_load'
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.neogamelab.neostation.dolphinjithelper'
  settings['PRODUCT_MODULE_NAME'] = 'DolphinJITHelper'
  settings['PRODUCT_NAME'] = '$(TARGET_NAME)'
  settings['SKIP_INSTALL'] = 'YES'
  settings['SWIFT_VERSION'] = '5.0'
  settings['TARGETED_DEVICE_FAMILY'] = '1,2'
end
runner.build_configurations.each do |configuration|
  settings = configuration.build_settings
  settings['CODE_SIGN_ENTITLEMENTS'] = 'Runner/Runner.entitlements'
  settings['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
  settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.4'
end
unless runner.dependencies.any? { |dependency| dependency.target == helper }
  runner.add_dependency(helper)
end
embed = runner.copy_files_build_phases.find { |item| item.name == 'Embed App Extensions' }
embed ||= runner.new_copy_files_build_phase('Embed App Extensions')
embed.dst_subfolder_spec = '13'
unless embed.files.any? { |file| file.file_ref == helper.product_reference }
  embed.add_file_reference(helper.product_reference, true)
end
runner_group = project.main_group.find_subpath('Runner', false)
raise 'Runner group not found' unless runner_group
sys_ref = runner_group.files.find { |file| file.path == 'Sys' }
sys_ref ||= runner_group.new_file('Sys')
sys_ref.last_known_file_type = 'folder'
unless runner.resources_build_phase.files.any? { |file| file.file_ref == sys_ref }
  runner.resources_build_phase.add_file_reference(sys_ref, true)
end

protected_after = protected.to_h { |target| [target.uuid, target_snapshot(target)] }
raise 'Dolphin modified an unrelated Xcode target' unless protected_before == protected_after
runner.build_phases.each do |item|
  next if item == embed || item == runner.resources_build_phase
  old = runner_phase_before[item.uuid]
  raise "Dolphin modified Runner phase #{item.display_name}" if old && old != item.to_hash
end
project.save
reopened = Xcodeproj::Project.open(project_path)
raise 'Saved helper target missing' unless reopened.targets.count { |t| t.name == 'DolphinJITHelper' } == 1
puts "xcodeproj.unrelated_targets_preserved=#{protected.map(&:name).join(',')}"
puts 'xcodeproj.save_reopen=passed'
'''
    script = IOS / '.configure_dolphin_helper.rb'
    script.write_text(ruby, encoding='utf-8')
    try:
        env = os.environ.copy()
        gemfile = Path(env.get('BUNDLE_GEMFILE', str(ROOT / 'build-utils/Gemfile.dolphin')))
        if not gemfile.is_file():
            raise SystemExit('Pinned Dolphin Gemfile is missing')
        env['BUNDLE_GEMFILE'] = str(gemfile)
        subprocess.run(['bundle', 'exec', 'ruby', str(script), str(IOS / 'Runner.xcodeproj')], cwd=ROOT, check=True, env=env)
    finally:
        script.unlink(missing_ok=True)


def main() -> None:
    if not (IOS / 'Runner.xcodeproj').is_dir():
        raise SystemExit('Generate the clean Flutter iOS host first')
    if not (RUNNER / 'Sys').is_dir():
        raise SystemExit('Dolphin Data/Sys must be copied to ios/Runner/Sys first')
    framework = ROOT / 'packages/dolphin_jit_helper/ios/Frameworks/StikJIT.xcframework/ios-arm64/StikJIT.framework/StikJIT'
    if not framework.is_file():
        raise SystemExit(f'StikJIT device framework missing: {framework}')
    configure_helper_files()
    configure_info_plist()
    configure_entitlements()
    configure_podfile()
    configure_xcode_project()
    print('Configured Runner, DolphinJITHelper and root Sys resources.')


if __name__ == '__main__':
    main()
