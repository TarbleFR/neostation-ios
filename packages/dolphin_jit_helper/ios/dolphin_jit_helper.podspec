Pod::Spec.new do |s|
  s.name             = 'dolphin_jit_helper'
  s.version          = '0.1.0'
  s.summary          = 'Out-of-process StikJIT legacy helper for NeoStation Dolphin.'
  s.description      = <<-DESC
App-extension implementation used only by NeoStation's embedded GameCube/Wii
engine. It attaches StikJIT 1.5.0 to the NeoStation host PID with legacy.js.
                       DESC
  s.homepage         = 'https://github.com/TarbleFR/neostation-ios'
  s.license          = { :type => 'GPL-3.0' }
  s.author           = { 'NeoStation iOS' => 'TarbleFR' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*.swift'
  s.vendored_frameworks = 'Frameworks/StikJIT.xcframework'
  s.platform = :ios, '17.4'
  s.ios.deployment_target = '17.4'
  s.swift_version = '5.0'
  s.module_name = 'dolphin_jit_helper'
  s.frameworks = 'Foundation', 'Network', 'Security', 'CFNetwork', 'SystemConfiguration', 'IOKit'
  s.libraries = 'z', 'bz2', 'iconv', 'compression'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'APPLICATION_EXTENSION_API_ONLY' => 'NO'
  }
end
