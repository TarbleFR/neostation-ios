Pod::Spec.new do |s|
  s.name             = 'rpcs3_jit_helper'
  s.version          = '0.1.0'
  s.summary          = 'Out-of-process StikJIT universal helper for NeoStation RPCS3.'
  s.description      = <<-DESC
App-extension implementation used only by NeoStation's embedded PlayStation 3
engine. It attaches StikJIT 1.5.0 to the NeoStation host PID with universal.js.
                       DESC
  s.homepage         = 'https://github.com/TarbleFR/neostation-ios'
  s.license          = { :type => 'GPL-3.0' }
  s.author           = { 'NeoStation iOS' => 'TarbleFR' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*.swift'
  s.static_framework = true
  s.platform = :ios, '17.4'
  s.ios.deployment_target = '17.4'
  s.swift_version = '5.0'
  s.module_name = 'rpcs3_jit_helper'
  s.frameworks = 'Foundation', 'Network', 'Security', 'CFNetwork', 'SystemConfiguration', 'IOKit'
  s.libraries = 'z', 'bz2', 'iconv', 'compression'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'APPLICATION_EXTENSION_API_ONLY' => 'YES',
    'FRAMEWORK_SEARCH_PATHS' => '$(inherited) "$(PODS_TARGET_SRCROOT)/../../stikjit_bridge/ios/Frameworks/StikJIT.xcframework/ios-arm64"'
  }
end
