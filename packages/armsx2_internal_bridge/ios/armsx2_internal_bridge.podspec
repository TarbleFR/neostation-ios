Pod::Spec.new do |s|
  s.name             = 'armsx2_internal_bridge'
  s.version          = '0.1.0'
  s.summary          = 'Lazy-loaded embedded ARMSX2 Core bridge for NeoStation iOS.'
  s.description      = <<-DESC
Loads ARMSX2Core.framework only after NeoStation's authenticated JIT helper has
attached to the NeoStation PID. No standalone ARMSX2 application is embedded.
                       DESC
  s.homepage         = 'https://github.com/TarbleFR/neostation-ios'
  s.license          = { :type => 'GPL-3.0' }
  s.author           = { 'NeoStation iOS' => 'TarbleFR' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '17.4'
  s.ios.deployment_target = '17.4'
  s.frameworks = 'UIKit', 'Foundation', 'Security'
  s.libraries = 'c++'
  s.preserve_paths = 'Frameworks/ARMSX2Core.framework'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++20',
    'OTHER_LDFLAGS' => '$(inherited) -ObjC'
  }
end
