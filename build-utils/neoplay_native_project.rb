require 'xcodeproj'
require 'fileutils'
root = File.expand_path('..', __dir__)
output = File.join(root, 'build', 'neoplay-native')
FileUtils.mkdir_p(output)
project = Xcodeproj::Project.new(File.join(output, 'NPCheck.xcodeproj'))
app = project.new_target(:application, 'NPCheck', :ios, '18.0')
tests = project.new_target(:unit_test_bundle, 'NPCheckTests', :ios, '18.0')
tests.add_dependency(app)
[app, tests].each do |target|
  target.build_configurations.each do |config|
    config.build_settings['SWIFT_VERSION'] = '5.0'
    config.build_settings['GENERATE_INFOPLIST_FILE'] = 'YES'
    config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'org.neostation.' + target.name.downcase
    config.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'
    config.build_settings['TARGETED_DEVICE_FAMILY'] = '1,2'
    config.build_settings['ENABLE_TESTABILITY'] = 'YES'
    config.build_settings['GCC_OPTIMIZATION_LEVEL'] = 's'
  end
end
app.build_configurations.each { |c| c.build_settings['INFOPLIST_KEY_UILaunchScreen_Generation'] = 'YES' }
tests.build_configurations.each do |c|
  c.build_settings['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/NPCheck.app/NPCheck'
  c.build_settings['BUNDLE_LOADER'] = '$(TEST_HOST)'
end
File.write(File.join(output,'App.swift'), "import UIKit\n@main class HarnessApp: UIResponder, UIApplicationDelegate { var window: UIWindow?; func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool { window = UIWindow(frame: UIScreen.main.bounds); window?.rootViewController = UIViewController(); window?.makeKeyAndVisible(); return true } }\n")
Dir.glob(File.join(root,'packages/neoplay_bridge/ios/Classes/*.swift')).reject { |f| f.end_with?('/NeoPlayBridgePlugin.swift') }.each { |f| app.add_file_references([project.main_group.new_file(f)]) }
app.add_file_references([project.main_group.new_file(File.join(output,'App.swift'))])
Dir.glob(File.join(root,'test/neoplay/*_tests.swift')).each { |file| tests.add_file_references([project.main_group.new_file(file)]) }
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app); scheme.add_test_target(tests); scheme.set_launch_target(app)
scheme.save_as(project.path, 'NPCheck', true)
File.write(File.join(output,'Podfile'), "platform :ios, '18.0'\nuse_frameworks!\ntarget 'NPCheck' do\n  pod 'google-cast-sdk', '4.8.6'\n  target 'NPCheckTests' do\n    inherit! :search_paths\n  end\nend\n")
