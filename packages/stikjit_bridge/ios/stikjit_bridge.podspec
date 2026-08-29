Pod::Spec.new do |s|
  s.name             = 'stikjit_bridge'
  s.version          = '0.0.1'
  s.summary          = 'Experimental NeoStation bridge for StikJIT.'
  s.description      = <<-DESC
Experimental iOS-only bridge allowing NeoStation to prepare StikJIT and enable JIT for MeloNX without routing through the StikDebug application.
                       DESC
  s.homepage         = 'https://github.com/TarbleFR/neostation-ios'
  s.license          = { :type => 'GPL-3.0' }
  s.author           = { 'NeoStation iOS' => 'TarbleFR' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.vendored_frameworks = 'Frameworks/StikJIT.xcframework'
  s.dependency 'Flutter'
  s.platform = :ios, '17.4'
  s.ios.deployment_target = '17.4'
  s.swift_version = '5.0'
  s.frameworks = 'JavaScriptCore', 'Network', 'Security', 'CFNetwork', 'SystemConfiguration', 'IOKit'
  s.libraries = 'z', 'bz2', 'iconv', 'compression'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES'
  }
end
