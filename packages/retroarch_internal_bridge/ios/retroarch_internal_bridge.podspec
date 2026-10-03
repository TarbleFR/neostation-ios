Pod::Spec.new do |s|
  s.name = 'retroarch_internal_bridge'
  s.version = '0.1.0'
  s.summary = 'Host-owned curated RetroArch sessions in NeoStation iOS.'
  s.description = 'Loads the embedded source-built RetroArch frontend through a versioned C ABI and presents one native session menu for curated libretro cores.'
  s.homepage = 'https://github.com/TarbleFR/neostation-ios'
  s.license = { :type => 'GPL-3.0' }
  s.author = { 'NeoStation iOS' => 'TarbleFR' }
  s.source = { :path => '.' }
  s.source_files = 'Classes/**/*.{h,mm}'
  s.public_header_files = 'Classes/RetroArchInternalBridgePlugin.h'
  s.dependency 'Flutter'
  s.platform = :ios, '18.0'
  s.ios.deployment_target = '18.0'
  s.frameworks = 'Foundation', 'UIKit', 'GameController', 'UniformTypeIdentifiers', 'QuartzCore'
  s.libraries = 'c++'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++20',
    'OTHER_LDFLAGS' => '$(inherited) -ObjC'
  }
end
