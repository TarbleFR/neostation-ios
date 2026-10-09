Pod::Spec.new do |s|
  s.name             = 'libretro_internal_bridge'
  s.version          = '0.1.0'
  s.summary          = 'Embedded libretro host for NeoStation iOS.'
  s.description      = <<-DESC
Runs the libretro core of the launched game inside NeoStation. Cores are
copied into Runner.app/Frameworks after the build and loaded only when a game
starts; no external RetroArch application is involved.
                       DESC
  s.homepage         = 'https://github.com/TarbleFR/neostation-ios'
  s.license          = { :type => 'GPL-3.0' }
  s.author           = { 'NeoStation iOS' => 'TarbleFR' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*.{h,m}',
                       'ThirdParty/rcheevos/include/*.h',
                       'ThirdParty/rcheevos/src/**/*.{h,c}'
  s.public_header_files = 'Classes/LibretroInternalBridgePlugin.h'
  s.preserve_paths   = 'ThirdParty/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '17.4'
  s.ios.deployment_target = '17.4'
  s.frameworks = 'UIKit', 'Foundation', 'Metal', 'QuartzCore', 'AVFoundation', 'GameController',
                 'OpenGLES', 'CoreVideo', 'Security'
  s.libraries = 'z'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_ENABLE_OBJC_ARC' => 'YES',
    'HEADER_SEARCH_PATHS' => '$(inherited) "${PODS_TARGET_SRCROOT}/ThirdParty/include" ' \
                             '"${PODS_TARGET_SRCROOT}/ThirdParty/include/libretro" ' \
                             '"${PODS_TARGET_SRCROOT}/ThirdParty/rcheevos/include" ' \
                             '"${PODS_TARGET_SRCROOT}/ThirdParty/rcheevos/src"',
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) GLES_SILENCE_DEPRECATION=1 COREVIDEO_SILENCE_GL_DEPRECATION=1 ' \
                                      'VK_USE_PLATFORM_METAL_EXT=1 VK_NO_PROTOTYPES=1 RC_CLIENT_SUPPORTS_HASH=1',
    'OTHER_LDFLAGS' => '$(inherited) -ObjC'
  }
end
