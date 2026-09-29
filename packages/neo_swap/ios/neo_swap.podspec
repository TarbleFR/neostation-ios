Pod::Spec.new do |s|
  s.name = 'neo_swap'
  s.version = '0.1.0'
  s.summary = 'Shared opt-in file-backed CPU data allocator for NeoStation.'
  s.description = 'One host-process broker, explicit versioned C ABI, bounded disk reservations and diagnostics.'
  s.homepage = 'https://github.com/TarbleFR/neostation-ios'
  s.license = { :type => 'GPL-3.0' }
  s.author = { 'NeoStation iOS' => 'TarbleFR' }
  s.source = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.public_header_files = 'Classes/NeoSwap.h', 'Classes/NeoSwapPlugin.h'
  s.private_header_files = 'Classes/NeoSwapCapacityProbe.h'
  s.dependency 'Flutter'
  s.platform = :ios, '17.4'
  s.frameworks = 'Foundation'
  s.libraries = 'c++'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++20'
  }
end
