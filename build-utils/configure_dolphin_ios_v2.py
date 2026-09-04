#!/usr/bin/env python3
"""Configure the generated Flutter iOS project for embedded Dolphin.

Only Runner build metadata, the dedicated Dolphin helper target and Dolphin Sys
resources are touched. Existing URL schemes and emulator integrations are
preserved; no Dolphin URL scheme is added.
"""

from __future__ import annotations

import os
import plistlib
import re
import shutil
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / "ios"
RUNNER = IOS / "Runner"
HELPER = IOS / "DolphinJITHelper"


def configure_info_plist() -> None:
    path = RUNNER / "Info.plist"
    with path.open("rb") as handle:
        payload = plistlib.load(handle)

    payload["UIFileSharingEnabled"] = True
    payload["LSSupportsOpeningDocumentsInPlace"] = True
    payload["UISupportedInterfaceOrientations"] = [
        "UIInterfaceOrientationLandscapeLeft",
        "UIInterfaceOrientationLandscapeRight",
    ]
    payload["UISupportedInterfaceOrientations~ipad"] = [
        "UIInterfaceOrientationLandscapeLeft",
        "UIInterfaceOrientationLandscapeRight",
    ]

    query_schemes = payload.get("LSApplicationQueriesSchemes")
    if not isinstance(query_schemes, list):
        query_schemes = []
    # Preserve existing integrations and the schemes already required by the
    # stable NeoStation build. Dolphin itself deliberately has no URL scheme.
    query_schemes = [
        item
        for item in query_schemes
        if isinstance(item, str)
        and item.lower() not in {"dolphin", "dolphinios", "dolphin-emu"}
    ]
    for required in ("retroarch", "shortcuts", "armsx2", "melonx"):
        if required not in query_schemes:
            query_schemes.append(required)
    payload["LSApplicationQueriesSchemes"] = query_schemes

    url_types = payload.get("CFBundleURLTypes")
    if not isinstance(url_types, list):
        url_types = []
    cleaned = []
    has_neostation = False
    for entry in url_types:
        if not isinstance(entry, dict):
            continue
        schemes = entry.get("CFBundleURLSchemes")
        if isinstance(schemes, list):
            schemes = [
                scheme
                for scheme in schemes
                if isinstance(scheme, str)
                and scheme.lower() not in {"dolphin", "dolphinios", "dolphin-emu"}
            ]
            entry = dict(entry)
            entry["CFBundleURLSchemes"] = schemes
            has_neostation = has_neostation or "neostation" in schemes
        cleaned.append(entry)
    if not has_neostation:
        cleaned.append(
            {
                "CFBundleURLName": "com.neogamelab.neostation",
                "CFBundleURLSchemes": ["neostation"],
            }
        )
    payload["CFBundleURLTypes"] = cleaned

    with path.open("wb") as handle:
        plistlib.dump(payload, handle, fmt=plistlib.FMT_XML, sort_keys=False)


def configure_entitlements() -> None:
    path = RUNNER / "Runner.entitlements"
    payload = {}
    if path.is_file():
        try:
            with path.open("rb") as handle:
                payload = plistlib.load(handle)
        except Exception:
            payload = {}
    payload["get-task-allow"] = True
    with path.open("wb") as handle:
        plistlib.dump(payload, handle, fmt=plistlib.FMT_XML, sort_keys=False)


def configure_helper_files() -> None:
    HELPER.mkdir(parents=True, exist_ok=True)
    shutil.copy2(
        ROOT / "native/dolphin_internal_helper/DolphinJITExtensionEntry.swift",
        HELPER / "DolphinJITExtensionEntry.swift",
    )
    shutil.copy2(
        ROOT / "native/dolphin_internal_helper/Info.plist",
        HELPER / "Info.plist",
    )


def configure_podfile() -> None:
    path = IOS / "Podfile"
    text = path.read_text(encoding="utf-8")
    text = re.sub(
        r"^\s*#?\s*platform\s+:ios,\s*'[^']+'\s*$",
        "platform :ios, '17.4'",
        text,
        count=1,
        flags=re.MULTILINE,
    )
    helper_block = """
# NeoStation-owned helper used only for Dolphin's legacy BRK #0x69 handshake.
target 'DolphinJITHelper' do
  use_modular_headers!
  pod 'dolphin_jit_helper', :path => '../packages/dolphin_jit_helper/ios'
end

"""
    if "target 'DolphinJITHelper' do" not in text:
        anchor = "post_install do |installer|"
        if anchor in text:
            text = text.replace(anchor, helper_block + anchor, 1)
        else:
            text += "\n" + helper_block
    path.write_text(text, encoding="utf-8")


def configure_xcode_project() -> None:
    ruby = r'''
require 'xcodeproj'

project_path = ARGV.fetch(0)
project = Xcodeproj::Project.open(project_path)
runner = project.targets.find { |target| target.name == 'Runner' }
raise 'Runner target not found' if runner.nil?

helper_candidates = project.targets.select { |target| target.name == 'DolphinJITHelper' }
if helper_candidates.length > 1
  discovered = helper_candidates.map { |target| "#{target.name}:#{target.product_type}" }.join(', ')
  raise "Multiple DolphinJITHelper targets found: #{discovered}"
end
helper = helper_candidates.first
if helper.nil?
  helper = project.new_target(:app_extension, 'DolphinJITHelper', :ios, '17.4')
end
expected_type = 'com.apple.product-type.app-extension'
unless helper.product_type == expected_type
  raise "DolphinJITHelper has unexpected product type #{helper.product_type.inspect}; expected #{expected_type}"
end
if helper.product_reference.nil?
  raise 'DolphinJITHelper has no product reference'
end
helper.product_reference.path = 'DolphinJITHelper.appex'

framework_phases = helper.build_phases.select do |phase|
  phase.is_a?(Xcodeproj::Project::Object::PBXFrameworksBuildPhase)
end
if framework_phases.length > 1
  raise "DolphinJITHelper has #{framework_phases.length} PBXFrameworksBuildPhase objects"
end
frameworks_phase = framework_phases.first
if frameworks_phase.nil?
  frameworks_phase = project.new(
    Xcodeproj::Project::Object::PBXFrameworksBuildPhase
  )
  helper.build_phases << frameworks_phase
end

spec = Gem.loaded_specs['xcodeproj']
puts "xcodeproj.version=#{Xcodeproj::VERSION}"
puts "xcodeproj.path=#{spec&.full_gem_path}"
puts "helper.class=#{helper.class.name}"
puts "helper.name=#{helper.name}"
puts "helper.product_type=#{helper.product_type}"
puts "helper.product_reference=#{helper.product_reference.path}"
puts "helper.build_phases=#{helper.build_phases.map { |phase| phase.class.name }.join(',')}"
puts "helper.respond_to.frameworks_build_phase=#{helper.respond_to?(:frameworks_build_phase)}"
puts "helper.respond_to.frameworks_build_phases=#{helper.respond_to?(:frameworks_build_phases)}"
puts "helper.framework_phase=#{frameworks_phase.uuid}"

helper_group = project.main_group.find_subpath('DolphinJITHelper', true)
helper_group.set_source_tree('<group>')
entry = helper_group.files.find { |file| file.path == 'DolphinJITExtensionEntry.swift' }
entry ||= helper_group.new_file('DolphinJITExtensionEntry.swift')
unless helper.source_build_phase.files.any? { |build_file| build_file.file_ref == entry }
  helper.source_build_phase.add_file_reference(entry, true)
end

helper.build_configurations.each do |configuration|
  settings = configuration.build_settings
  settings['APPLICATION_EXTENSION_API_ONLY'] = 'NO'
  settings['CLANG_ENABLE_MODULES'] = 'YES'
  settings['CODE_SIGN_STYLE'] = 'Automatic'
  settings['CURRENT_PROJECT_VERSION'] = '194'
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

embed = runner.copy_files_build_phases.find { |phase| phase.name == 'Embed App Extensions' }
embed ||= runner.new_copy_files_build_phase('Embed App Extensions')
embed.dst_subfolder_spec = '13'
unless embed.files.any? { |build_file| build_file.file_ref == helper.product_reference }
  embed.add_file_reference(helper.product_reference, true)
end

runner_group = project.main_group.find_subpath('Runner', false)
raise 'Runner group not found' if runner_group.nil?
sys_ref = runner_group.files.find { |file| file.path == 'Sys' }
sys_ref ||= runner_group.new_file('Sys')
sys_ref.last_known_file_type = 'folder'
unless runner.resources_build_phase.files.any? { |build_file| build_file.file_ref == sys_ref }
  runner.resources_build_phase.add_file_reference(sys_ref, true)
end

project.save
'''
    script = IOS / ".configure_dolphin_helper.rb"
    script.write_text(ruby, encoding="utf-8")
    try:
        env = os.environ.copy()
        gemfile = Path(
            env.get(
                "BUNDLE_GEMFILE",
                str(ROOT / "build-utils/Gemfile.dolphin"),
            )
        )
        command = ["ruby", str(script), str(IOS / "Runner.xcodeproj")]
        if gemfile.is_file():
            env["BUNDLE_GEMFILE"] = str(gemfile)
            command = [
                "bundle",
                "exec",
                "ruby",
                str(script),
                str(IOS / "Runner.xcodeproj"),
            ]
        subprocess.run(command, cwd=ROOT, check=True, env=env)
    finally:
        script.unlink(missing_ok=True)


def main() -> None:
    if not (IOS / "Runner.xcodeproj").is_dir():
        raise SystemExit("Run flutter create --platforms=ios before this script")
    if not (RUNNER / "Sys").is_dir():
        raise SystemExit("Dolphin Data/Sys must be copied to ios/Runner/Sys first")
    configure_helper_files()
    configure_info_plist()
    configure_entitlements()
    configure_podfile()
    configure_xcode_project()
    print("Configured Runner, DolphinJITHelper and root Sys resources.")


if __name__ == "__main__":
    main()
