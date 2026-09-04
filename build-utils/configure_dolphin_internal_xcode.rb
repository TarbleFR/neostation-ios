#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'xcodeproj'

root = File.expand_path('..', __dir__)
ios = File.join(root, 'ios')
project_path = File.join(ios, 'Runner.xcodeproj')
template_root = File.join(root, 'native', 'dolphin_internal')
runner_native = File.join(ios, 'Runner', 'DolphinInternal')
helper_root = File.join(ios, 'DolphinJITHelper')

abort "Missing generated iOS project: #{project_path}" unless File.directory?(project_path)
abort "Missing Dolphin native templates" unless File.directory?(template_root)

FileUtils.mkdir_p(runner_native)
FileUtils.mkdir_p(helper_root)

runner_sources = %w[
  DolphinCoreBridge.swift
  DolphinNativeRuntime.swift
  DolphinEmulationViewController.swift
  DolphinJITCoordinator.swift
  DolphinJITExtensionPoint.swift
  DolphinJITMessage.swift
]
runner_sources.each do |name|
  FileUtils.cp(File.join(template_root, name), File.join(runner_native, name))
end
FileUtils.cp(
  File.join(template_root, 'DolphinJITHelper.swift'),
  File.join(helper_root, 'DolphinJITHelper.swift')
)
FileUtils.cp(
  File.join(template_root, 'DolphinJITHelper-Info.plist'),
  File.join(helper_root, 'Info.plist')
)

entitlements = File.join(ios, 'Runner', 'Runner.entitlements')
File.write(entitlements, <<~PLIST)
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0">
  <dict>
    <key>get-task-allow</key>
    <true/>
  </dict>
  </plist>
PLIST

app_delegate = File.join(ios, 'Runner', 'AppDelegate.swift')
abort 'Expected Swift AppDelegate was not generated' unless File.file?(app_delegate)
app_text = File.read(app_delegate)
unless app_text.include?('NeoStationDolphinBridge.register')
  implicit_anchor = '    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)'
  legacy_anchor = '    GeneratedPluginRegistrant.register(with: self)'

  if app_text.scan(implicit_anchor).length == 1
    implicit_registration = <<~SWIFT.chomp
        GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
        if let registrar = engineBridge.pluginRegistry.registrar(
          forPlugin: "NeoStationDolphinBridge"
        ) {
          NeoStationDolphinBridge.register(with: registrar)
        } else {
          assertionFailure("Flutter did not provide the NeoStationDolphinBridge registrar.")
        }
    SWIFT
    app_text = app_text.sub(implicit_anchor, implicit_registration)
  elsif app_text.scan(legacy_anchor).length == 1
    legacy_registration = <<~SWIFT.chomp
        GeneratedPluginRegistrant.register(with: self)
        NeoStationDolphinBridge.register(
          with: self.registrar(forPlugin: "NeoStationDolphinBridge")
        )
    SWIFT
    app_text = app_text.sub(legacy_anchor, legacy_registration)
  else
    abort 'Unexpected AppDelegate.swift layout: no supported Flutter plugin registration anchor'
  end

  File.write(app_delegate, app_text)
end

project = Xcodeproj::Project.open(project_path)
runner = project.targets.find { |target| target.name == 'Runner' }
abort 'Runner target not found' unless runner

runner_group = project.main_group.groups.find { |group| group.display_name == 'Runner' }
abort 'Runner group not found' unless runner_group
native_group = runner_group.groups.find { |group| group.display_name == 'DolphinInternal' }
native_group ||= runner_group.new_group('DolphinInternal', 'DolphinInternal')

def source_reference(group, name)
  group.files.find { |file| file.path == name } || group.new_file(name)
end

def add_source(target, reference)
  existing = target.source_build_phase.files_references.include?(reference)
  target.source_build_phase.add_file_reference(reference, true) unless existing
end

source_refs = {}
runner_sources.each do |name|
  reference = source_reference(native_group, name)
  source_refs[name] = reference
  add_source(runner, reference)
end

entitlements_ref = runner_group.files.find { |file| file.path == 'Runner.entitlements' }
entitlements_ref ||= runner_group.new_file('Runner.entitlements')

helper = project.targets.find { |target| target.name == 'DolphinJITHelper' }
unless helper
  helper = project.new_target(:app_extension, 'DolphinJITHelper', :ios, '26.0')
  # xcodeproj models PBXNativeTarget.product_type as a Symbol. Passing the raw
  # String raises before the generated project can be saved.
  helper.product_type = :'com.apple.product-type.extensionkit-extension'
  helper.product_reference.explicit_file_type = 'wrapper.extensionkit-extension'
  helper.product_reference.path = 'DolphinJITHelper.appex'
end

helper_group = project.main_group.groups.find do |group|
  group.display_name == 'DolphinJITHelper'
end
helper_group ||= project.main_group.new_group('DolphinJITHelper', 'DolphinJITHelper')
helper_source = source_reference(helper_group, 'DolphinJITHelper.swift')
helper_plist = source_reference(helper_group, 'Info.plist')
add_source(helper, helper_source)
add_source(helper, source_refs.fetch('DolphinJITMessage.swift'))

# The helper links the device slice directly. The framework is copied into the
# helper bundle after xcodebuild, before IPA verification.
frameworks_group = project.frameworks_group || project.main_group.new_group('Frameworks')
stik_path = '../packages/stikjit_bridge/ios/Frameworks/StikJIT.xcframework/ios-arm64/StikJIT.framework'
stik_ref = frameworks_group.files.find { |file| file.path == stik_path }
stik_ref ||= frameworks_group.new_file(stik_path)
unless helper.frameworks_build_phase.files_references.include?(stik_ref)
  helper.frameworks_build_phase.add_file_reference(stik_ref, true)
end

# Runner must build the helper product even though it is copied to Extensions/
# after the unsigned app is produced.
unless runner.dependencies.any? { |dependency| dependency.target == helper }
  runner.add_dependency(helper)
end

runner.build_configurations.each do |configuration|
  settings = configuration.build_settings
  settings['IPHONEOS_DEPLOYMENT_TARGET'] = '26.0'
  settings['SWIFT_VERSION'] = '5.0'
  settings['CODE_SIGN_ENTITLEMENTS'] = 'Runner/Runner.entitlements'
  settings['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
  settings['OTHER_LDFLAGS'] = '$(inherited) -ObjC'
end

helper.build_configurations.each do |configuration|
  settings = configuration.build_settings
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.neogamelab.neostation.DolphinJITHelper'
  settings['PRODUCT_NAME'] = 'DolphinJITHelper'
  settings['EXECUTABLE_NAME'] = 'DolphinJITHelper'
  settings['INFOPLIST_FILE'] = 'DolphinJITHelper/Info.plist'
  settings['GENERATE_INFOPLIST_FILE'] = 'NO'
  settings['IPHONEOS_DEPLOYMENT_TARGET'] = '26.0'
  settings['SWIFT_VERSION'] = '5.0'
  settings['TARGETED_DEVICE_FAMILY'] = '1,2'
  settings['APPLICATION_EXTENSION_API_ONLY'] = 'YES'
  settings['SKIP_INSTALL'] = 'YES'
  settings['DEFINES_MODULE'] = 'YES'
  settings['LD_RUNPATH_SEARCH_PATHS'] = '$(inherited) @executable_path/Frameworks @loader_path/Frameworks'
  settings['FRAMEWORK_SEARCH_PATHS'] = [
    '$(inherited)',
    '$(PROJECT_DIR)/../packages/stikjit_bridge/ios/Frameworks/StikJIT.xcframework/ios-arm64',
  ]
  settings['OTHER_LDFLAGS'] = '$(inherited) -framework StikJIT'
  settings['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
end

project.build_configurations.each do |configuration|
  configuration.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '26.0'
end

project.save
puts 'Configured Runner + DolphinJITHelper ExtensionFoundation targets.'
