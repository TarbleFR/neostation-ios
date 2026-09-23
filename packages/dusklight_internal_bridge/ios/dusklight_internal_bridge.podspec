Pod::Spec.new do |s|
  s.name             = 'dusklight_internal_bridge'
  s.version          = '0.1.0'
  s.summary          = 'Lazy-loaded in-process Dusklight Core bridge for NeoStation iOS.'
  s.description      = <<-DESC
Defines NeoStation's host-owned Dusklight session boundary. DusklightCore is
opened only when a Ports title is launched; no standalone Dusklight app is
linked into NeoStation at process startup.
                       DESC
  s.homepage         = 'https://github.com/AloneAgainstWorld/-neostation-ios'
  s.license          = { :type => 'GPL-3.0' }
  s.author           = { 'NeoStation iOS' => 'AloneAgainstWorld' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.public_header_files = 'Classes/DusklightInternalBridgePlugin.h'
  s.preserve_paths   = 'Frameworks/DusklightCore.framework'
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
