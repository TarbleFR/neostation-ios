#!/usr/bin/env ruby
# Build upstream's actual griffin iOS graph as a hosted dylib.
require 'xcodeproj'
source = File.expand_path(ARGV.fetch(0))
path = File.join(source, 'pkg/apple/RetroArch_iOS11.xcodeproj')
project = Xcodeproj::Project.open(path)
target = project.targets.find { |t| t.name == 'RetroArchiOS11' }
raise 'Pinned iOS frontend target missing' unless target
project.targets.reject { |t| t == target }.each(&:remove_from_project)
target.name = 'RetroArchCore'
target.product_type = 'com.apple.product-type.library.dynamic'
target.product_reference.path = 'libRetroArchCore.dylib'
target.product_reference.explicit_file_type = 'compiled.mach-o.dylib'
# The dylib has no application resources, core-download scripts, UIApplication,
# code signing hooks or app packaging. Cores/resources are independently pinned.
target.build_phases.to_a.each do |phase|
  phase.remove_from_project if phase.is_a?(Xcodeproj::Project::Object::PBXResourcesBuildPhase) ||
    phase.is_a?(Xcodeproj::Project::Object::PBXShellScriptBuildPhase) ||
    phase.is_a?(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase)
end
adapter = project.main_group.new_group('NeoStation', '../../neostation')
['NeoRetroArchCore.m', 'NeoRetroArchNoJIT.c', 'NeoRetroArchStateImport.c'].each do |name|
  target.source_build_phase.add_file_reference(adapter.new_file(name))
end
# The pinned iOS11 project predates the WebDAV source addition: Cocoa lifecycle
# methods still reference this class even though hosted startup is disabled.
# Compile the tracked matching implementation, not a fetched dependency.
webdav = project.main_group.new_group('Pinned WebDAV', 'WebServer/GCDWebDAVServer')
target.source_build_phase.add_file_reference(webdav.new_file('GCDWebDAVServer.m'))
xml = project.frameworks_group.new_file('usr/lib/libxml2.tbd')
xml.source_tree = 'SDKROOT'
target.frameworks_build_phase.add_file_reference(xml)
['CoreHaptics','MetricKit'].each do |name|
  ref = project.frameworks_group.new_file("System/Library/Frameworks/#{name}.framework")
  ref.source_tree = 'SDKROOT'
  target.frameworks_build_phase.add_file_reference(ref)
end
# Do not leak tvOS SDK references into the iOS link step.
project.files.each do |ref|
  if ref.path&.include?('AppleTVOS') && ref.path&.end_with?('.framework')
    ref.path = "System/Library/Frameworks/#{File.basename(ref.path)}"
    ref.source_tree = 'SDKROOT'
  end
end
(project.build_configurations + target.build_configurations).each do |configuration|
  settings = configuration.build_settings
  settings.keys.grep(/OTHER_CFLAGS/).each do |key|
    flags = Array(settings[key])
    # GLES3 keeps GLES2 core contexts supported, but defining both feature
    # levels selects GLES3 SDK headers with GLES2-only OES enum branches in
    # gl2.c. Use the coherent GLES3 path needed by the reviewed N64 donor.
    flags.reject! { |f| %w[-DHAVE_ONLINE_UPDATER -DHAVE_UPDATE_ASSETS -DHAVE_UPDATE_CORES -DHAVE_NETWORKGAMEPAD -DHAVE_OPENGLES2].include?(f) }
    settings[key] = flags + ['-DHAVE_APPLE_STORE','-DHAVE_FRAMEWORKS','-DHAVE_OPENGLES3','-DHAVE_ZLIB','-DNEOSTATION_EMBEDDED_RETROARCH=1']
  end
  settings['OTHER_CFLAGS'] = Array(settings['OTHER_CFLAGS']) + ['-DHAVE_APPLE_STORE','-DHAVE_FRAMEWORKS','-DHAVE_OPENGLES3','-DHAVE_ZLIB','-DNEOSTATION_EMBEDDED_RETROARCH=1']
  # Keep existing upstream headers and include its repository-pinned WebDAV
  # directory, which is missing from the original iOS11 project's header map.
  settings['HEADER_SEARCH_PATHS'] = Array(settings['HEADER_SEARCH_PATHS']) + ['$(inherited)', '$(SRCROOT)/../..', '$(SRCROOT)/../../libretro-common/include',
    '$(SRCROOT)/../../deps/stb','$(SRCROOT)/../../deps/rcheevos/include','$(SRCROOT)/../../deps',
    '$(SRCROOT)', '$(SRCROOT)/../../neostation', '$(SRCROOT)/WebServer/GCDWebDAVServer',
    '$(SRCROOT)/WebServer/GCDWebUploader', '$(SRCROOT)/WebServer/GCDWebServer/Core',
    '$(SRCROOT)/WebServer/GCDWebServer/Requests', '$(SRCROOT)/WebServer/GCDWebServer/Responses',
    '$(SDKROOT)/usr/include/libxml2']
  settings['CLANG_ENABLE_OBJC_ARC'] = 'YES'
  settings['CLANG_CXX_LIBRARY'] = 'libc++'
  settings['GCC_C_LANGUAGE_STANDARD'] = 'gnu11'
  settings['ARCHS'] = 'arm64'
  settings['VALID_ARCHS'] = 'arm64'
  settings['ONLY_ACTIVE_ARCH'] = 'NO'
  settings['IPHONEOS_DEPLOYMENT_TARGET'] = '18.0'
  settings['SUPPORTED_PLATFORMS'] = 'iphoneos'
  settings['SDKROOT'] = 'iphoneos'
  settings['MACH_O_TYPE'] = 'mh_dylib'
  settings['PRODUCT_NAME'] = 'RetroArchCore'
  settings['EXECUTABLE_PREFIX'] = 'lib'
  settings['EXECUTABLE_EXTENSION'] = 'dylib'
  settings['DYLIB_INSTALL_NAME_BASE'] = '@rpath'
  settings['LD_DYLIB_INSTALL_NAME'] = '@rpath/libRetroArchCore.dylib'
  settings['EXPORTED_SYMBOLS_FILE'] = '$(SRCROOT)/../../neostation/exports.txt'
  settings['GCC_SYMBOLS_PRIVATE_EXTERN'] = 'YES'
  settings['DEAD_CODE_STRIPPING'] = 'YES'
  settings['CODE_SIGNING_ALLOWED'] = 'NO'
  settings['CODE_SIGNING_REQUIRED'] = 'NO'
  settings['SKIP_INSTALL'] = 'YES'
  %w[INFOPLIST_FILE GENERATE_INFOPLIST_FILE WRAPPER_EXTENSION ASSETCATALOG_COMPILER_APPICON_NAME
    ASSETCATALOG_COMPILER_LAUNCHIMAGE_NAME CODE_SIGN_RESOURCE_RULES_PATH DEVELOPMENT_TEAM
    PROVISIONING_PROFILE LD_NO_PIE].each { |key| settings.delete(key) }
end
project.save
# Inspect the saved Xcode graph too: conditional flags may otherwise override
# the generic setting and silently restore the contradictory GLES2 level.
saved = Xcodeproj::Project.open(path)
saved_target = saved.targets.find { |t| t.name == 'RetroArchCore' }
(saved.build_configurations + saved_target.build_configurations).each do |configuration|
  configuration.build_settings.keys.grep(/OTHER_CFLAGS/).each do |key|
    flags = Array(configuration.build_settings[key])
    raise "Contradictory GLES2 feature flag in #{configuration.name}/#{key}" if flags.include?('-DHAVE_OPENGLES2')
    raise "GLES3 feature flag missing in #{configuration.name}/#{key}" unless flags.include?('-DHAVE_OPENGLES3')
  end
end
puts "Configured #{path}: RetroArchCore arm64 iOS 18 dylib"
