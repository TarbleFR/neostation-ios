Pod::Spec.new do |s|
  s.name             = 'rpcs3_internal_bridge'
  s.version          = '0.1.0'
  s.summary          = 'Lazy-loaded in-process RPCS3 Core bridge for NeoStation iOS.'
  s.description      = <<-DESC
Exposes NeoStation's PlayStation 3 runtime bridge without linking RPCS3 Core
into the application at process startup. The verified RPCS3 dylib is embedded
as a dormant runtime resource and opened only when a PS3 session is requested.
The standalone RPCS3 SwiftUI application is not embedded.
                       DESC
  s.homepage         = 'https://github.com/TarbleFR/neostation-ios'
  s.license          = { :type => 'GPL-3.0' }
  s.author           = { 'NeoStation iOS' => 'TarbleFR' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  # Deliberately do NOT use vendored_libraries here. CocoaPods would link the
  # dylib into Runner/rpcs3_internal_bridge and dyld would load RPCS3 before
  # NeoStation reaches its menus. Build 216 copies this file after Xcode builds
  # the host, and Rpcs3InternalBridgePlugin opens it later with dlopen().
  s.preserve_paths   = 'Frameworks/libRPCS3Core.dylib'
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
