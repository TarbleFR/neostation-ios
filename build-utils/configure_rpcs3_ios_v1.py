#!/usr/bin/env python3
"""Configure the generated iOS host for NeoStation's embedded RPCS3 engine.

This script owns only RPCS3-specific host capabilities and the RPCS3JITHelper
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
HELPER = IOS / 'RPCS3JITHelper'


def write_plist(path: Path, payload: dict) -> None:
    path.write_bytes(plistlib.dumps(payload, fmt=plistlib.FMT_XML, sort_keys=False))


def configure_entitlements() -> None:
    """Mirror the memory/JIT capabilities present in the verified RPCS3 IPA."""
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
    source = ROOT / 'native' / 'rpcs3_internal_helper'
    HELPER.mkdir(parents=True, exist_ok=True)
    for name in ('Rpcs3JITExtensionEntry.swift', 'Info.plist'):
        candidate = source / name
        if not candidate.is_file():
            raise SystemExit(f'Missing RPCS3 helper source: {candidate}')
        shutil.copy2(candidate, HELPER / name)


def configure_podfile() -> None:
    path = IOS / 'Podfile'
    if not path.is_file():
        raise SystemExit('Flutter Podfile is missing')
    text = path.read_text(encoding='utf-8')
    block = """
# NeoStation-owned helper used only by the embedded RPCS3 engine.
target 'RPCS3JITHelper' do
  use_frameworks!
  use_modular_headers!
  pod 'rpcs3_jit_helper', :path => '../packages/rpcs3_jit_helper/ios'
end

"""
    if "target 'RPCS3JITHelper' do" not in text:
        anchor = 'post_install do |installer|'
        text = text.replace(anchor, block + anchor, 1) if anchor in text else text + '\n' + block
    else:
        pattern = r"(?ms)^target 'RPCS3JITHelper' do\n.*?^end$"
        matches = list(re.finditer(pattern, text))
        if len(matches) != 1:
            raise SystemExit('Expected exactly one RPCS3JITHelper Podfile stanza')
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

# RPCS3 may create/update only its own helper target and Runner's app-extension
# dependency/embed references. Existing emulator targets are immutable here.
def target_snapshot(target)
  {
    'target' => target.to_hash,
    'phases' => target.build_phases.map { |phase| [phase.to_hash, phase.files.map(&:to_hash)] },
    'configurations' => target.build_configurations.map(&:to_hash),
    'dependencies' => target.dependencies.map(&:to_hash)
  }
end
protected = project.targets.reject { |target| ['Runner', 'RPCS3JITHelper'].include?(target.name) }
protected_before = protected.to_h { |target| [target.uuid, target_snapshot(target)] }
runner_phase_before = runner.build_phases.to_h { |phase| [phase.uuid, phase.to_hash] }

candidates = project.targets.select do |target|
  target.name == 'RPCS3JITHelper' ||
    target.product_reference&.path == 'RPCS3JITHelper.appex' ||
    target.build_configurations.any? do |configuration|
      configuration.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] ==
        'com.neogamelab.neostation.rpcs3jithelper'
    end
end
raise "Ambiguous RPCS3 helper identity: #{candidates.map(&:name).inspect}" if candidates.length > 1
helper = candidates.first
helper ||= project.new_target(:app_extension, 'RPCS3JITHelper', :ios, '17.4')
raise 'RPCS3JITHelper is not an app extension' unless helper.product_type == 'com.apple.product-type.app-extension'
raise 'RPCS3JITHelper product reference missing' unless helper.product_reference
raise "Unexpected RPCS3 helper product #{helper.product_reference.path.inspect}" unless helper.product_reference.path == 'RPCS3JITHelper.appex'

framework_phases = helper.build_phases.select do |phase|
  phase.is_a?(Xcodeproj::Project::Object::PBXFrameworksBuildPhase)
end
raise "RPCS3 helper has #{framework_phases.length} Frameworks phases" if framework_phases.length > 1
framework_phase = framework_phases.first
unless framework_phase
  framework_phase = project.new(Xcodeproj::Project::Object::PBXFrameworksBuildPhase)
  helper.build_phases << framework_phase
end

# Link the same verified StikJIT binary already embedded by NeoStation, but via
# a RPCS3-owned target reference. No Dolphin target is touched.
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

helper_group = project.main_group.find_subpath('RPCS3JITHelper', true)
helper_group.set_source_tree('<group>')
helper_group.path = 'RPCS3JITHelper'
entry = helper_group.files.find { |file| file.path == 'Rpcs3JITExtensionEntry.swift' }
entry ||= helper_group.new_file('Rpcs3JITExtensionEntry.swift')
unless helper.source_build_phase.files.any? { |file| file.file_ref == entry }
  helper.source_build_phase.add_file_reference(entry, true)
end
raise "RPCS3 helper source does not resolve: #{entry.real_path}" unless File.file?(entry.real_path)

helper.build_configurations.each do |configuration|
  settings = configuration.build_settings
  settings['APPLICATION_EXTENSION_API_ONLY'] = 'YES'
  settings['CLANG_ENABLE_MODULES'] = 'YES'
  settings['CODE_SIGN_STYLE'] = 'Automatic'
  settings['CURRENT_PROJECT_VERSION'] = ENV.fetch('BUILD_NUMBER', '214')
  settings['DEFINES_MODULE'] = 'YES'
  settings['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
  settings['GENERATE_INFOPLIST_FILE'] = 'NO'
  settings['INFOPLIST_FILE'] = 'RPCS3JITHelper/Info.plist'
  settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.4'
  settings['FRAMEWORK_SEARCH_PATHS'] = [
    '$(inherited)',
    '$(PROJECT_DIR)/../packages/stikjit_bridge/ios/Frameworks/StikJIT.xcframework/ios-arm64'
  ]
  settings['LD_RUNPATH_SEARCH_PATHS'] = '$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks'
  settings['MARKETING_VERSION'] = '1.0.0'
  settings['OTHER_LDFLAGS'] = '$(inherited) -ObjC -all_load'
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.neogamelab.neostation.rpcs3jithelper'
  settings['PRODUCT_MODULE_NAME'] = 'RPCS3JITHelper'
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
raise 'RPCS3 modified an unrelated Xcode target' unless protected_before == protected_after
runner.build_phases.each do |phase|
  next if phase == embed
  previous = runner_phase_before[phase.uuid]
  raise "RPCS3 modified Runner phase #{phase.display_name}" if previous && previous != phase.to_hash
end

project.save
reopened = Xcodeproj::Project.open(project_path)
raise 'Saved RPCS3 helper target missing' unless reopened.targets.count { |target| target.name == 'RPCS3JITHelper' } == 1
puts "rpcs3.helper.target=#{helper.name}"
puts "rpcs3.helper.bundle=com.neogamelab.neostation.rpcs3jithelper"
puts "rpcs3.unrelated_targets_preserved=#{protected.map(&:name).join(',')}"
puts 'rpcs3.xcode.save_reopen=passed'
'''
    script = IOS / '.configure_rpcs3_helper.rb'
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
        raise SystemExit('Generate the Flutter iOS host before configuring RPCS3')
    core = ROOT / 'packages' / 'rpcs3_internal_bridge' / 'ios' / 'Frameworks' / 'libRPCS3Core.dylib'
    if not core.is_file():
        raise SystemExit(f'RPCS3 Core has not been materialized: {core}')
    stik = ROOT / 'packages' / 'stikjit_bridge' / 'ios' / 'Frameworks' / 'StikJIT.xcframework' / 'ios-arm64' / 'StikJIT.framework' / 'StikJIT'
    if not stik.is_file():
        raise SystemExit(f'StikJIT device framework missing: {stik}')

    configure_helper_files()
    configure_entitlements()
    configure_podfile()
    configure_xcode_project()
    print('Configured embedded RPCS3 Core capabilities and RPCS3JITHelper.')


if __name__ == '__main__':
    main()
