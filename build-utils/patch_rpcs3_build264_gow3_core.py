#!/usr/bin/env python3
"""Build 264: harden ARM64 RSX waits and enable RPCS3-only ThinLTO."""

from __future__ import annotations

import sys
from pathlib import Path


MARKER = "NEOSTATION_BUILD264_GOW3_ARM64_LTO_V1"


def replace_once(text: str, old: str, new: str, description: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{description}: expected one source anchor, found {count}")
    return text.replace(old, new, 1)


def patch_rsx_semaphore(source: Path) -> None:
    path = source / "rpcs3/Emu/RSX/NV47/HW/nv406e.cpp"
    text = path.read_text()
    if MARKER in text:
        return

    text = replace_once(
        text,
        "// NEOSTATION_BUILD258_RUNTIME_RESILIENCE_V1\n",
        "// NEOSTATION_BUILD258_RUNTIME_RESILIENCE_V1\n"
        f"// {MARKER}\n",
        "Build 264 RSX marker",
    )

    old = """\t\t\tconst auto& sema = vm::_ref<RsxSemaphore>(addr);
\t\t\tconst auto& atomic_sema = vm::_ref<atomic_t<RsxSemaphore>>(addr);

\t\t\tif (sema == arg)
\t\t\t{
\t\t\t\t// Flip semaphore doesnt need wake-up delay
\t\t\t\tif (addr != RSX(ctx)->label_addr + 0x10)
\t\t\t\t{
\t\t\t\t\tRSX(ctx)->flush_fifo();
\t\t\t\t\tRSX(ctx)->fifo_wake_delay(2);
\t\t\t\t}

\t\t\t\treturn;
\t\t\t}
\t\t\telse
\t\t\t{
\t\t\t\tRSX(ctx)->flush_fifo();
\t\t\t}

\t\t\tu64 start = get_system_time();
\t\t\tu64 last_check_val = start;
\t\t\tbool timed_out = false;

\t\t\twhile (sema != arg)
\t\t\t{
\t\t\t\tif (RSX(ctx)->test_stopped())
\t\t\t\t{
\t\t\t\t\tRSX(ctx)->state += cpu_flag::again;
\t\t\t\t\treturn;
\t\t\t\t}

\t\t\t\tif (const auto tdr = static_cast<u64>(g_cfg.video.driver_recovery_timeout))
\t\t\t\t{
\t\t\t\t\tconst u64 current = get_system_time();

\t\t\t\t\tif (current - last_check_val > 20'000)
\t\t\t\t\t{
\t\t\t\t\t\t// Suspicious amnount of time has passed
\t\t\t\t\t\t// External pause such as debuggers' pause or operating system sleep may have taken place
\t\t\t\t\t\t// Ignore it
\t\t\t\t\t\tstart += current - last_check_val;
\t\t\t\t\t}

\t\t\t\t\tlast_check_val = current;

\t\t\t\t\tif ((current - start) > tdr)
\t\t\t\t\t{
\t\t\t\t\t\t// Keep RPCS3's recovery semantics: report the stale label and
\t\t\t\t\t\t// leave the wait after the configured deadline. Never forge the
\t\t\t\t\t\t// guest semaphore value to hide the synchronization fault.
\t\t\t\t\t\ttimed_out = true;
\t\t\t\t\t\trsx_log.error(
\t\t\t\t\t\t\t"nv406e::semaphore_acquire timed out: address=0x%X expected=0x%X observed=0x%X waited_us=%llu",
\t\t\t\t\t\t\taddr, arg, static_cast<u32>(sema), current - start);
\t\t\t\t\t\tbreak;
\t\t\t\t\t}
\t\t\t\t}

\t\t\t\tif (RSX(ctx)->external_interrupt_lock ||
\t\t\t\t\t(RSX(ctx)->state & (cpu_flag::dbg_global_pause + cpu_flag::exit)) == cpu_flag::dbg_global_pause)
\t\t\t\t{
\t\t\t\t\tRSX(ctx)->cpu_wait({});
\t\t\t\t\tcontinue;
\t\t\t\t}

\t\t\t\tRSX(ctx)->on_semaphore_acquire_wait();

\t\t\t\t// Wait until the value changes or until 100us pass.
\t\t\t\tutils::spin_on_cacheline_once(atomic_sema, sema, 100);
\t\t\t}
"""
    new = """\t\t\tconst auto& atomic_sema = vm::_ref<atomic_t<RsxSemaphore>>(addr);
\t\t\tRsxSemaphore observed = atomic_sema.load();

\t\t\t// ARM64 must observe guest label writes with acquire semantics. Reading
\t\t\t// through a non-atomic alias can keep an old value in the hot loop even
\t\t\t// after another guest thread has released the next label.
\t\t\tif (observed == arg)
\t\t\t{
\t\t\t\t// Flip semaphore doesnt need wake-up delay
\t\t\t\tif (addr != RSX(ctx)->label_addr + 0x10)
\t\t\t\t{
\t\t\t\t\tRSX(ctx)->flush_fifo();
\t\t\t\t\tRSX(ctx)->fifo_wake_delay(2);
\t\t\t\t}

\t\t\t\treturn;
\t\t\t}

\t\t\tRSX(ctx)->flush_fifo();

\t\t\tconst u64 wait_started = get_system_time();
\t\t\tu64 progress_started = wait_started;
\t\t\tu64 last_check_val = wait_started;
\t\t\tbool recovery_attempted = false;
\t\t\tbool timed_out = false;

\t\t\twhile (observed != arg)
\t\t\t{
\t\t\t\tif (RSX(ctx)->test_stopped())
\t\t\t\t{
\t\t\t\t\tRSX(ctx)->state += cpu_flag::again;
\t\t\t\t\treturn;
\t\t\t\t}

\t\t\t\tif (const auto tdr = static_cast<u64>(g_cfg.video.driver_recovery_timeout))
\t\t\t\t{
\t\t\t\t\tconst u64 current = get_system_time();
\t\t\t\t\tconst RsxSemaphore refreshed = atomic_sema.load();

\t\t\t\t\tif (refreshed != observed)
\t\t\t\t\t{
\t\t\t\t\t\t// A changing label is delayed, not dead. Give the producer a new
\t\t\t\t\t\t// recovery window instead of advancing RSX one value behind.
\t\t\t\t\t\tobserved = refreshed;
\t\t\t\t\t\tprogress_started = current;
\t\t\t\t\t\tlast_check_val = current;
\t\t\t\t\t\tcontinue;
\t\t\t\t\t}

\t\t\t\t\tif (current - last_check_val > 20'000)
\t\t\t\t\t{
\t\t\t\t\t\t// Ignore debugger, OS sleep and scheduling pauses when measuring
\t\t\t\t\t\t// a no-progress interval.
\t\t\t\t\t\tprogress_started += current - last_check_val;
\t\t\t\t\t}

\t\t\t\t\tlast_check_val = current;

\t\t\t\t\tif ((current - progress_started) > tdr)
\t\t\t\t\t{
#ifdef RPCS3_IOS
\t\t\t\t\t\tif (!recovery_attempted)
\t\t\t\t\t\t{
\t\t\t\t\t\t\trecovery_attempted = true;
\t\t\t\t\t\t\trsx_log.warning(
\t\t\t\t\t\t\t\t"nv406e::semaphore_acquire stalled; forcing one bounded RSX synchronization: address=0x%X expected=0x%X observed=0x%X",
\t\t\t\t\t\t\t\taddr, arg, static_cast<u32>(observed));
\t\t\t\t\t\t\tRSX(ctx)->sync_point_request.release(true);
\t\t\t\t\t\t\tRSX(ctx)->on_semaphore_acquire_wait();
\t\t\t\t\t\t\tRSX(ctx)->sync();
\t\t\t\t\t\t\tRSX(ctx)->flush_fifo();
\t\t\t\t\t\t\tobserved = atomic_sema.load();
\t\t\t\t\t\t\tprogress_started = get_system_time();
\t\t\t\t\t\t\tlast_check_val = progress_started;
\t\t\t\t\t\t\tcontinue;
\t\t\t\t\t\t}
#endif
\t\t\t\t\t\ttimed_out = true;
\t\t\t\t\t\trsx_log.error(
\t\t\t\t\t\t\t"nv406e::semaphore_acquire timed out: address=0x%X expected=0x%X observed=0x%X waited_us=%llu",
\t\t\t\t\t\t\taddr, arg, static_cast<u32>(observed), current - wait_started);
\t\t\t\t\t\tbreak;
\t\t\t\t\t}
\t\t\t\t}

\t\t\t\tif (RSX(ctx)->external_interrupt_lock ||
\t\t\t\t\t(RSX(ctx)->state & (cpu_flag::dbg_global_pause + cpu_flag::exit)) == cpu_flag::dbg_global_pause)
\t\t\t\t{
\t\t\t\t\tRSX(ctx)->cpu_wait({});
\t\t\t\t\tobserved = atomic_sema.load();
\t\t\t\t\tcontinue;
\t\t\t\t}

\t\t\t\tRSX(ctx)->on_semaphore_acquire_wait();

\t\t\t\t// WFE monitors the atomic cache line; reload with acquire ordering
\t\t\t\t// after every wake before testing the guest-visible value again.
\t\t\t\tutils::spin_on_cacheline_once(atomic_sema, observed, 100);
\t\t\t\tobserved = atomic_sema.load();
\t\t\t}
"""
    text = replace_once(text, old, new, "progress-aware ARM64 semaphore wait")
    text = replace_once(
        text,
        "\t\t\tconst u64 waited = get_system_time() - start;\n",
        "\t\t\tconst u64 waited = get_system_time() - wait_started;\n",
        "total semaphore wait accounting",
    )
    path.write_text(text)


def patch_selective_thinlto(source: Path) -> None:
    root = source / "CMakeLists.txt"
    text = root.read_text()
    if "RPCS3_IOS_SELECTIVE_THINLTO" not in text:
        text = replace_once(
            text,
            'option(USE_LTO "Use LTO for building" ON)\n',
            'option(USE_LTO "Use LTO for building" ON)\n'
            'option(RPCS3_IOS_SELECTIVE_THINLTO '
            '"Use ThinLTO only for the embedded RPCS3 iOS targets" OFF)\n',
            "selective ThinLTO option",
        )
        root.write_text(text)

    emu = source / "rpcs3/Emu/CMakeLists.txt"
    text = emu.read_text()
    if MARKER not in text:
        anchor = """if(USE_LTO)
    set_target_properties(rpcs3_emu PROPERTIES INTERPROCEDURAL_OPTIMIZATION ON)
endif()
"""
        addition = f"""if(USE_LTO)
    set_target_properties(rpcs3_emu PROPERTIES INTERPROCEDURAL_OPTIMIZATION ON)
endif()

# {MARKER}: keep LLVM and all third-party dependencies as normal objects. Only
# NeoStation's emulator archive carries ThinLTO bitcode into the final iOS Core.
if(RPCS3_FRONTEND STREQUAL "IOS" AND RPCS3_IOS_SELECTIVE_THINLTO)
    target_compile_options(rpcs3_emu PRIVATE "$<$<CONFIG:Release>:-flto=thin>")
    target_compile_definitions(rpcs3_emu PRIVATE NEOSTATION_SELECTIVE_THINLTO=1)
endif()
"""
        emu.write_text(replace_once(text, anchor, addition, "RPCS3 emulator ThinLTO"))

    core = source / "rpcs3/CMakeLists.txt"
    text = core.read_text()
    if MARKER not in text:
        anchor = """    target_compile_definitions(RPCS3Core PRIVATE
        RPCS3_IOS_CORE_BUILD=1
        "$<TARGET_PROPERTY:3rdparty_zlib,INTERFACE_COMPILE_DEFINITIONS>"
    )
"""
        addition = f"""    target_compile_definitions(RPCS3Core PRIVATE
        RPCS3_IOS_CORE_BUILD=1
        "$<TARGET_PROPERTY:3rdparty_zlib,INTERFACE_COMPILE_DEFINITIONS>"
    )

    # {MARKER}: complete ThinLTO only at RPCS3Core's final link. Applying these
    # flags to targets rather than globally deliberately excludes LLVM,
    # FFmpeg, MoltenVK and every other third-party dependency.
    if(RPCS3_IOS_SELECTIVE_THINLTO)
        target_compile_options(RPCS3Core PRIVATE "$<$<CONFIG:Release>:-flto=thin>")
        target_link_options(RPCS3Core PRIVATE "$<$<CONFIG:Release>:-flto=thin>")
        target_compile_definitions(RPCS3Core PRIVATE NEOSTATION_SELECTIVE_THINLTO=1)
    endif()
"""
        core.write_text(replace_once(text, anchor, addition, "RPCS3 Core ThinLTO"))


def patch_build_info(source: Path) -> None:
    path = source / "rpcs3/ios/RPCS3IOS.cpp"
    text = path.read_text()
    if MARKER in text:
        return
    old = '\\"performance\\":\\"fps-cpu-rsx-memory\\"'
    new = (
        f'\\"build264\\":\\"{MARKER}\\",'
        '\\"lto\\":\\"thin-rpcs3-core-only\\",'
        '\\"performance\\":\\"fps-cpu-rsx-memory\\"'
    )
    path.write_text(replace_once(text, old, new, "Build 264 Core metadata"))


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch_rpcs3_build264_gow3_core.py <rpcs3-source-root>")
    source = Path(sys.argv[1]).resolve()
    patch_rsx_semaphore(source)
    patch_selective_thinlto(source)
    patch_build_info(source)
    print("RPCS3 Build 264 God of War ARM64/ThinLTO patch: OK")


if __name__ == "__main__":
    main()
