#!/usr/bin/env python3
"""Prepare pinned KartPad/WiiCompiled iOS sources for NeoStation Core embedding.

The script never downloads or creates translated game code. It operates only on
a fresh source tree already staged by KartPad and fails closed if an expected
upstream marker changed.
"""
from __future__ import annotations

import argparse
from pathlib import Path


def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(
            f"ERROR: expected exactly one patch marker in {path}, found {count}"
        )
    path.write_text(text.replace(old, new, 1))


def patch_runtime_paths(runtime: Path) -> None:
    path = runtime / "include/runtime_config.h"
    replace_once(
        path,
        "#include <toml.hpp>\n#ifdef __APPLE__\n",
        """#include <toml.hpp>\n#if defined(__APPLE__)\nextern "C" const char* NeoKartPadEmbeddedSupportPath(void) __attribute__((weak_import));\nextern "C" const char* NeoKartPadEmbeddedCachePath(void) __attribute__((weak_import));\n#endif\n#ifdef __APPLE__\n""",
    )
    replace_once(
        path,
        "inline std::filesystem::path ApplicationDataDirectory() {\n",
        """inline std::filesystem::path ApplicationDataDirectory() {\n#if defined(__APPLE__)\n    if (NeoKartPadEmbeddedSupportPath) {\n        const char* value = NeoKartPadEmbeddedSupportPath();\n        if (value && *value) return std::filesystem::path(value);\n    }\n#endif\n""",
    )
    replace_once(
        path,
        "inline std::filesystem::path CacheDataDirectory() {\n",
        """inline std::filesystem::path CacheDataDirectory() {\n#if defined(__APPLE__)\n    if (NeoKartPadEmbeddedCachePath) {\n        const char* value = NeoKartPadEmbeddedCachePath();\n        if (value && *value) return std::filesystem::path(value);\n    }\n#endif\n""",
    )
    replace_once(
        path,
        """inline std::filesystem::path ResolveConfigPath() {\n    return ApplicationDataDirectory() / kConfigFileName;\n}\n""",
        """inline std::filesystem::path ResolveConfigPath() {\n#if defined(__APPLE__)\n    if (NeoKartPadEmbeddedSupportPath) {\n        const char* value = NeoKartPadEmbeddedSupportPath();\n        if (value && *value) {\n            return std::filesystem::path(value) / "Config" / kConfigFileName;\n        }\n    }\n#endif\n    return ApplicationDataDirectory() / kConfigFileName;\n}\n""",
    )


def patch_nand_paths(runtime: Path) -> None:
    path = runtime / "include/nand_path.h"
    replace_once(
        path,
        """inline std::filesystem::path ManagedNandRootPath() {\n    return RuntimeConfigFile::ApplicationDataDirectory() / "NAND";\n}\n""",
        """inline std::filesystem::path ManagedNandRootPath() {\n#if defined(__APPLE__)\n    if (NeoKartPadEmbeddedSupportPath) {\n        const char* value = NeoKartPadEmbeddedSupportPath();\n        if (value && *value) {\n            return std::filesystem::path(value) / "Saves" / "NAND";\n        }\n    }\n#endif\n    return RuntimeConfigFile::ApplicationDataDirectory() / "NAND";\n}\n""",
    )


def patch_sdl_pump(runtime: Path) -> None:
    path = runtime / "aurora-main/lib/window.cpp"
    replace_once(
        path,
        '#include "internal.hpp"\n',
        """#include "internal.hpp"\n#if defined(__APPLE__)\n#include <TargetConditionals.h>\n#if TARGET_OS_IOS\n#include <dispatch/dispatch.h>\n#include <pthread.h>\n#endif\n#endif\n""",
    )
    replace_once(
        path,
        """void pump_events() noexcept {\n  if (g_window != nullptr) {\n    SDL_SyncWindow(g_window);\n  }\n  SDL_PumpEvents();\n}\n""",
        """void pump_events() noexcept {\n#if defined(__APPLE__) && TARGET_OS_IOS\n  if (!pthread_main_np()) {\n    dispatch_sync_f(dispatch_get_main_queue(), nullptr, [](void*) {\n      if (g_window != nullptr) SDL_SyncWindow(g_window);\n      SDL_PumpEvents();\n    });\n    return;\n  }\n#endif\n  if (g_window != nullptr) SDL_SyncWindow(g_window);\n  SDL_PumpEvents();\n}\n""",
    )


def patch_first_frame(runtime: Path) -> None:
    path = runtime / "aurora-main/lib/aurora.cpp"
    replace_once(
        path,
        "// C API bindings\n",
        """// C API bindings\n#if defined(__APPLE__)\nextern "C" void NeoKartPadEmbeddedFramePresented(void) __attribute__((weak_import));\n#endif\n""",
    )
    replace_once(
        path,
        "void aurora_end_frame() { aurora::end_frame(); }\n",
        """void aurora_end_frame() {\n  aurora::end_frame();\n#if defined(__APPLE__)\n  if (NeoKartPadEmbeddedFramePresented) NeoKartPadEmbeddedFramePresented();\n#endif\n}\n\nextern "C" void NeoKartPadEmbeddedPresentationSuspend(void) {\n#ifdef AURORA_ENABLE_GX\n  aurora::wait_for_frame_worker();\n  aurora::window::set_surface_ready(false);\n  aurora::webgpu::release_surface();\n#endif\n}\n\nextern "C" int NeoKartPadEmbeddedPresentationResume(void) {\n#ifdef AURORA_ENABLE_GX\n  aurora::window::set_surface_ready(true);\n  return aurora::webgpu::refresh_surface(true) ? 1 : 0;\n#else\n  return 1;\n#endif\n}\n""",
    )


def patch_runtime_entry(runtime: Path) -> None:
    path = runtime / "src/main.cpp"
    replace_once(
        path,
        "#include <SDL3/SDL_messagebox.h>\n",
        "#include <SDL3/SDL_messagebox.h>\n#include <dispatch/dispatch.h>\n#include <pthread.h>\n",
    )
    marker = "void ServiceGuestTimingDuringAuroraFrameWait() {\n"
    helpers = """AuroraInfo NeoKartPadAuroraInitialize(AuroraConfig* config) {\n    if (pthread_main_np()) return aurora_initialize(0, nullptr, config);\n    struct Context { AuroraConfig* config; AuroraInfo result{}; } context{config};\n    dispatch_sync_f(dispatch_get_main_queue(), &context, [](void* raw) {\n        auto* ctx = static_cast<Context*>(raw);\n        ctx->result = aurora_initialize(0, nullptr, ctx->config);\n    });\n    return context.result;\n}\n\nvoid NeoKartPadAuroraShutdown() {\n    if (pthread_main_np()) { aurora_shutdown(); return; }\n    dispatch_sync_f(dispatch_get_main_queue(), nullptr, [](void*) { aurora_shutdown(); });\n}\n\n"""
    replace_once(path, marker, helpers + marker)
    replace_once(
        path,
        """        const std::string auroraUserPath = applicationDataDirectory.string();\n        const std::string auroraCachePath = rendererCacheDirectory.string();\n""",
        """#if defined(MKW_NEOSTATION_EMBEDDED_CORE)\n        const auto auroraUserDirectory = applicationDataDirectory / "Mods";\n        std::error_code auroraUserPathError;\n        std::filesystem::create_directories(auroraUserDirectory, auroraUserPathError);\n        const std::string auroraUserPath = auroraUserDirectory.string();\n#else\n        const std::string auroraUserPath = applicationDataDirectory.string();\n#endif\n        const std::string auroraCachePath = rendererCacheDirectory.string();\n""",
    )
    replace_once(
        path,
        "const AuroraInfo auroraInfo = aurora_initialize(0, nullptr, &auroraConfig);",
        "const AuroraInfo auroraInfo = NeoKartPadAuroraInitialize(&auroraConfig);",
    )
    text = path.read_text()
    text = text.replace("        aurora_shutdown();", "        NeoKartPadAuroraShutdown();")
    old_main = """int main(int argc, char** argv) {\n    return RuntimeMain(argc, argv);\n}\n"""
    new_main = """#if !defined(MKW_NEOSTATION_EMBEDDED_CORE)\nint main(int argc, char** argv) {\n    return RuntimeMain(argc, argv);\n}\n#else\nextern "C" int NeoKartPadRuntimeRunGuest(void) {\n    char name[] = "KartPadCore";\n    char* argv[] = {name, nullptr};\n    return RuntimeMain(1, argv);\n}\n#endif\n"""
    if old_main not in text:
        raise SystemExit(f"ERROR: runtime main marker changed in {path}")
    path.write_text(text.replace(old_main, new_main, 1))


def patch_product(runtime: Path) -> None:
    cmake = runtime / "CMakeLists.txt"
    replace_once(
        cmake,
        "set(MKW_PROJECT_COMPILE_DEFINITIONS NOMINMAX)\n",
        """set(MKW_PROJECT_COMPILE_DEFINITIONS NOMINMAX)\noption(MKW_NEOSTATION_EMBEDDED_CORE "Build KartPad as a NeoStation framework" OFF)\nset(MKW_NEOSTATION_CORE_SOURCE "" CACHE FILEPATH "NeoStation KartPad Core host source")\nif(MKW_NEOSTATION_EMBEDDED_CORE)\n  list(APPEND MKW_PROJECT_COMPILE_DEFINITIONS MKW_NEOSTATION_EMBEDDED_CORE=1)\n  if(NOT EXISTS "${MKW_NEOSTATION_CORE_SOURCE}")\n    message(FATAL_ERROR "MKW_NEOSTATION_CORE_SOURCE is required")\n  endif()\nendif()\n""",
    )

    products = runtime / "cmake/PublicProducts.cmake"
    replace_once(
        products,
        'add_executable(WiiCompiled "${MKW_BASE_PRODUCT_SOURCE}" ${MKW_BASE_REGISTRATION_SOURCES})\n',
        """if(MKW_NEOSTATION_EMBEDDED_CORE)\n  add_library(WiiCompiled SHARED\n      "${MKW_BASE_PRODUCT_SOURCE}" ${MKW_BASE_REGISTRATION_SOURCES}\n      "${MKW_NEOSTATION_CORE_SOURCE}")\nelse()\n  add_executable(WiiCompiled "${MKW_BASE_PRODUCT_SOURCE}" ${MKW_BASE_REGISTRATION_SOURCES})\nendif()\n""",
    )
    replace_once(
        products,
        """    target_sources(WiiCompiled PRIVATE ${MKW_KARTPAD_MOBILE_SOURCES}\n        "${MKW_KARTPAD_ICON_CATALOG}" "${MKW_KARTPAD_PRIVACY_MANIFEST}")\n""",
        """    if(MKW_NEOSTATION_EMBEDDED_CORE)\n      target_sources(WiiCompiled PRIVATE ${MKW_KARTPAD_MOBILE_SOURCES})\n    else()\n      target_sources(WiiCompiled PRIVATE ${MKW_KARTPAD_MOBILE_SOURCES}\n          "${MKW_KARTPAD_ICON_CATALOG}" "${MKW_KARTPAD_PRIVACY_MANIFEST}")\n    endif()\n""",
    )
    bundle = """    set_target_properties(WiiCompiled PROPERTIES\n        OUTPUT_NAME KartPad\n        MACOSX_BUNDLE TRUE\n        MACOSX_BUNDLE_INFO_PLIST "${MKW_KARTPAD_IOS_DIR}/RuntimeInfo.plist"\n        XCODE_ATTRIBUTE_ARCHS arm64\n        XCODE_ATTRIBUTE_ASSETCATALOG_COMPILER_APPICON_NAME AppIcon\n        XCODE_ATTRIBUTE_CLANG_CXX_LANGUAGE_STANDARD "c++20"\n        XCODE_ATTRIBUTE_CURRENT_PROJECT_VERSION 3\n        XCODE_ATTRIBUTE_GENERATE_INFOPLIST_FILE NO\n        XCODE_ATTRIBUTE_IPHONEOS_DEPLOYMENT_TARGET 16.0\n        XCODE_ATTRIBUTE_MARKETING_VERSION 0.2.0\n        XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER dev.kartpad.app\n        XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS "iphonesimulator iphoneos"\n        XCODE_ATTRIBUTE_SUPPORTS_MACCATALYST NO\n        XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1,2")\n"""
    framework = """    if(MKW_NEOSTATION_EMBEDDED_CORE)\n      target_compile_definitions(WiiCompiled PRIVATE MKW_NEOSTATION_EMBEDDED_CORE=1)\n      set_target_properties(WiiCompiled PROPERTIES\n          OUTPUT_NAME KartPadCore\n          FRAMEWORK TRUE\n          FRAMEWORK_VERSION A\n          MACOSX_FRAMEWORK_IDENTIFIER com.neogamelab.neostation.kartpadcore\n          XCODE_ATTRIBUTE_ARCHS arm64\n          XCODE_ATTRIBUTE_CLANG_CXX_LANGUAGE_STANDARD "c++20"\n          XCODE_ATTRIBUTE_IPHONEOS_DEPLOYMENT_TARGET 17.4\n          XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS iphoneos\n          XCODE_ATTRIBUTE_SUPPORTS_MACCATALYST NO\n          XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1,2")\n    else()\n""" + bundle + """    endif()\n"""
    replace_once(products, bundle, framework)


def patch_rvz_import(kartpad: Path) -> None:
    path = kartpad / "apple/ios/KartPadRuntimeOverlayHost.mm"
    replace_once(
        path,
        """  return [extension isEqualToString:@"wbfs"] ||
         [extension isEqualToString:@"iso"];
""",
        """  return [extension isEqualToString:@"wbfs"] ||
         [extension isEqualToString:@"iso"] ||
         [extension isEqualToString:@"rvz"];
""",
    )


def patch_overlay(kartpad: Path) -> None:
    path = kartpad / "apple/ios/KartPadRuntimeOverlayHost.mm"
    replace_once(
        path,
        "#include <atomic>\n",
        """#include <atomic>\nextern "C" const char* NeoKartPadEmbeddedSupportPath(void) __attribute__((weak_import));\nextern "C" const char* NeoKartPadEmbeddedGamePath(void) __attribute__((weak_import));\nextern "C" const char* NeoKartPadEmbeddedUIText(const char* key) __attribute__((weak_import));\nextern "C" void NeoKartPadEmbeddedPresentationSuspend(void) __attribute__((weak_import));\nextern "C" int NeoKartPadEmbeddedPresentationResume(void) __attribute__((weak_import));\nextern "C" int NeoKartPadEmbeddedShouldReturnToHost(void) __attribute__((weak_import));\nextern "C" void NeoKartPadEmbeddedSuspendGuestUntilResume(void) __attribute__((weak_import));\n""",
    )
    replace_once(
        path,
        """- (void)runMainMenu;\n""",
        """- (void)runMainMenu;\n- (void)setNeoStationSuspended:(BOOL)suspended;\n""",
    )
    replace_once(
        path,
        """NSString *KartPadSupportRoot() {\n  return [[NSHomeDirectory() stringByAppendingPathComponent:\n      @"Library/Application Support"] stringByAppendingPathComponent:@"KartPad"];\n}\n""",
        """NSString *NeoKartPadUIText(NSString *fallback, const char *key) {\n  if (NeoKartPadEmbeddedUIText) {\n    const char *value = NeoKartPadEmbeddedUIText(key);\n    if (value && *value) return [NSString stringWithUTF8String:value];\n  }\n  return fallback;\n}\n\nNSString *KartPadSupportRoot() {\n  if (NeoKartPadEmbeddedSupportPath) {\n    const char* root = NeoKartPadEmbeddedSupportPath();\n    if (root && *root) return [NSString stringWithUTF8String:root];\n  }\n  return [[NSHomeDirectory() stringByAppendingPathComponent:\n      @"Library/Application Support"] stringByAppendingPathComponent:@"KartPad"];\n}\n""",
    )
    replace_once(
        path,
        """extern "C" bool KartPadMobileEnsureGameDataAvailable() {\n  KartPadSystemDiagnosticsStart();\n""",
        """extern "C" bool KartPadMobileEnsureGameDataAvailable() {\n  KartPadSystemDiagnosticsStart();\n  if (NeoKartPadEmbeddedGamePath) {\n    if (KartPadInstalledGameDataIsValid()) return true;\n    const char* raw = NeoKartPadEmbeddedGamePath();\n    if (!raw || !*raw) return false;\n    NSError* error = KartPadPerformGameDataImport(\n        [NSURL fileURLWithPath:[NSString stringWithUTF8String:raw]], nil);\n    if (error) NSLog(@"[KartPad/NeoStation] import failed: %@", error);\n    return error == nil && KartPadInstalledGameDataIsValid();\n  }\n""",
    )

    run_marker = "- (void)runMainMenu {\n"
    suspend_method = """- (void)setNeoStationSuspended:(BOOL)suspended {\n  if (suspended) {\n    [(KartPadGameOverlay *)_overlay resetKartPadControlAppearance];\n    [[SunPadInputMixer sharedMixer] clearInputFromTouch:YES];\n    [[KartPadMotionSteering sharedSteering] stop];\n    AudioBackend::Instance().SetPausedForHost(true);\n    _window.hidden = YES;\n  } else {\n    [_window makeKeyAndVisible];\n    if (NeoKartPadEmbeddedPresentationResume &&\n        !NeoKartPadEmbeddedPresentationResume()) {\n      NSLog(@"[KartPad/NeoStation] presentation surface resume deferred");\n    }\n    [[SunPadInputMixer sharedMixer] clearInputFromTouch:YES];\n    [[KartPadMotionSteering sharedSteering] start];\n    AudioBackend::Instance().SetPausedForHost(false);\n  }\n}\n\n"""
    replace_once(path, run_marker, suspend_method + run_marker)

    old_service = """extern "C" void KartPadMobileServiceMainMenu() {\n  static BOOL previewShown=![NSProcessInfo.processInfo.environment[@"KARTPAD_UI_PREVIEW"] isEqualToString:@"report"];\n"""
    new_service = """extern "C" void KartPadMobileServiceMainMenu() {\n  if (NeoKartPadEmbeddedSuspendGuestUntilResume &&\n      (gKartPadMainMenuRequested ||\n       (NeoKartPadEmbeddedShouldReturnToHost && NeoKartPadEmbeddedShouldReturnToHost()))) {\n    gKartPadMainMenuRequested = NO;\n    if (NeoKartPadEmbeddedPresentationSuspend) {\n      NeoKartPadEmbeddedPresentationSuspend();\n    }\n    KartPadMobileSetHostSuspended(1);\n    NeoKartPadEmbeddedSuspendGuestUntilResume();\n    KartPadMobileSetHostSuspended(0);\n    return;\n  }\n  static BOOL previewShown=![NSProcessInfo.processInfo.environment[@"KARTPAD_UI_PREVIEW"] isEqualToString:@"report"];\n"""
    replace_once(path, old_service, new_service)

    old_install = """extern "C" void KartPadMobileRuntimeHostInstall(void *sdlWindow) {\n  if (sdlWindow == nullptr || !NSThread.isMainThread) {\n    NSLog(@"[KartPad] refusing overlay installation away from UIKit's main thread");\n    return;\n  }\n  [gRuntimeOverlayHost uninstall];\n  gRuntimeOverlayHost =\n      [[KartPadRuntimeOverlayHost alloc] initWithSDLWindow:(SDL_Window *)sdlWindow];\n}\n\nextern "C" void KartPadMobileRuntimeHostUninstall() {\n  [gRuntimeOverlayHost uninstall];\n  gRuntimeOverlayHost = nil;\n}\n"""
    new_install = """extern "C" void KartPadMobileRuntimeHostInstall(void *sdlWindow) {\n  if (sdlWindow == nullptr) return;\n  void (^work)(void) = ^{\n    [gRuntimeOverlayHost uninstall];\n    gRuntimeOverlayHost = [[KartPadRuntimeOverlayHost alloc]\n        initWithSDLWindow:(SDL_Window *)sdlWindow];\n  };\n  if (NSThread.isMainThread) work();\n  else dispatch_sync(dispatch_get_main_queue(), work);\n}\n\nextern "C" void KartPadMobileRuntimeHostUninstall() {\n  void (^work)(void) = ^{ [gRuntimeOverlayHost uninstall]; gRuntimeOverlayHost = nil; };\n  if (NSThread.isMainThread) work();\n  else dispatch_sync(dispatch_get_main_queue(), work);\n}\n\nextern "C" void KartPadMobileSetHostSuspended(int suspended) {\n  void (^work)(void) = ^{\n    [gRuntimeOverlayHost setNeoStationSuspended:(suspended != 0)];\n  };\n  if (NSThread.isMainThread) work();\n  else dispatch_sync(dispatch_get_main_queue(), work);\n}\n"""
    replace_once(path, old_install, new_install)
    text = path.read_text()
    text = text.replace(
        'actionWithTitle:@"Return to KartPad Menu"',
        'actionWithTitle:NeoKartPadUIText(@"Return to NeoStation", "returnToLibrary")',
    )
    path.write_text(text)


def patch_auxiliary_support_root(path: Path) -> None:
    text = path.read_text()
    if "NeoKartPadEmbeddedSupportPath" in text:
        return
    first_include_end = max(text.find("\n\n"), 0)
    text = (
        text[:first_include_end]
        + '\nextern "C" const char* NeoKartPadEmbeddedSupportPath(void) __attribute__((weak_import));'
        + text[first_include_end:]
    )
    old = """return [[NSHomeDirectory() stringByAppendingPathComponent:\n      @"Library/Application Support"] stringByAppendingPathComponent:@"KartPad"];"""
    if old in text:
        new = """if (NeoKartPadEmbeddedSupportPath) {\n    const char* root = NeoKartPadEmbeddedSupportPath();\n    if (root && *root) return [NSString stringWithUTF8String:root];\n  }\n  """ + old
        text = text.replace(old, new, 1)
    path.write_text(text)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("runtime_source", type=Path)
    parser.add_argument("kartpad_source", type=Path)
    parser.add_argument("core_source", type=Path)
    args = parser.parse_args()

    required = (
        args.runtime_source / "CMakeLists.txt",
        args.runtime_source / "src/main.cpp",
        args.runtime_source / "cmake/PublicProducts.cmake",
        args.kartpad_source / "apple/ios/KartPadRuntimeOverlayHost.mm",
        args.core_source,
    )
    for item in required:
        if not item.exists():
            parser.error(f"missing required source: {item}")

    patch_runtime_paths(args.runtime_source)
    patch_nand_paths(args.runtime_source)
    patch_sdl_pump(args.runtime_source)
    patch_first_frame(args.runtime_source)
    patch_runtime_entry(args.runtime_source)
    patch_product(args.runtime_source)
    patch_rvz_import(args.kartpad_source)
    patch_overlay(args.kartpad_source)
    patch_auxiliary_support_root(
        args.kartpad_source / "apple/shared/KartPadMiiManager.mm"
    )
    patch_auxiliary_support_root(
        args.kartpad_source / "apple/ios/KartPadRetroRewindInstaller.mm"
    )
    print("Prepared KartPad source for NeoStation embedded Core mode.")


if __name__ == "__main__":
    main()
