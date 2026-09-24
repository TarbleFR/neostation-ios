Pod::Spec.new do |s|
  s.name             = 'kartpad_internal_bridge'
  s.version          = '0.1.0'
  s.summary          = 'Lazy-loaded in-process KartPad Core bridge for NeoStation iOS.'
  s.description      = <<-DESC
Defines NeoStation's host-owned KartPad session boundary. KartPadCore is opened
only when Mario Kart Wii is launched from Ports; the standalone KartPad app is
never linked or executed inside NeoStation.
                       DESC
  s.homepage         = 'https://github.com/TarbleFR/neostation-ios'
  s.license          = { :type => 'GPL-3.0' }
  s.author           = { 'NeoStation iOS' => 'TarbleFR' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.public_header_files = 'Classes/KartPadInternalBridgePlugin.h'
  s.preserve_paths   = 'Frameworks/KartPadCore.framework'
  s.dependency 'Flutter'
  s.platform = :ios, '17.4'
  s.ios.deployment_target = '17.4'
  s.frameworks = 'UIKit', 'Foundation'
  s.libraries = 'c++'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++20',
    'OTHER_LDFLAGS' => '$(inherited) -ObjC'
  }
end
