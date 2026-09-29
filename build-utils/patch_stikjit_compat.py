#!/usr/bin/env python3
"""Rebase NeoStation transport fixes onto pinned StikJIT 1.9.0.

Only opted-in pre-iOS-26 PS2/PS3 helpers use the classic attach transaction.
The iOS >=26 script dispatch, custom scripts and core allocator stay intact.
"""
from pathlib import Path
import sys
from patch_stikjit_rpcs3 import patch as patch_transport, replace_once


def patch(root: Path) -> None:
    patch_transport(root)
    api = root / 'Sources/StikJIT.swift'
    text = api.read_text()
    text = replace_once(text, 'import Foundation\n',
                        'import Foundation\n@_implementationOnly import idevice\n', 'FFI import')
    text = replace_once(text, '        public var connectionTimeout: TimeInterval\n',
        '        public var connectionTimeout: TimeInterval\n\n'
        '        // NeoStation opt-in; default preserves all other StikJIT clients.\n'
        '        public var neoStationClassicAttach: Bool\n', 'classic config field')
    text = replace_once(text, '                    connectionTimeout: TimeInterval = 5) {',
        '                    connectionTimeout: TimeInterval = 5,\n'
        '                    neoStationClassicAttach: Bool = false) {', 'classic config init')
    text = replace_once(text, '            self.connectionTimeout = connectionTimeout\n',
        '            self.connectionTimeout = connectionTimeout\n'
        '            self.neoStationClassicAttach = neoStationClassicAttach\n', 'classic config value')
    anchor = '        let readiness = prepareDevice(pairingFile: pairingFile,\n'
    text = replace_once(text, anchor,
        '        if JITSession.neoStationUsesClassicAttach(\n'
        '            osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,\n'
        '            requested: configuration.neoStationClassicAttach, forceScript: forceScript) {\n'
        '            // Process-local to this helper. Never change the modern debugger timeout.\n'
        '            idevice_set_global_timeout(20)\n'
        '        }\n' + anchor, 'bounded legacy FFI')
    api.write_text(text)

    session = root / 'Sources/JITSession.swift'
    text = session.read_text()
    text = replace_once(text, 'final class JITSession {\n', '''final class JITSession {

    static func neoStationUsesClassicAttach(osMajor: Int, requested: Bool, forceScript: Bool) -> Bool {
        return requested && osMajor < 26 && !forceScript
    }
''', 'classic policy')
    anchor = '        switch (forceScript, txmPresence) {\n'
    text = replace_once(text, anchor, '''        // NEOSTATION_STIKJIT_IOS18_CLASSIC_V1
        // A legacy Core never issues the iOS 26 Universal BRKs. TXM presence
        // alone must not put that Core and a waiting script in a circular wait.
        if Self.neoStationUsesClassicAttach(
            osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            requested: configuration.neoStationClassicAttach, forceScript: forceScript) {
            try neoStationAttachClassic(targetPID: targetPID, debugProxy: debugProxy, progress: progress)
            return
        }
''' + anchor, 'legacy dispatch')
    anchor = '    private func attachWithoutScript('
    method = r'''    private func neoStationAttachClassic(targetPID: Int32, debugProxy: OpaquePointer, progress: (String) -> Void) throws {
        progress("NEOSTATION_STIKJIT_IOS18_CLASSIC_V1: attaching legacy Core PID \(targetPID).")
        guard let reply = try sendCommand("vAttach;\(String(targetPID, radix: 16))", over: debugProxy),
              reply.count >= 3, reply.first == "T" || reply.first == "S",
              UInt8(reply.dropFirst().prefix(2), radix: 16) != nil else {
            throw StikJITError.scriptExecution("Legacy debugserver attach was not acknowledged.")
        }
        // Do not swallow detach errors or return a guessed success.
        guard try sendCommand("D", over: debugProxy) == "OK" else {
            throw StikJITError.scriptExecution("Legacy debugserver detach was not acknowledged.")
        }
        progress("NEOSTATION_STIKJIT_IOS18_CLASSIC_V1: attach and detach acknowledged; host must verify CS_DEBUGGED.")
    }

'''
    text = replace_once(text, anchor, method + anchor, 'verified classic attach')
    session.write_text(text)

    # NeoStation's existing MeloNX bridge resolves public idevice FFI symbols.
    # Upstream 1.9 hides/dead-strips them. Preserve the established export ABI.
    project = root / 'project.yml'
    text = project.read_text()
    text = replace_once(text, '-Wl,-hidden-lidevice_ffi',
                        '-Wl,-force_load,$(SRCROOT)/idevice/libidevice_ffi.a', 'FFI exports')
    text = replace_once(text, '        DEAD_CODE_STRIPPING: YES',
                        '        DEAD_CODE_STRIPPING: NO', 'dynamic FFI retention')
    project.write_text(text)


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: patch_stikjit_compat.py <pinned-source-root>')
    patch(Path(sys.argv[1]).resolve())
