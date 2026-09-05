#!/usr/bin/env ruby
# Execute the production menu and original touchscreen widgets in iOS Simulator.
require 'xcodeproj'
require 'json'
require 'fileutils'

package = File.expand_path('..', __dir__)
output = File.expand_path('../../../build/dolphin-ci/session-ui', __dir__)
FileUtils.mkdir_p(output)
project_path = File.join(output, 'SessionHarness.xcodeproj')
project = Xcodeproj::Project.new(project_path)
app = project.new_target(:application, 'SessionHarness', :ios, '17.4')
tests = project.new_target(:unit_test_bundle, 'SessionMenuTests', :ios, '17.4')
tests.add_dependency(app)
sources = [File.join(__dir__, 'SessionMenuHarness.mm'), File.join(package, 'ios/Classes/DolphinSessionMenu.mm'), File.join(package, 'ios/Classes/DolphinPerformanceOverlay.mm'), File.join(package, 'ios/Classes/DolphinRecordingController.mm')]
sources += Dir[File.join(package, 'ios/Classes/TouchController/*.{swift,mm}')]
sources.each { |path| app.source_build_phase.add_file_reference(project.main_group.new_file(path)) }
Dir[File.join(package, 'ios/TouchResources/*')].each do |path|
  app.resources_build_phase.add_file_reference(project.main_group.new_file(path))
end
tests.source_build_phase.add_file_reference(project.main_group.new_file(File.join(__dir__, 'SessionMenuTests.mm')))
tests.source_build_phase.add_file_reference(project.main_group.new_file(File.join(__dir__, 'SessionLifecycleTests.mm')))
tests.source_build_phase.add_file_reference(project.main_group.new_file(File.join(__dir__, 'PerformanceOverlayTests.mm')))
tests.source_build_phase.add_file_reference(project.main_group.new_file(File.join(__dir__, 'RecordingControllerTests.mm')))
tests.source_build_phase.add_file_reference(project.main_group.new_file(File.join(package, 'ios/Classes/DolphinSessionLifecycle.mm')))

[app, tests].each do |target|
  target.build_configurations.each do |configuration|
    configuration.build_settings.merge!({
      'PRODUCT_BUNDLE_IDENTIFIER' => "com.neostation.tests.#{target.name}",
      'GENERATE_INFOPLIST_FILE' => 'YES',
      'CLANG_ENABLE_OBJC_ARC' => 'YES',
      'CLANG_CXX_LANGUAGE_STANDARD' => 'c++20',
      'CODE_SIGNING_ALLOWED' => 'NO',
      'TARGETED_DEVICE_FAMILY' => '1,2',
      'HEADER_SEARCH_PATHS' => [File.join(package, 'ios/Classes'), File.join(package, 'ios/Classes/TouchController')],
      'SWIFT_VERSION' => '5.0',
      'OTHER_LDFLAGS' => ['$(inherited)', '-framework', 'UIKit', '-framework', 'CoreGraphics', '-framework', 'AVFoundation', '-framework', 'ReplayKit', '-framework', 'CoreImage', '-framework', 'VideoToolbox', '-framework', 'Metal', '-framework', 'CoreMedia', '-framework', 'CoreVideo', '-framework', 'AudioToolbox'],
    })
    if configuration.name == 'Debug'
      configuration.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] = ['$(inherited)', 'DEBUG=1']
    end
  end
end
app.build_configurations.each do |configuration|
  configuration.build_settings.merge!({
    'PRODUCT_MODULE_NAME' => 'dolphin_internal_bridge',
    'ENABLE_TESTABILITY' => 'YES',
    'SWIFT_OBJC_BRIDGING_HEADER' => File.join(package, 'ios/Classes/TouchController/TCManagerInterface.h'),
    'INFOPLIST_KEY_UILaunchScreen_Generation' => 'YES',
    'INFOPLIST_KEY_UISupportedInterfaceOrientations' => 'UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight',
  })
end
tests.build_configurations.each do |configuration|
  configuration.build_settings['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/SessionHarness.app/SessionHarness'
  configuration.build_settings['BUNDLE_LOADER'] = '$(TEST_HOST)'
end
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.add_test_target(tests)
scheme.set_launch_target(app)
scheme.save_as(project_path, 'SessionHarness', true)

devices = JSON.parse(`xcrun simctl list devices available --json`).fetch('devices').values.flatten
device = devices.find { |item| item['name'].start_with?('iPhone') && item['isAvailable'] }
abort 'No iPhone simulator available for the native UI regression test' unless device
command = ['xcodebuild', 'test', '-project', project_path, '-scheme', 'SessionHarness',
           '-destination', "platform=iOS Simulator,id=#{device['udid']}",
           '-derivedDataPath', File.join(output, 'DerivedData'),
           '-resultBundlePath', File.join(output, 'SessionUI.xcresult'),
           '-parallel-testing-enabled', 'NO', 'CODE_SIGNING_ALLOWED=NO']
exit(system(*command) ? 0 : 1)
