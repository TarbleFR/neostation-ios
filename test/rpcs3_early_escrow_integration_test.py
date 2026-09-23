#!/usr/bin/env python3
"""Guard the early low-VA escrow and allocation-free Core handoff."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CLASSES = ROOT / "packages/rpcs3_internal_bridge/ios/Classes"
bridge = (CLASSES / "Rpcs3InternalBridgePlugin.mm").read_text()
policy = (CLASSES / "Rpcs3EarlyAddressSpaceEscrowPolicy.h").read_text()
wrapper = (CLASSES / "Rpcs3EarlyAddressSpaceEscrow.h").read_text()

assert "NEOSTATION_BUILD321_EARLY_JIT_ESCROW_V1" in policy
assert "448 * mib, 384 * mib, 320 * mib, 256 * mib" in policy
assert "data_bytes = 256 * mib" in policy
assert "VM_PROT_NONE" in wrapper
assert "VM_FLAGS_FIXED" in wrapper
assert "VM_FLAGS_OVERWRITE" not in wrapper
assert "map.regions < 32768" in wrapper

plugin_init = bridge.index("- (instancetype)init")
acquire = bridge.index("_jitEscrow.acquire()", plugin_init)
method_handler = bridge.index("- (void)handleMethodCall:")
assert plugin_init < acquire < method_handler

load = bridge.index("[self loadCoreWithExpandedJit:expanded error:&error]")
release = bridge.index("self->_jitEscrow.release_for_core()")
initialize = bridge.index("self->_api.initialize(&options)")
assert acquire < load < release < initialize

# The success edge from vm_deallocate enters the existing Core-owned allocator
# directly. Diagnostics and string formatting are deliberately after initialize.
between = bridge[release:initialize]
assert "RPCS3Milestone" not in between
assert "RPCS3Diagnostic" not in between
assert "stringWithFormat" not in between
assert "return;" in between  # fail-closed branch blocks initialize
assert '"stage": @"arena_escrow"' in between

for retired in (
    "Rpcs3ArenaReservation",
    "reserveAddressSpace",
    "adopt_jit_layout",
    "reset_failed_startup",
):
    assert retired not in bridge
    assert retired not in policy
    assert retired not in wrapper

print("PASS: Build321 reserves low VA before Dusklight and hands it to RPCS3")
