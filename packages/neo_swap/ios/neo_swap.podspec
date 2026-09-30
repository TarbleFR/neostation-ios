Pod::Spec.new do |s|
  s.name = 'neo_swap'
  s.version = '0.1.0'
  s.summary = 'Shared CPU data allocator and experimental memory donor for NeoStation.'
  s.description = 'One host broker, immutable C ABI, verified helper-owned shared memory, bounded file fallback and diagnostics.'
  s.homepage = 'https://github.com/TarbleFR/neostation-ios'
  s.license = { :type => 'GPL-3.0' }
  s.author = { 'NeoStation iOS' => 'TarbleFR' }
  s.source = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.public_header_files = 'Classes/NeoSwap.h', 'Classes/NeoSwapPlugin.h', 'Classes/NeoSwapHost.h', 'Classes/NeoSwapClientStats.h', 'Classes/NeoSwapRelay.h', 'Classes/NeoSwapRelayService.h'
  s.private_header_files = 'Classes/NeoSwapCapacityProbe.h', 'Classes/Donation/*.h', 'Classes/Relay/*.h'
  s.exclude_files = 'Classes/Donation/NeoSwapDonorRequestHandler.h'
  s.dependency 'Flutter'
  s.platform = :ios, '17.4'
  s.frameworks = 'Foundation'
  s.libraries = 'c++'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++20',
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) NEOSWAP_DONATION=1 NEOSWAP_RELAY=1'
  }
end
