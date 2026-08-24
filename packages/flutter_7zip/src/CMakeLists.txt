# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

project(flutter_7zip_library VERSION 0.0.1 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)

set(SZ_BASE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/7zip/C")

include_directories(${SZ_BASE_DIR})

add_link_options("-Wl,--build-id=none")

add_library(flutter_7zip SHARED
        "${SZ_BASE_DIR}/7zAlloc.c"
        "${SZ_BASE_DIR}/7zArcIn.c"
        "${SZ_BASE_DIR}/7zBuf.c"
        "${SZ_BASE_DIR}/7zBuf2.c"
        "${SZ_BASE_DIR}/7zCrc.c"
        "${SZ_BASE_DIR}/7zCrcOpt.c"
        "${SZ_BASE_DIR}/7zDec.c"
        "${SZ_BASE_DIR}/7zFile.c"
        "${SZ_BASE_DIR}/7zStream.c"
        "${SZ_BASE_DIR}/Bcj2.c"
        "${SZ_BASE_DIR}/Bra.c"
        "${SZ_BASE_DIR}/Bra86.c"
        "${SZ_BASE_DIR}/Delta.c"
        "${SZ_BASE_DIR}/LzmaDec.c"
        "${SZ_BASE_DIR}/Lzma2Dec.c"
        "${SZ_BASE_DIR}/CpuArch.c"
        "flutter_7zip.cpp"
)

set_target_properties(flutter_7zip PROPERTIES
  PUBLIC_HEADER flutter_7zip.h
  OUTPUT_NAME "flutter_7zip"
)

target_compile_definitions(flutter_7zip PUBLIC DART_SHARED_LIB)

if (ANDROID)
  # Support Android 15 16k page size
  target_link_options(flutter_7zip PRIVATE "-Wl,-z,max-page-size=16384" "-Wl,-z,common-page-size=16384")
endif()
