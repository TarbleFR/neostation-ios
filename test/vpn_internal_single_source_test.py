#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text()

manager = read('packages/stikjit_bridge/ios/Classes/NeoStationLocalTunnelManager.swift')
provider = read('native/local_jit_tunnel/PacketTunnelProvider.swift')
service = read('lib/services/local_jit_tunnel_service.dart')
bridge = read('packages/stikjit_bridge/lib/stikjit_bridge.dart')
native_bridge = read('packages/stikjit_bridge/ios/Classes/StikjitBridgePlugin.swift')
main = read('lib/main.dart')
lifecycle = read('lib/widgets/app_lifecycle_handler.dart')
fast_workflow = read('.github/workflows/ios-ci.yml')

for forbidden in (
    'patch_rpcs3_build268_tunnel.py',
    'patch_local_tunnel_build269.py',
    'patch_vpn_build271.py',
    'patch_vpn_build273.py',
    'patch_vpn_build276_final.py',
):
    assert forbidden not in fast_workflow, forbidden

assert 'func enableOwned(' in manager
assert 'func disable(' in manager
assert 'func ensureRunning(' in manager
ensure_body = manager.split('func ensureRunning(', 1)[1].split('// MARK: - Status', 1)[0]
assert 'probeJitRoute' in ensure_body
for mutation in ('startVPNTunnel', 'stopVPNTunnel', 'saveToPreferences', 'removeFromPreferences'):
    assert mutation not in ensure_body, mutation

assert 'activateOwnedTunnel' in native_bridge
assert 'activateOwnedTunnel' in bridge
assert 'StikjitBridge.activateOwnedTunnel()' in service
assert 'StikjitBridge.ensureJitRoute()' in service

for forbidden in (
    'heartbeatTimeout',
    'startWatchdog',
    'expireHeartbeatIfNeeded',
    'cancelTunnelWithError',
):
    assert forbidden not in provider, forbidden
assert 'heartbeatMessage' not in manager
assert 'startHeartbeat' not in manager
assert 'stopHeartbeat' not in manager

assert 'writeFailures &+= 1' in provider
assert 'droppedPackets &+= UInt64(reflected.count)' in provider

# Provider startup must never leave startTunnel unresolved indefinitely.
assert 'settings.mtu = 1500' in provider
assert 'self.queue.asyncAfter(deadline: .now() + 10)' in provider
assert 'self.pendingStart != nil' in provider
assert 'networkSettingsTimeoutError()' in provider
assert 'setTunnelNetworkSettings did not complete within 10 seconds.' in provider

assert 'LocalJitTunnelService' not in main
assert 'LocalJitTunnelService' not in lifecycle
assert 'refreshInBackground' not in service
assert 'stopForLifecycle' not in service



# Regression guard: iOS may still report the previous disconnected state
# immediately after startVPNTunnel(). It is terminal only after a real
# connecting/reasserting state was observed.
assert 'observedConnecting: false' in manager
assert 'observedConnecting: true' in manager
assert 'case .disconnected where observedConnecting:' in manager
assert 'status == .connecting' in manager
assert 'status == .reasserting' in manager

def activation_result(states):
    observed = False
    for state in states:
        if state == 'connected':
            return 'connected'
        if state == 'invalid':
            return 'failed'
        if state == 'disconnected' and observed:
            return 'failed'
        if state in ('connecting', 'reasserting'):
            observed = True
    return 'pending'

assert activation_result(['disconnected', 'connecting', 'connected']) == 'connected'
assert activation_result(['disconnected', 'disconnected', 'connecting', 'connected']) == 'connected'
assert activation_result(['connecting', 'disconnected']) == 'failed'
assert activation_result(['reasserting', 'disconnected']) == 'failed'


# A system VPN profile can outlive a sideload installation. The manager must
# bind a profile to the current app-container installation and recreate only
# stale profiles on explicit Settings ON.
assert 'installationTokenKey = "installationToken"' in manager
assert 'NeoStationLocalTunnel.installationToken' in manager
assert 'let token = self.installationToken()' in manager
assert 'Self.installationToken(for: $0) == token' in manager
assert 'Self.installationToken(for: $0) != token' in manager
assert 'stale + duplicates' in manager
assert 'Constants.installationTokenKey: installationToken' in manager

def profile_plan(stored_tokens, current_token):
    current = [token for token in stored_tokens if token == current_token]
    stale = [token for token in stored_tokens if token != current_token]
    return current, stale

current, stale = profile_plan(['old-install'], 'new-install')
assert current == [] and stale == ['old-install']
current, stale = profile_plan(['same-install'], 'same-install')
assert current == ['same-install'] and stale == []
current, stale = profile_plan([None, 'same-install'], 'same-install')
assert current == ['same-install'] and stale == [None]


# LocalDevVPN handoff: explicit ON may stop an active foreign packet tunnel,
# waits until it is truly disconnected, then settles before starting NeoStation.
assert 'let foreignActive = allManagers.filter' in manager
assert '!Self.isOwned($0, providerBundleIdentifier: providerIdentifier)' in manager
assert 'stopForeignManagersForHandoff' in manager
assert 'manager.connection.stopVPNTunnel()' in manager
assert 'waitUntilQuiescent' in manager
assert 'handoffSettleDelay: TimeInterval = 1.0' in manager
assert 'recoverOwnedTransitionIfNeeded' in manager
assert 'case .connecting, .reasserting, .disconnecting:' in manager
assert 'status == .disconnected || status == .invalid' in manager

# Game launch may wait for a user-requested ON already in flight, but must
# never start a VPN itself.
assert 'static Future<LocalJitTunnelState>? _activationInFlight;' in service
assert 'final activation = _activationInFlight;' in service
assert 'await activation;' in service
assert service.count('StikjitBridge.activateOwnedTunnel()') == 1
ensure_jit = service.split('static Future<LocalJitTunnelState> ensureRunningForJit()', 1)[1].split('/// Explicit Settings OFF', 1)[0]
assert 'StikjitBridge.activateOwnedTunnel()' not in ensure_jit
assert ensure_jit.index('await activation;') < ensure_jit.index('StikjitBridge.ensureJitRoute()')

def handoff_plan(foreign_status, owned_status):
    stop_foreign = foreign_status in ('connected', 'connecting', 'reasserting')
    wait_foreign = foreign_status in ('connected', 'connecting', 'reasserting', 'disconnecting')
    recover_owned = owned_status in ('connecting', 'reasserting', 'disconnecting')
    return stop_foreign, wait_foreign, recover_owned

assert handoff_plan('connected', 'disconnected') == (True, True, False)
assert handoff_plan('disconnecting', 'disconnected') == (False, True, False)
assert handoff_plan('disconnected', 'connecting') == (False, False, True)
assert handoff_plan('disconnected', 'connected') == (False, False, False)

assert 'schemaVersion = 277' in manager
assert '"version": 277' in provider

print('PASS: VPN 279 provider + reinstall identity + LocalDevVPN handoff + pending activation coordination')
