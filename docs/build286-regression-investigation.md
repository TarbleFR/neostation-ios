# Candidate 286 — VPN, debugger handoff, game deletion

Starting revision: `1ebe245e3327102eae03e19d922e42ad288891c7` (Build 285).
The Build 273 reference, main and backup are unchanged.

## Evidence and scope

The supplied RPCS3 milestones end at `core_load_begin`, and stderr records entry
into dlopen. The app log records a reachable TCP endpoint and then “internal JIT
prepared”. These facts locate the failure; they do not establish an iOS crash
exception. An iPhone crash report and a test of this candidate remain necessary
to attribute every reported crash conclusively.

Confirmed source defects:

* The helper interpreted `Handling signal 1`, printed **before** the blocking
  debugserver continue, then sent `core_load_ready` after 250 ms. No protocol
  response was required. The replacement RPCS3-only script validates vAttach and
  qProcessInfo, then answers a host-owned BRK command 3 carrying a fresh nonce.
  The host gates dlopen on the returned value after its probe thread resumes.
  A live P_TRACED check precedes the probe. Core arena preparation and final
  detach still use the existing universal protocol. No core binary or StikJIT
  binary was rebuilt; the shared scripts used by other emulators are unchanged.
* VPN commands invalidated callbacks but did not serialize the preference writes
  already submitted to NetworkExtension. A superseded save could overwrite the
  later OFF. Saves/removals now have an outstanding-write fence; later commands
  load preferences only after it clears. Timeout cancels further steps and
  reconciles only the unfinished connection started by that explicit ON.
  Connected tunnels and foreign profiles are never stopped by this recovery.
  Notifications retain transient connecting states missed between polling ticks.
  The same owned profile is reused, connected ON is a no-op, and game/lifecycle
  preflight remains read-only. The validated 279 packet provider is unchanged.
* Generic deletion removed SQLite rows first, used File.exists on virtual URIs,
  and swallowed filesystem errors. PS3 bulk deletion additionally required JIT
  and Core initialization. Settings and bulk PS3 removal now use a bounded
  private-root installation plan independent of JIT. Generic file deletion
  propagates native permission/I/O errors and commits metadata removal afterward.
  iOS reacquires a matching bookmark scope for coordinated file removal and
  balances that acquisition without revoking existing import scopes. Unknown or
  revoked external folders fail visibly. Stale container paths are not guessed.

PS3 removal includes installed HDD title/update folders, extracted games,
DiscImages/DiscImgs variants and the exact games.yml registration. It retains
save data, savestates, licenses, firmware and caches. Active emulation, import,
launch and overlapping deletion are rejected. SQLite title/metadata removal is
transactional; cached entries are removed and the private library is reconciled.
Late catalog enrichment cannot insert a private installation whose files are gone.

Filesystem deletion and SQLite cannot form one atomic transaction. On an I/O or
database failure the error remains visible; retry is idempotent and the ordinary
library reconciliation removes rows for installations already absent. No error
is converted into a successful delete callback.

## Regression gates

* `vpn_state_machine_test.py` compiles the production Swift controller against
  deterministic NetworkExtension adapters: ON/OFF with late save, stuck start
  and retry, transient connect/disconnect with native error, duplicate ON,
  already-connected ON and read-only route failure/recovery.
* `rpcs3_debugger_handshake_test.js` executes the bundled script and verifies
  attach/PID/nonce/PC/register acknowledgements and actual continue order,
  including five failure paths. The old tests requiring the 250 ms implementation
  are replaced by this behavior gate; the packet-provider identity guard stays.
* `game_deletion_regression_test.dart` exercises actual temporary files and an
  in-memory SQLite database: failure preserves rows, retry, missing parent,
  virtual URI rejection, PS3 multi-location deletion, retained user data,
  registration cleanup, path traversal and symlink rejection.
* Existing repository/library/Dolphin deletion tests, Flutter analyze and the
  macOS early-loader diagnostic test run before xcodebuild. Packaging verifies
  native donor identities, provider machine code/entitlements against 279 and
  exact inclusion of the reviewed debugger script in the helper extension.

Build 285's historical host patches were materialized once into tracked source.
`build-utils/canonical-host-285.json` records the resulting hashes. The candidate
workflow builds those sources directly. The separate historical release workflow
is not used to build this candidate.

## Diagnostics and device validation

VPN records command ID, intent, phase, observed status, elapsed milliseconds,
pending writes, native error and recovery outcome. RPCS3 records durable
`debugger_probe_begin/end` before `core_load_begin/end`; probe success remains
distinct from Core initialization, JIT arena completion and game boot. Deletion
records the operation/title and filesystem/registration/database/cache stages.
Errors reach the UI instead of silently removing a game card.

Simulator/mocked tests and an IPA build do not prove on-device stability. Check
on iPhone: explicit ON/OFF and timeout recovery; cold/warm PS3 launches; Dolphin
then PS3; deletion before any JIT session; revoked external bookmark; restart
after deletion; reimport of the same title; saves still present. Capture the iOS
crash report if a launch still terminates after a successful debugger probe.
