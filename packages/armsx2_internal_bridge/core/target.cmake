# SPDX-License-Identifier: GPL-3.0-or-later
if(NOT NEO_ARMSX2_ADAPTER_DIR OR NOT NEO_ARMSX2_SOURCE_REVISION)
  message(FATAL_ERROR "NeoStation adapter and pinned source revision are required")
endif()
add_library(ARMSX2Core SHARED
  ios_main.mm IOS/GamepadHaptics.mm IOS/HostImpls.mm IOS/PlaySoundAsync.mm
  ARMSX2Bridge.mm "${NEO_ARMSX2_ADAPTER_DIR}/core/ARMSX2Core.mm")
# IOSRuntime.h only forward-declares ARMSX2GameView. The embedded render-window
# adapter converts it to UIView, which requires the actual superclass declaration.
# Keep this source-specific: no cast and no change to other engines or upstream UI.
set_property(SOURCE IOS/HostImpls.mm APPEND PROPERTY COMPILE_OPTIONS
  "-include" "${CMAKE_CURRENT_SOURCE_DIR}/IOS/ARMSX2GameView.h")
# Upstream disables exceptions globally. Only the owned adapter worker uses
# exceptions, catches them before returning, and never unwinds across the ABI.
set_property(SOURCE "${NEO_ARMSX2_ADAPTER_DIR}/core/ARMSX2Core.mm"
  APPEND PROPERTY COMPILE_OPTIONS "-fexceptions")
set_target_properties(ARMSX2Core PROPERTIES
  FRAMEWORK TRUE FRAMEWORK_VERSION A OUTPUT_NAME ARMSX2Core
  MACOSX_FRAMEWORK_IDENTIFIER com.neogamelab.neostation.ARMSX2Core
  XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER com.neogamelab.neostation.ARMSX2Core
  XCODE_ATTRIBUTE_IPHONEOS_DEPLOYMENT_TARGET 17.4
  XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED NO
  XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED NO
  XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC NO
  XCODE_ATTRIBUTE_CLANG_ENABLE_MODULES YES
  XCODE_ATTRIBUTE_MTL_HEADER_SEARCH_PATHS "${ARMSX2_ROOT}/pcsx2/GS/Renderers/Metal ${ARMSX2_ROOT}/3rdparty/include"
  BUILD_WITH_INSTALL_NAME_DIR TRUE INSTALL_NAME_DIR "@rpath")
target_compile_definitions(ARMSX2Core PRIVATE PCSX2_NO_PCAP=1
  NEO_ARMSX2_SOURCE_REVISION="${NEO_ARMSX2_SOURCE_REVISION}")
target_compile_options(ARMSX2Core PRIVATE -fno-objc-arc)
target_include_directories(ARMSX2Core PRIVATE "${NEO_ARMSX2_ADAPTER_DIR}/ios/Classes")
target_link_libraries(ARMSX2Core PRIVATE PCSX2 SDL3::SDL3
  "-framework UIKit" "-framework AVFoundation" "-framework Metal"
  "-framework MetalKit" "-framework QuartzCore" "-framework CoreText"
  "-framework CoreGraphics" "-framework ImageIO" "-framework GameController"
  "-framework CoreHaptics" "-framework OpenGLES")
target_link_options(ARMSX2Core PRIVATE
  "LINKER:-exported_symbols_list,${NEO_ARMSX2_ADAPTER_DIR}/core/exports.txt")
	target_include_directories(ARMSX2Core PRIVATE
		${CMAKE_CURRENT_BINARY_DIR}
		${CMAKE_SOURCE_DIR}
		${ARMSX2_ROOT}
		${ARMSX2_ROOT}/common
		${ARMSX2_ROOT}/pcsx2
		${ARMSX2_ROOT}/pcsx2/GS/Renderers/Metal
		${ARMSX2_ROOT}/3rdparty/SDL3/include
		${ARMSX2_ROOT}/3rdparty/fmt/include
		${ARMSX2_ROOT}/3rdparty/fast_float/include
		${ARMSX2_ROOT}/3rdparty/vixl/include
		${ARMSX2_ROOT}/3rdparty/include
		${ARMSX2_ROOT}/3rdparty/vulkan/include
		${ARMSX2_ROOT}/3rdparty/glslang/glslang
		${ARMSX2_ROOT}/3rdparty/glslang/include
		${CMAKE_BINARY_DIR}/common/include
		${CMAKE_BINARY_DIR}/pcsx2
		${ARMSX2_ROOT}/3rdparty/simpleini/include
		${ARMSX2_ROOT}/3rdparty/imgui/include
		${ARMSX2_ROOT}/3rdparty/rapidyaml/include
		${ARMSX2_ROOT}/3rdparty/cpuinfo/include
		${ARMSX2_ROOT}/3rdparty/libchdr/include
		${ARMSX2_ROOT}/3rdparty/libzip/lib
		${CMAKE_BINARY_DIR}/3rdparty/libzip
		${ARMSX2_ROOT}/3rdparty/cubeb/include
		${ARMSX2_ROOT}/3rdparty/rcheevos/include
		${ARMSX2_ROOT}/3rdparty/freesurround/include
		${ARMSX2_ROOT}/3rdparty/freetype/include
		${ARMSX2_ROOT}/3rdparty/plutosvg1/source
		${ARMSX2_ROOT}/3rdparty/plutosvg1/plutovg/include
		${CMAKE_BINARY_DIR}/3rdparty/freetype/include
		${ARMSX2_ROOT}/3rdparty/soundtouch/soundtouch
		${ARMSX2_ROOT}/3rdparty/lz4/lz4/lib
		${ARMSX2_ROOT}/3rdparty/lzma/include
		${ARMSX2_ROOT}/3rdparty/zstd/zstd/lib
		${ARMSX2_ROOT}/3rdparty/demangler/include
		${ARMSX2_ROOT}/3rdparty/ccc/src
		${CMAKE_BINARY_DIR}/3rdparty/SDL3/include-revision
	)

file(GLOB METAL_SHADERS "${ARMSX2_ROOT}/pcsx2/GS/Renderers/Metal/*.metal")
target_sources(ARMSX2Core PRIVATE ${METAL_SHADERS})
set_source_files_properties(${METAL_SHADERS} PROPERTIES
  XCODE_EXPLICIT_FILE_TYPE sourcecode.metal MACOSX_PACKAGE_LOCATION Resources)
# Core resource paths are explicit: never borrow another engine's default.metallib.
file(GLOB_RECURSE CORE_RESOURCES "${ARMSX2_ROOT}/bin/resources/*")
foreach(resource IN LISTS CORE_RESOURCES)
  if(resource MATCHES "/shaders/dx11/")
    continue()
  endif()
  get_filename_component(directory "${resource}" DIRECTORY)
  file(RELATIVE_PATH relative "${ARMSX2_ROOT}/bin/resources" "${directory}")
  target_sources(ARMSX2Core PRIVATE "${resource}")
  set_source_files_properties("${resource}" PROPERTIES MACOSX_PACKAGE_LOCATION "Resources/${relative}")
endforeach()
foreach(resource
    "${ARMSX2_ROOT}/bin/resources-overlay/armsx2_overrides.yaml"
    "${CMAKE_SOURCE_DIR}/../assets/resources/patches.zip")
  target_sources(ARMSX2Core PRIVATE "${resource}")
  set_source_files_properties("${resource}" PROPERTIES MACOSX_PACKAGE_LOCATION Resources)
endforeach()
