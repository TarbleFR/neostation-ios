Pod::Spec.new do |s|
  s.name             = 'rpcs3_internal_bridge'
  s.version          = '0.1.0'
  s.summary          = 'In-process RPCS3 Core bridge for NeoStation iOS.'
  s.description      = <<-DESC
Loads the RPCS3 iOS 0.8.1 Core as an isolated PlayStation 3 engine inside
NeoStation. The standalone RPCS3 SwiftUI application is not embedded.
                       DESC
  s.homepage         = 'https://github.com/TarbleFR/neostation-ios'
  s.license          = { :type => 'GPL-3.0' }
  s.author           = { 'NeoStation iOS' => 'TarbleFR' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.vendored_libraries = 'Frameworks/libRPCS3Core.dylib'
  s.dependency 'Flutter'
  s.platform = :ios, '17.4'
  s.ios.deployment_target = '17.4'
  s.frameworks = 'UIKit', 'Metal', 'QuartzCore', 'Security', 'CoreFoundation', 'AudioToolbox', 'CoreGraphics', 'IOSurface', 'CoreServices', 'CoreAudio', 'CoreMIDI', 'Foundation', 'MetalFX'
  s.libraries = 'c++', 'iconv'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++20',
    'OTHER_LDFLAGS' => '$(inherited) -ObjC'
  }
end
