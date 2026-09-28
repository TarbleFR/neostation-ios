#!/usr/bin/env python3
"""Static contract for the selective XITRIX Preview 0.10 Core import."""
from pathlib import Path
import sys

root = Path(sys.argv[1]).resolve()

def text(rel):
    p = root / rel
    assert p.is_file(), f"missing {rel}"
    return p.read_text(errors="strict")

def require(rel, *needles):
    data = text(rel)
    for needle in needles:
        assert needle in data, f"{rel}: missing {needle!r}"

# ARM64/SPU codegen and weak-memory ordering.
require("rpcs3/Emu/Cell/SPUARM64Lowering.h",
        "fold_byte_reversals", "fold_single_source_tables")
require("rpcs3/Emu/Cell/SPUARM64CompareLowering.h",
        "fold_wide_comparison_reversals")
require("rpcs3/Emu/Cell/SPULLVMRecompiler.cpp",
        "fold_byte_reversals(f)", "fold_single_source_tables(f)",
        "fold_wide_comparison_reversals(f)", "check_state_with_interrupts")
require("rpcs3/Emu/Cell/SPUThread.cpp",
        "static FORCE_INLINE bool rdata_fence()",
        "struct spu_dec_intr_timer",
        "check_state_with_interrupts",
        "aarch64::spu_scan16_rdata")
require("rpcs3/Emu/CPU/Backends/AArch64/SPUReservationHash.h",
        "spu_rdata_hash32")

# PPU fixes must coexist with NeoStation's memory-safe compile budget.
require("rpcs3/Emu/Cell/PPUThread.cpp",
        "get_ppu_module_file_budget", "arithmetic_codegen_v4")
require("rpcs3/Emu/Cell/PPUTranslator.cpp",
        "CreateSExt", "CreateSDiv")

# Savestate stack pages keep their 4K mapping on restore.
vm = text("rpcs3/Emu/Memory/vm.cpp")
assert "else if (flags & page_size_4k)" in vm
assert "pflags |= page_size_4k;" in vm
require("rpcs3/Emu/Memory/VMReservationRange.h",
        "reservation_range_overlaps",
        "shared_memory(point >> (16 - 7)) == 0")

# RSX / MoltenVK / Metal paths.
require("rpcs3/Emu/CMakeLists.txt", "RSX/VK/vkutils/metal_event.mm")
require("rpcs3/ios/IOSGPUEventWait.h", "wait_for_gpu_event")
require("rpcs3/Emu/RSX/VK/VKQueryPool.h", "query_slot_queue")
require("rpcs3/Emu/RSX/Common/sampler_invalidation.h", "invalidate_sampler_context")
require("rpcs3/Emu/RSX/VK/upscalers/fsr1/fsr_pass.cpp",
        "VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT",
        "VK_FORMAT_R8G8B8A8_UNORM")
require("rpcs3/Emu/RSX/Program/GLSLSnippets/GPUDeswizzle.glsl",
        "invocation.size.z")

# iOS audio recovery / tempo smoothing.
require("rpcs3/ios/IOSAudioRecovery.h", "class stereo_fader final")
require("rpcs3/ios/IOSAudioTempo.h", "class tempo_controller final")
require("rpcs3/Emu/Audio/IOS/IOSAudioBackend.cpp", "m_fader.process")
require("rpcs3/Emu/Cell/Modules/cellAudio.cpp", "m_tempo")

# Preserve NeoStation's more advanced JIT/address-space and GOW3 memory policy.
require("Utilities/JITIOS.cpp",
        "JIT_DATA_ADDRESS_SPACE_EXHAUSTED",
        "reserve_capacity_layout")
require("rpcs3/ios/IOSMemoryPressurePolicy.h",
        "high_footprint_headroom_moderate_enter",
        "get_ppu_module_file_budget")

print("PASS: Build353 XITRIX v0.10 selective engine contract")
