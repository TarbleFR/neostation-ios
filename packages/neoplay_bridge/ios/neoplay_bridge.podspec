Pod::Spec.new do |s|
  s.name = 'neoplay_bridge'
  s.version = '0.1.0'
  s.summary = 'NeoPlay local H.264/AAC streaming'
  s.description = 'Opt-in ReplayKit capture, bounded local transports and independent receiver sessions.'
  s.homepage = 'https://github.com/TarbleFR/neostation-ios'
  s.license = { :type => 'GPL-3.0-or-later', :file => '../../../LICENSE.md' }
  s.author = { 'NeoStation' => 'maintainers@neostation.invalid' }
  s.source = { :path => '.' }
  s.source_files = 'Classes/**/*.swift'
  s.dependency 'Flutter'
  s.dependency 'google-cast-sdk', '4.8.6'
  s.static_framework = true
  s.platform = :ios, '18.0'
  s.swift_version = '5.0'
  s.frameworks = 'ReplayKit', 'AVFoundation', 'CoreMedia', 'CoreImage', 'Network', 'UniformTypeIdentifiers', 'GameController'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'GCC_OPTIMIZATION_LEVEL' => 's' }
end
