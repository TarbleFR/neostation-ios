Pod::Spec.new do |s|
  s.name             = 'dolphin_internal_bridge'
  s.version          = '0.1.0'
  s.summary          = 'Isolated in-process Dolphin Core bridge for NeoStation iOS.'
  s.description      = <<-DESC
Links the pinned arm64 iOS Dolphin Core into NeoStation and exposes only the
GameCube/Wii runtime, Metal surface, lifecycle, and Dolphin-specific StikJIT
legacy gate. It does not replace or modify other emulator integrations.
                       DESC
  s.homepage         = 'https://github.com/TarbleFR/neostation-ios'
  s.license          = { :type => 'GPL-3.0' }
  s.author           = { 'NeoStation iOS' => 'TarbleFR' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.resources        = 'TouchResources/*'
  s.vendored_frameworks = 'Frameworks/DolphinCore.framework'
  s.dependency 'Flutter'
  s.dependency 'stikjit_bridge'
  s.platform = :ios, '17.4'
  s.ios.deployment_target = '17.4'
  s.swift_version = '5.0'
  s.frameworks = 'UIKit', 'Metal', 'MetalKit', 'QuartzCore', 'Security', 'AVFoundation', 'AudioToolbox', 'GameController'
  s.libraries = 'c++', 'z', 'bz2', 'iconv', 'compression'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++20',
    # CocoaPods exposes the vendored dynamic framework to consumers, but the
    # bridge's own dynamic target must also link the actual Dolphin C ABI.
    # Keep this target-local; do not add the core to any other emulator pod.
    'OTHER_LDFLAGS' => '$(inherited) -ObjC -framework DolphinCore'
  }
end
