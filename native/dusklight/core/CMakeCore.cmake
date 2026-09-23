# Compiled into a private, lazily dlopen'ed framework; never aurora::main.
target_sources(dusklight PRIVATE neostation/NeoDusklightCore.mm)
set_source_files_properties(neostation/NeoDusklightCore.mm PROPERTIES COMPILE_FLAGS "-fobjc-arc")
target_include_directories(dusklight PRIVATE "${CMAKE_SOURCE_DIR}/neostation")
target_link_libraries(dusklight PRIVATE "-framework UIKit" "-framework Foundation")
target_link_options(dusklight PRIVATE
    "-Wl,-exported_symbols_list,${CMAKE_SOURCE_DIR}/neostation/exports.txt")
set_target_properties(dusklight PROPERTIES
    FRAMEWORK TRUE
    FRAMEWORK_VERSION A
    OUTPUT_NAME DusklightCore
    MACOSX_FRAMEWORK_IDENTIFIER fr.neostation.DusklightCore
    MACOSX_FRAMEWORK_BUNDLE_VERSION 1
    MACOSX_FRAMEWORK_SHORT_VERSION_STRING 1.0
    XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED NO
    XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED NO
    INSTALL_NAME_DIR "@rpath"
    BUILD_WITH_INSTALL_NAME_DIR TRUE)
add_custom_command(TARGET dusklight POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        "${CMAKE_SOURCE_DIR}/res" "$<TARGET_BUNDLE_DIR:dusklight>/res"
    VERBATIM)
