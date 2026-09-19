#!/usr/bin/env python3
"""Configure the generated iOS host for NeoStation's embedded ARMSX2 engine.

This script owns only ARMSX2-specific host capabilities and the ARMSX2JITHelper
extension. It deliberately does not edit Dolphin source, targets, or settings.
"""
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
HELPER = IOS / 'ARMSX2JITHelper'


def write_plist(path: Path, payload: dict) -> None:
    path.write_bytes(plistlib.dumps(payload, fmt=plistlib.FMT_XML, sort_keys=False))


def configure_entitlements() -> None:
    """Mirror the memory/JIT capabilities present in the verified ARMSX2 IPA."""
    path = RUNNER / 'Runner.entitlements'
    payload = plistlib.loads(path.read_bytes()) if path.is_file() else {}
    if not isinstance(payload, dict):
        raise SystemExit('Existing Runner entitlements are not a dictionary')
    payload['get-task-allow'] = True
    payload['com.apple.developer.kernel.extended-virtual-addressing'] = True
    payload['com.apple.developer.kernel.increased-memory-limit'] = True
    payload['com.apple.developer.kernel.increased-debugging-memory-limit'] = True
    write_plist(path, payload)


def configure_helper_files() -> None:
    source = ROOT / 'native' / 'armsx2_internal_helper'
    HELPER.mkdir(parents=True, exist_ok=True)
    for name in ('Armsx2JITExtensionEntry.swift', 'Info.plist'):
        candidate = source / name
        if not candidate.is_file():
            raise SystemExit(f'Missing ARMSX2 helper source: {candidate}')
        shutil.copy2(candidate, HELPER / name)


def configure_podfile() -> None:
    path = IOS / 'Podfile'
    if not path.is_file():
        raise SystemExit('Flutter Podfile is missing')
    text = path.read_text(encoding='utf-8')
    block = """
# NeoStation-owned helper used only by the embedded ARMSX2 engine.
target 'ARMSX2JITHelper' do
  use_frameworks!
  use_modular_headers!
  pod 'armsx2_jit_helper', :path => '../packages/armsx2_jit_helper/ios'
end

"""
    if "target 'ARMSX2JITHelper' do" not in text:
        anchor = 'post_install do |installer|'
        text = text.replace(anchor, block + anchor, 1) if anchor in text else text + '\n' + block
    else:
        pattern = r"(?ms)^target 'ARMSX2JITHelper' do\n.*?^end$"
        matches = list(re.finditer(pattern, text))
        if len(matches) != 1:
            raise SystemExit('Expected exactly one ARMSX2JITHelper Podfile stanza')
        text = text[:matches[0].start()] + block.strip() + text[matches[0].end():]
    path.write_text(text, encoding='utf-8')


def configure_xcode_project() -> None:
    ruby = r'''
require 'xcodeproj'
require 'json'

project_path = ARGV.fetch(0)
project = Xcodeproj::Project.open(project_path)
runner = project.targets.find { |target| target.name == 'Runner' }
raise 'Runner target not found' unless runner

# ARMSX2 may create/update only its own helper target and Runner's app-extension
# dependency/embed references. Existing emulator targets are immutable here.
def target_snapshot(target)
  {
    'target' => target.to_hash,
    'phases' => target.build_phases.map { |phase| [phase.to_hash, phase.files.map(&:to_hash)] },
    'configurations' => target.build_configurations.map(&:to_hash),
    'dependencies' => target.dependencies.map(&:to_hash)
  }
end
protected = project.targets.reject { |target| ['Runner', 'ARMSX2JITHelper'].include?(target.name) }
protected_before = protected.to_h { |target| [target.uuid, target_snapshot(target)] }
runner_phase_before = runner.build_phases.to_h { |phase| [phase.uuid, phase.to_hash] }

candidates = project.targets.select do |target|
  target.name == 'ARMSX2JITHelper' ||
    target.product_reference&.path == 'ARMSX2JITHelper.appex' ||
    target.build_configurations.any? do |configuration|
      configuration.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] ==
        'com.neogamelab.neostation.armsx2jithelper'
    end
end
raise "Ambiguous ARMSX2 helper identity: #{candidates.map(&:name).inspect}" if candidates.length > 1
helper = candidates.first
helper ||= project.new_target(:app_extension, 'ARMSX2JITHelper', :ios, '17.4')
raise 'ARMSX2JITHelper is not an app extension' unless helper.product_type == 'com.apple.product-type.app-extension'
raise 'ARMSX2JITHelper product reference missing' unless helper.product_reference
raise "Unexpected ARMSX2 helper product #{helper.product_reference.path.inspect}" unless helper.product_reference.path == 'ARMSX2JITHelper.appex'

framework_phases = helper.build_phases.select do |phase|
  phase.is_a?(Xcodeproj::Project::Object::PBXFrameworksBuildPhase)
end
raise "ARMSX2 helper has #{framework_phases.length} Frameworks phases" if framework_phases.length > 1
framework_phase = framework_phases.first
unless framework_phase
  framework_phase = project.new(Xcodeproj::Project::Object::PBXFrameworksBuildPhase)
  helper.build_phases << framework_phase
end

# Link the same verified StikJIT binary already embedded by NeoStation, but via
# a ARMSX2-owned target reference. No Dolphin target is touched.
stik_path = '../packages/stikjit_bridge/ios/Frameworks/StikJIT.xcframework/ios-arm64/StikJIT.framework'
framework_group = project.main_group.groups.find { |group| group.display_name == 'Frameworks' }
framework_group ||= project.main_group.new_group('Frameworks')
stik_ref = project.files.find do |file|
  file.path == stik_path && file.source_tree == 'SOURCE_ROOT'
end
stik_ref ||= framework_group.new_file(stik_path, 'SOURCE_ROOT')
raise "StikJIT binary does not resolve: #{stik_ref.real_path}" unless File.file?(File.join(stik_ref.real_path, 'StikJIT'))
unless framework_phase.files.any? { |file| file.file_ref == stik_ref }
  framework_phase.add_file_reference(stik_ref, true)
end

helper_group = project.main_group.find_subpath('ARMSX2JITHelper', true)
helper_group.set_source_tree('<group>')
helper_group.path = 'ARMSX2JITHelper'
entry = helper_group.files.find { |file| file.path == 'Armsx2JITExtensionEntry.swift' }
entry ||= helper_group.new_file('Armsx2JITExtensionEntry.swift')
unless helper.source_build_phase.files.any? { |file| file.file_ref == entry }
  helper.source_build_phase.add_file_reference(entry, true)
end
raise "ARMSX2 helper source does not resolve: #{entry.real_path}" unless File.file?(entry.real_path)

helper.build_configurations.each do |configuration|
  settings = configuration.build_settings
  settings['APPLICATION_EXTENSION_API_ONLY'] = 'YES'
  settings['CLANG_ENABLE_MODULES'] = 'YES'
  settings['CODE_SIGN_STYLE'] = 'Automatic'
  settings['CURRENT_PROJECT_VERSION'] = ENV.fetch('BUILD_NUMBER', '214')
  settings['DEFINES_MODULE'] = 'YES'
  settings['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
  settings['GENERATE_INFOPLIST_FILE'] = 'NO'
  settings['INFOPLIST_FILE'] = 'ARMSX2JITHelper/Info.plist'
  settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.4'
  settings['FRAMEWORK_SEARCH_PATHS'] = [
    '$(inherited)',
    '$(PROJECT_DIR)/../packages/stikjit_bridge/ios/Frameworks/StikJIT.xcframework/ios-arm64'
  ]
  settings['LD_RUNPATH_SEARCH_PATHS'] = '$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks'
  settings['MARKETING_VERSION'] = '1.0.0'
  settings['OTHER_LDFLAGS'] = '$(inherited) -ObjC -all_load'
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.neogamelab.neostation.armsx2jithelper'
  settings['PRODUCT_MODULE_NAME'] = 'ARMSX2JITHelper'
  settings['PRODUCT_NAME'] = '$(TARGET_NAME)'
  settings['SKIP_INSTALL'] = 'YES'
  settings['SWIFT_VERSION'] = '5.0'
  settings['TARGETED_DEVICE_FAMILY'] = '1,2'
end

unless runner.dependencies.any? { |dependency| dependency.target == helper }
  runner.add_dependency(helper)
end
embed = runner.copy_files_build_phases.find { |phase| phase.name == 'Embed App Extensions' }
embed ||= runner.new_copy_files_build_phase('Embed App Extensions')
embed.dst_subfolder_spec = '13'
unless embed.files.any? { |file| file.file_ref == helper.product_reference }
  build_file = embed.add_file_reference(helper.product_reference, true)
  build_file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
end

runner.build_configurations.each do |configuration|
  settings = configuration.build_settings
  settings['CODE_SIGN_ENTITLEMENTS'] = 'Runner/Runner.entitlements'
  settings['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
  settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.4'
end

protected_after = protected.to_h { |target| [target.uuid, target_snapshot(target)] }
raise 'ARMSX2 modified an unrelated Xcode target' unless protected_before == protected_after
runner.build_phases.each do |phase|
  next if phase == embed
  previous = runner_phase_before[phase.uuid]
  raise "ARMSX2 modified Runner phase #{phase.display_name}" if previous && previous != phase.to_hash
end

project.save
reopened = Xcodeproj::Project.open(project_path)
raise 'Saved ARMSX2 helper target missing' unless reopened.targets.count { |target| target.name == 'ARMSX2JITHelper' } == 1
puts "armsx2.helper.target=#{helper.name}"
puts "armsx2.helper.bundle=com.neogamelab.neostation.armsx2jithelper"
puts "armsx2.unrelated_targets_preserved=#{protected.map(&:name).join(',')}"
puts 'armsx2.xcode.save_reopen=passed'
'''
    script = IOS / '.configure_armsx2_helper.rb'
    script.write_text(ruby, encoding='utf-8')
    try:
        env = os.environ.copy()
        gemfile = Path(env.get('BUNDLE_GEMFILE', str(ROOT / 'build-utils/Gemfile.dolphin')))
        if not gemfile.is_file():
            raise SystemExit('Pinned xcodeproj Gemfile is missing')
        env['BUNDLE_GEMFILE'] = str(gemfile)
        subprocess.run(
            ['bundle', 'exec', 'ruby', str(script), str(IOS / 'Runner.xcodeproj')],
            cwd=ROOT,
            check=True,
            env=env,
        )
    finally:
        script.unlink(missing_ok=True)


def main() -> None:
    if not (IOS / 'Runner.xcodeproj').is_dir():
        raise SystemExit('Generate the Flutter iOS host before configuring ARMSX2')
    core = ROOT / 'dist' / 'armsx2' / 'ARMSX2Core.framework' / 'ARMSX2Core'
    if not core.is_file():
        raise SystemExit(f'ARMSX2 Core has not been built: {core}')
    stik = ROOT / 'packages' / 'stikjit_bridge' / 'ios' / 'Frameworks' / 'StikJIT.xcframework' / 'ios-arm64' / 'StikJIT.framework' / 'StikJIT'
    if not stik.is_file():
        raise SystemExit(f'StikJIT device framework missing: {stik}')

    configure_helper_files()
    configure_entitlements()
    configure_podfile()
    configure_xcode_project()
    print('Configured embedded ARMSX2 Core capabilities and ARMSX2JITHelper.')


if __name__ == '__main__':
    main()
