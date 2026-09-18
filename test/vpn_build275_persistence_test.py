#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

template = (ROOT/'build-utils/vpn271/provider.swift.inc').read_text()
assert 'NEOSTATION_VPN_PERSISTENCE_275' in template
assert 'cancelTunnelWithError(failure("packet write failed after bounded retries"' not in template

provider = (ROOT/'native/local_jit_tunnel/PacketTunnelProvider.swift').read_text()
assert 'NEOSTATION_VPN_PERSISTENCE_275' in provider
assert 'cancelTunnelWithError(failure("packet write failed after bounded retries"' not in provider
segment = provider.split('private func deliver(',1)[1].split('private func',1)[0]
assert 'droppedCount &+= UInt64(packets.count)' in segment
assert 'readNext()' in segment

manager = (ROOT/'packages/stikjit_bridge/ios/Classes/NeoStationLocalTunnelManager.swift').read_text()
status = manager.split('  func status(',1)[1].split('  func disable(',1)[0]
assert 'NEOSTATION_VPN_PERSISTENCE_275: using live cached manager' in status
assert 'Self.isActive(cached.connection.status)' in status
assert 'Self.providerIdentifier(for: $0) == identifier && $0.isEnabled' in status

start = manager.split('  private func loadForStart(',1)[1].split('  private func configure(',1)[0]
assert 'Self.isActive($0.connection.status)' in start
assert 'Self.providerIdentifier(for: $0) == identifier && $0.isEnabled' in start

# Preserve Build 274's rule: no VPN mutation during the RPCS3 preflight.
preflight = manager.split('NEOSTATION_VPN_STABLE_PREFLIGHT_274',1)[1].split('// Explicit Settings ON',1)[0]
for forbidden in ('startVPNTunnel', 'stopVPNTunnel', 'saveToPreferences', 'loadAllFromPreferences'):
    assert forbidden not in preflight, forbidden

print('PASS: Build 275 keeps explicit ON persistent and leaves RPCS3 preflight read-only')
