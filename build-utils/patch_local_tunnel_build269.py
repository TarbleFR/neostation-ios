#!/usr/bin/env python3
"""Build 269: explicit owned activation, stop-before-configure and startup recovery.

Apply after the Build 268 host patches. The embedded cores, emulator settings,
Dolphin account login, signing permissions and debugger lease are unchanged.
"""
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]


def change(name, old, new):
    file = ROOT / name
    text = file.read_text()
    if new in text:
        return
    if text.count(old) != 1:
        raise RuntimeError(f'{name}: expected one anchor ({text.count(old)}): {old[:90]}')
    file.write_text(text.replace(old, new, 1))


MANAGER = 'packages/stikjit_bridge/ios/Classes/NeoStationLocalTunnelManager.swift'
PROVIDER = 'native/local_jit_tunnel/PacketTunnelProvider.swift'
BRIDGE = 'packages/stikjit_bridge/ios/Classes/StikjitBridgePlugin.swift'
DART = 'packages/stikjit_bridge/lib/stikjit_bridge.dart'
SERVICE = 'lib/services/local_jit_tunnel_service.dart'
COORDINATOR = 'lib/services/local_jit_session_coordinator.dart'
UI = 'lib/screens/settings_screen/new_settings_options/tools_settings_content.dart'

# Keep separate request intentions. A queued manual ON must not inherit an
# earlier automatic request's successful LocalDevVPN result.
change(MANAGER, '  private var queuedEnsureWaiters = [(Response) -> Void]()', '''  private var queuedEnsureWaiters = [(owned: Bool, completion: (Response) -> Void)]()
  private var activePreferOwned = false
  private var retryUsed = false
  private var lastFailure: NeoStationLocalTunnelError?''')
change(MANAGER, '''  func ensureRunning(completion: @escaping (Response) -> Void) {
    DispatchQueue.main.async {
      if self.disableInFlight || self.stopRequested {
        self.queuedEnsureWaiters.append(completion)
      } else if self.ensureInFlight {
        self.activeEnsureWaiters.append(completion)
      } else {
        self.queuedEnsureWaiters.append(completion)
        self.beginEnsureIfPossible()
      }
    }
  }''', '''  func ensureRunning(completion: @escaping (Response) -> Void) {
    requestRoute(owned: false, completion: completion)
  }

  func enableOwned(completion: @escaping (Response) -> Void) {
    requestRoute(owned: true, completion: completion)
  }

  private func requestRoute(owned: Bool, completion: @escaping (Response) -> Void) {
    DispatchQueue.main.async {
      if self.ensureInFlight && !self.disableInFlight && !self.stopRequested &&
          self.activePreferOwned == owned && self.queuedEnsureWaiters.isEmpty {
        self.activeEnsureWaiters.append(completion)
      } else {
        self.queuedEnsureWaiters.append((owned, completion))
        self.beginEnsureIfPossible()
      }
    }
  }''')
change(MANAGER, '      for waiter in cancelledWaiters { waiter(.failure(.cancelled)) }',
       '      for waiter in cancelledWaiters { waiter.completion(.failure(.cancelled)) }')
change(MANAGER, '''    activeEnsureWaiters.append(contentsOf: queuedEnsureWaiters)
    queuedEnsureWaiters.removeAll(keepingCapacity: true)
    performEnsureJitRoute(generation: generation)''', '''    activePreferOwned = queuedEnsureWaiters[0].owned
    retryUsed = false
    lastFailure = nil
    while let first = queuedEnsureWaiters.first, first.owned == activePreferOwned {
      activeEnsureWaiters.append(queuedEnsureWaiters.removeFirst().completion)
    }
    performEnsureJitRoute(generation: generation)''')
change(MANAGER, '''    trace = ["generation=\\(generation)"]''',
       '''    trace = ["build=269", "generation=\\(generation)", "intent=\\(activePreferOwned ? "owned" : "automatic")"]''')
change(MANAGER, '''  private func probeExternalThenEnsureOwned(generation: UInt64) {
    // Keep the external probe''', '''  private func probeExternalThenEnsureOwned(generation: UInt64) {
    // Explicit ON always establishes our profile. It cannot succeed merely
    // because LocalDevVPN (or a draining old route) answers the TCP probe.
    if activePreferOwned {
      ensureOwnedTunnel(generation: generation)
      return
    }
    // Keep the external probe''')
# Adopt a previously running owned profile before classifying its traffic as
# external. This matters when iOS restarted the provider outside this instance.
change(MANAGER, '''    probeExternalThenEnsureOwned(generation: generation)
  }

  private func probeExternalThenEnsureOwned''', '''    if activePreferOwned {
      ensureOwnedTunnel(generation: generation)
      return
    }
    NETunnelProviderManager.loadAllFromPreferences { managers, _ in
      DispatchQueue.main.async {
        guard self.ensureIsCurrent(generation) else {
          self.finishEnsure(.failure(.cancelled), generation: generation); return
        }
        let identifier = self.providerBundleIdentifier()
        if let existing = managers?.first(where: {
          Self.isOwned($0, providerBundleIdentifier: identifier) &&
            $0.connection.status == .connected
        }) {
          self.activeManager = existing
          self.performEnsureJitRoute(generation: generation)
        } else {
          // Reading our profiles is NOT a way to enumerate third-party VPNs.
          // The automatic route can still work if preference access is denied.
          self.probeExternalThenEnsureOwned(generation: generation)
        }
      }
    }
  }

  private func probeExternalThenEnsureOwned''')
change(MANAGER, '''          self.configure(manager, providerBundleIdentifier: providerBundleIdentifier)
          self.saveReloadAndStart(manager, generation: generation)''', '''          self.prepareOwnedStart(manager, providerBundleIdentifier: providerBundleIdentifier,
                                 generation: generation)''')
# Build a clean protocol rather than retaining obsolete signed identities,
# routing flags or a connecting session from a previous installation.
change(MANAGER, '    static let schemaVersion = 1', '    static let schemaVersion = 2')
change(MANAGER, '    static let serverAddress = "On-device RemotePairing route"',
       '    static let serverAddress = "10.7.0.1"')
change(MANAGER, '    static let connectionTimeout: TimeInterval = 12',
       '    static let connectionTimeout: TimeInterval = 25')
change(MANAGER, '    let tunnelProtocol = manager.protocolConfiguration as? NETunnelProviderProtocol ?? NETunnelProviderProtocol()',
       '    let tunnelProtocol = NETunnelProviderProtocol()')
change(MANAGER, '''          configuration[Constants.schemaVersionKey] as? Int == Constants.schemaVersion else { return false }''',
       '''          let schema = configuration[Constants.schemaVersionKey] as? Int,
          (schema == 1 || schema == Constants.schemaVersion) else { return false }''')
change(MANAGER, '  private func configure(_ manager: NETunnelProviderManager, providerBundleIdentifier: String) {', '''  // Stop and confirm a terminal state BEFORE changing the protocol or saving.
  // Starting while an older profile is still disconnecting may be ignored.
  private func prepareOwnedStart(
    _ manager: NETunnelProviderManager, providerBundleIdentifier: String,
    generation: UInt64
  ) {
    guard ensureIsCurrent(generation) else {
      finishEnsure(.failure(.cancelled), generation: generation); return
    }
    stopHeartbeat()
    if manager.connection.status != .disconnected && manager.connection.status != .invalid {
      manager.connection.stopVPNTunnel()
    }
    waitForCleanStart(manager, generation: generation,
        deadline: ProcessInfo.processInfo.systemUptime + Constants.disconnectionTimeout) {
      self.configure(manager, providerBundleIdentifier: providerBundleIdentifier)
      self.saveReloadAndStart(manager, generation: generation)
    }
  }

  private func waitForCleanStart(
    _ manager: NETunnelProviderManager, generation: UInt64,
    deadline: TimeInterval, completion: @escaping () -> Void
  ) {
    guard ensureIsCurrent(generation) else {
      finishEnsure(.failure(.cancelled), generation: generation); return
    }
    if manager.connection.status == .disconnected || manager.connection.status == .invalid {
      completion(); return
    }
    guard ProcessInfo.processInfo.systemUptime < deadline else {
      disableFailedOwnedRoute(manager, generation: generation,
          failure: .stop("build=269; previous session did not stop; status=\\(Self.statusName(manager.connection.status)); trace=\\(trace.joined(separator: ","))"))
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + Constants.connectionPollInterval) {
      self.waitForCleanStart(manager, generation: generation, deadline: deadline, completion: completion)
    }
  }

  private func configure(_ manager: NETunnelProviderManager, providerBundleIdentifier: String) {''')
change(MANAGER, '''    waitUntilConnected(
      manager, generation: generation,''', '''    startHeartbeat(for: manager)
    waitUntilConnected(
      manager, generation: generation,''')
change(MANAGER, '''    let status = manager.connection.status
    switch status {''', '''    let status = manager.connection.status
    let observation = "observed=\\(Self.statusName(status))"
    if trace.last != observation { trace.append(observation) }
    switch status {''')
change(MANAGER, '''      self.disableFailedOwnedRoute(
        manager, generation: generation,
        failure: timedOut ? .timeout(details) : .start(details)
      )''', '''      if timedOut && !self.retryUsed {
        // One clean retry repairs a stale connecting session after a VPN
        // handoff. No infinite loop, profile deletion or third-party mutation.
        self.retryUsed = true
        self.trace.append("recovery=stop-reload-start; firstFailure=\\(details)")
        guard let identifier = self.providerBundleIdentifier() else {
          self.finishEnsure(.failure(.extensionMissing), generation: generation); return
        }
        self.prepareOwnedStart(manager, providerBundleIdentifier: identifier, generation: generation)
      } else {
        self.disableFailedOwnedRoute(
          manager, generation: generation,
          failure: timedOut ? .timeout(details) : .start(details)
        )
      }''')
# Keep the host IPC timer alive while the system transitions to connected.
change(MANAGER, '''    guard manager.connection.status == .connected else { return }
    // Sending from a dedicated queue''', '''    guard Self.isActive(manager.connection.status) else { return }
    // Sending from a dedicated queue''')
change(MANAGER, '''      guard let manager, manager.connection.status == .connected else { return }
      Self.sendHeartbeat(to: manager)''', '''      guard let manager, Self.isActive(manager.connection.status) else { return }
      Self.sendHeartbeat(to: manager)''')
# Return useful native diagnostics through subsequent status reads, not just
# an ephemeral Flutter exception which gets replaced by a localized timeout.
change(MANAGER, '''    let waiters = activeEnsureWaiters
    activeEnsureWaiters.removeAll''', '''    if case .failure(let error) = response { lastFailure = error }
    else { lastFailure = nil }
    let waiters = activeEnsureWaiters
    activeEnsureWaiters.removeAll''')
change(MANAGER, '''    let waiters = disableWaiters
    disableWaiters.removeAll''', '''    if case .failure(let error) = response { lastFailure = error }
    else { lastFailure = nil }
    let waiters = disableWaiters
    disableWaiters.removeAll''')
change(MANAGER, '''      "onDemand": manager?.isOnDemandEnabled ?? false, "routeVerified": routeVerified,
    ]''', '''      "onDemand": manager?.isOnDemandEnabled ?? false, "routeVerified": routeVerified,
      "lastErrorCode": lastFailure.map { "local_tunnel_" + $0.code } as Any? ?? NSNull(),
      "lastErrorDetail": lastFailure?.localizedDescription as Any? ?? NSNull(),
      "trace": trace,
    ]''')
change(BRIDGE, '    if call.method == "ensureLocalTunnel" {',
       '    if call.method == "ensureLocalTunnel" || call.method == "activateOwnedTunnel" {')
change(BRIDGE, '      NeoStationLocalTunnelManager.shared.ensureRunning { response in',
       '      let complete: (NeoStationLocalTunnelManager.Response) -> Void = { response in')
change(BRIDGE, '''      }
      return
    }

    if call.method == "localTunnelStatus"''', '''      }
      if call.method == "activateOwnedTunnel" {
        NeoStationLocalTunnelManager.shared.enableOwned(completion: complete)
      } else {
        NeoStationLocalTunnelManager.shared.ensureRunning(completion: complete)
      }
      return
    }

    if call.method == "localTunnelStatus"''')
# The old provider began its 5s watchdog before the host could observe connected
# and send a heartbeat. Give only the initial handshake a bounded grace period.
change(PROVIDER, '    static let watchdogInterval: TimeInterval = 1.0',
       '    static let watchdogInterval: TimeInterval = 1.0\n    static let startupHeartbeatGrace: TimeInterval = 30')
change(PROVIDER, '  private var debuggerLease = NeoStationDebuggerLeasePolicy()',
       '  private var debuggerLease = NeoStationDebuggerLeasePolicy()\n  private var receivedHostHeartbeat = false')
change(PROVIDER, '''        self.lastHeartbeatUptime = ProcessInfo.processInfo.systemUptime
        completionHandler?(Data("alive".utf8))''', '''        self.lastHeartbeatUptime = ProcessInfo.processInfo.systemUptime
        self.receivedHostHeartbeat = true
        completionHandler?(Data("alive".utf8))''')
change(PROVIDER, '''    lastHeartbeatUptime = ProcessInfo.processInfo.systemUptime
    let generation = self.generation''', '''    lastHeartbeatUptime = ProcessInfo.processInfo.systemUptime
    receivedHostHeartbeat = false
    logger.info("Build 269: waiting for the first host heartbeat before the normal watchdog.")
    let generation = self.generation''')
change(PROVIDER, '''    guard elapsed >= debuggerLease.timeout(normal: Configuration.heartbeatTimeout, now: now) else { return }''', '''    let normalTimeout = receivedHostHeartbeat
        ? Configuration.heartbeatTimeout : Configuration.startupHeartbeatGrace
    guard elapsed >= debuggerLease.timeout(normal: normalTimeout, now: now) else { return }''')
# Same host interface geometry as the working LocalDevVPN default, but still
# only a single /32 remote-pairing destination is routed into this tunnel.
change(PROVIDER, '        subnetMasks: ["255.255.255.255"]',
       '        subnetMasks: ["255.255.255.0"]')

change(DART, '''  /// The native preflight proves endpoint reachability, not merely VPN status.''', '''  /// Manual ON requires our provider, never a successful external fallback.
  static Future<LocalJitTunnelState> activateOwnedTunnel() async {
    final raw = await _channel.invokeMethod<Object?>('activateOwnedTunnel');
    if (raw is! Map) {
      throw StateError('NeoStation owned tunnel returned an invalid response.');
    }
    final state = LocalJitTunnelState.fromMap(Map<String, dynamic>.from(raw));
    if (!state.active || !state.routeVerified || !state.managedByNeoStation) {
      throw PlatformException(
        code: 'local_tunnel_jit_route_unavailable',
        message: 'The integrated provider did not confirm the local JIT route.',
        details: raw,
      );
    }
    return state;
  }

  /// The native preflight proves endpoint reachability, not merely VPN status.''')
change(DART, '    this.routeVerified = false,',
       '    this.routeVerified = false,\n    this.lastErrorCode,\n    this.lastErrorDetail,')
change(DART, "        routeVerified: data['routeVerified'] == true,", "        routeVerified: data['routeVerified'] == true,\n        lastErrorCode: data['lastErrorCode']?.toString(),\n        lastErrorDetail: data['lastErrorDetail']?.toString(),")
change(DART, '  final bool routeVerified;', '  final bool routeVerified;\n  final String? lastErrorCode;\n  final String? lastErrorDetail;')
change(COORDINATOR, '  Future<T> ensure() async {', '  Future<T> ensure({Future<T> Function()? routeOverride}) async {')
change(COORDINATOR, '    final route = await _ensureRoute();', '    final route = await (routeOverride ?? _ensureRoute)();')
change(SERVICE, '''  static Future<LocalJitTunnelState> authorizeAndEnable() async {
    return ensureRunningForJit();
  }''', '''  static Future<LocalJitTunnelState> authorizeAndEnable() async {
    ++_lifecycleGeneration;
    try {
      return await _session.ensure(
        routeOverride: () => _ensureNativeRoute(owned: true),
      );
    } on LocalJitSessionCancelled {
      throw const LocalJitTunnelException(
        'local_tunnel_cancelled',
        'The manual VPN activation was cancelled by a newer stop.',
      );
    }
  }''')
change(SERVICE, '''  static Future<LocalJitTunnelState> _ensureNativeRoute() async {
    try {
      final state = await StikjitBridge.ensureJitRoute();''', '''  static Future<LocalJitTunnelState> _ensureNativeRoute({bool owned = false}) async {
    try {
      final state = owned
          ? await StikjitBridge.activateOwnedTunnel()
          : await StikjitBridge.ensureJitRoute();''')
# isEnabled is permission/configuration, NOT the running state. Treating it as
# ON was making a retry click perform a second OFF after a failed startup.
change(UI, '''    if (state == null) return false;
    return state.active ||
        state.enabled ||
        state.status == 'connecting' ||
        state.status == 'reasserting';''', '''    return state?.canStopOwnedTunnel ?? false;''')
change(UI, '''        _tunnelStateLoaded = true;
        _tunnelErrorCode = null;''', '''        _tunnelStateLoaded = true;
        _tunnelErrorCode = state.lastErrorCode;''')
# Read actual status at click time, and after errors. Do not restore stale UI
# state from before a trip to iOS Settings or a failed activation.
change(UI, '''    final previous = _tunnelState;
    final disable = _shouldDisableTunnel(previous);''', '''    var previous = _tunnelState;
    var disable = _shouldDisableTunnel(previous);''')
change(UI, '''    try {
      final wasAuthorized = previous?.authorized == true;''', '''    try {
      previous = await LocalJitTunnelService.status();
      disable = _shouldDisableTunnel(previous);
      if (!mounted) return;
      setState(() { _tunnelState = previous; _isDisablingTunnel = disable; });
      final wasAuthorized = previous?.authorized == true;''')
# Both error branches independently refresh and preserve their original error.
change(UI, '''        'Could not change the local JIT tunnel state.',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      setState(() {
        _tunnelState = previous;
        _tunnelErrorCode = error.code;''', '''        'Could not change the local JIT tunnel state.',
        error: error,
        stackTrace: stackTrace,
      );
      try { previous = await LocalJitTunnelService.status(); } catch (_) {}
      if (!mounted) return;
      setState(() {
        _tunnelState = previous;
        _tunnelErrorCode = error.code;''')
change(UI, '''        LocalJitTunnelLocale.error(context, error.code),
        type: NotificationType.error,''', '''        '${LocalJitTunnelLocale.error(context, error.code)}\\n${error.message}',
        type: NotificationType.error,''')
change(UI, '''              SettingsCardRow(
                icon: Symbols.swap_horiz_rounded,''', '''              if (Platform.isIOS && _tunnelErrorCode != null &&
                  (_tunnelState?.lastErrorDetail?.isNotEmpty ?? false))
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: SelectableText(
                    _tunnelState!.lastErrorDetail!,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              SettingsCardRow(
                icon: Symbols.swap_horiz_rounded,''')
change('lib/services/game/game_launch_service.dart', '''                : Rpcs3LibraryLocale.launchFailed(context),
            titleId,''', '''                : Rpcs3LibraryLocale.launchFailed(context),
            localTunnelError ? '$titleId\\n${internalError ?? internalErrorCode}' : titleId,''')


# TCP alone may be another VPN. Require an acknowledgement from the selected
# owned NETunnelProviderSession before using its route for a game.
change(MANAGER, '''      startHeartbeat(for: manager)
      probeJitRoute { available in''', '''      startHeartbeat(for: manager)
      probeOwnedJitRoute(manager) { available in''')
change(MANAGER, '''    startHeartbeat(for: manager)
    probeJitRoute { available in''', '''    startHeartbeat(for: manager)
    probeOwnedJitRoute(manager) { available in''')
change(MANAGER, '  private func probeJitRoute(completion: @escaping (Bool) -> Void) {', '''  private func probeOwnedJitRoute(
    _ manager: NETunnelProviderManager, completion: @escaping (Bool) -> Void
  ) {
    guard let session = manager.connection as? NETunnelProviderSession else {
      completion(false); return
    }
    var settled = false
    let acknowledge: (Bool) -> Void = { alive in
      guard !settled else { return }
      settled = true
      self.trace.append("providerAlive=\\(alive)")
      guard alive, session.status == .connected else { completion(false); return }
      self.probeJitRoute(completion: completion)
    }
    do {
      try session.sendProviderMessage(Data(Constants.heartbeatMessage.utf8)) { data in
        DispatchQueue.main.async { acknowledge(data == Data("alive".utf8)) }
      }
    } catch { acknowledge(false) }
    DispatchQueue.main.asyncAfter(deadline: .now() + Constants.routeProbeTimeout) {
      acknowledge(false)
    }
  }

  private func probeJitRoute(completion: @escaping (Bool) -> Void) {''')
# A status request submitted before a click must not replace the click result.
change(UI, '''      final state = await LocalJitTunnelService.status();
      if (!mounted) return;''', '''      final state = await LocalJitTunnelService.status();
      if (!mounted || _isUpdatingTunnel) return;''')

# Update existing regression harnesses for the actual new intent queue and
# retry contract; retain every old scenario and its assertions.
QUEUE_TEST = 'test/local_jit_state_machine_check.py'
change(QUEUE_TEST, '  private var queuedEnsureWaiters = [(Response) -> Void]()', '''  private var queuedEnsureWaiters = [(owned: Bool, completion: (Response) -> Void)]()
  private var activePreferOwned = false
  private var retryUsed = false
  private var lastFailure: NeoStationLocalTunnelError?''')
TRANSPORT_TEST = 'test/local_jit_transport_behavior_test.py'
change(TRANSPORT_TEST, '(\'connectionTimeout\', \'12\', \'1.0\')', '(\'connectionTimeout\', \'25\', \'1.0\')')
change(TRANSPORT_TEST, '''    require(TestPlatform.loads == 0, "external route independent of profile permission")''', '''    require(TestPlatform.loads == 1, "inspect own provider before classifying external traffic")''')
change(TRANSPORT_TEST, '''  setup([draining], [false, true])
  let drainResult''', '''  main { draining.connection.onStop = { $0.status = .disconnecting } }
  setup([draining], [false, true])
  let drainResult''')
change(TRANSPORT_TEST, '''  wait("waiting for disconnect", { draining.saves > 0 })''', '''  wait("waiting for disconnect", { draining.connection.stops > 0 })''')
change(TRANSPORT_TEST, '''    require(timeoutProfile.connection.errorRequests == 1, "disconnect diagnostic fetched once")''', '''    require(timeoutProfile.connection.errorRequests == 2, "each of two bounded attempts keeps its diagnostic")
    require(timeoutProfile.connection.starts == 2, "only one clean retry is allowed")''')
# Preserve the 268 policy and transport tests. Its patch's own idempotence was
# already exercised before 269; after 269 check the full current patch instead.
LEASE_TEST = 'test/rpcs3_build268_tunnel_test.py'
change(LEASE_TEST, "    subprocess.run(['python3', str(ROOT / 'build-utils/patch_rpcs3_build268_tunnel.py')], check=True)",
       "    subprocess.run(['python3', str(ROOT / 'build-utils/patch_local_tunnel_build269.py')], check=True)")
change(LEASE_TEST, "    assert 'debuggerLease.timeout(normal: Configuration.heartbeatTimeout, now: now)' in provider",
       "    assert 'debuggerLease.timeout(normal: normalTimeout, now: now)' in provider\n    assert '? Configuration.heartbeatTimeout : Configuration.startupHeartbeatGrace' in provider")

change(DART, '  final bool routeVerified;', '''  bool get canStopOwnedTunnel => managedByNeoStation &&
      (active || status == 'connecting' || status == 'reasserting');

  final bool routeVerified;''')
change(TRANSPORT_TEST, 'def check_manager_transport(manager_source: str) -> str:',
       'def check_manager_transport(manager_source: str, *, scenarios: str = MANAGER_TESTS, marker: str = \'PASS: transport scenarios A-H\') -> str:')
change(TRANSPORT_TEST, "    return run_swift(PLATFORM + source + MANAGER_TESTS, 'PASS: transport scenarios A-H')",
       '    return run_swift(PLATFORM + source + scenarios, marker)')
# A controllable IPC response in the platform double exercises stale-manager
# rejection without replacing any of the manager's production methods.
change(TRANSPORT_TEST, '''  private var messageCount = 0
  var messages: Int''', '''  private var messageCount = 0
  var acknowledgeHeartbeat = true
  var messages: Int''')
change(TRANSPORT_TEST, '''    responseHandler?(Data("alive".utf8))''',
       '''    responseHandler?(acknowledgeHeartbeat ? Data("alive".utf8) : nil)''')

# The RPCS3 binary is unchanged. Extend the existing source-change gate only
# to the four explicit Build 269 host/test files, not to a wildcard or core path.
change('build-utils/reuse_build266_rpcs3_for267.py', "    'test/rpcs3_build268_tunnel_test.py',", "    'test/rpcs3_build268_tunnel_test.py',\n    'build-utils/patch_local_tunnel_build269.py',\n    'build-utils/validate_build269_identity.py',\n    'test/local_tunnel_build269_test.py',\n    'test/local_tunnel_build269_test.dart',")
change('test/rpcs3_savestate_ui_contract_test.py', "version.group(1) in ('267', '268')", "version.group(1) in ('267', '268', '269')")
print('Build 269 applied: manual owned intent, ordered restart, startup grace and retained diagnostics.')
