#!/usr/bin/env python3
"""Patch the pinned StikJIT 1.5.0 source for NeoStation's RPCS3 Universal JIT.

The upstream 1.5.0 ScriptRunner serializes only nine hexadecimal address
nibbles in each debugserver memory-write packet. RPCS3's iOS JIT arena can sit
at addresses such as 0x7000000000, so the high nibble was silently discarded.
The same code also discarded each page-write reply. Build 240 keeps the
upstream firmware/DDI/detection/cache behavior unchanged and fixes only this
Universal JIT transport contract.
"""
from pathlib import Path
import sys

SWIFT_MARKER = 'NEOSTATION_STIKJIT_RPCS3_V1'
JS_MARKER = 'NEOSTATION_STIKJIT_UNIVERSAL_V1'


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if text.count(old) != 1:
        raise ValueError(f'StikJIT 1.5.0 source drift at {label}: expected one exact match')
    return text.replace(old, new, 1)


def patch_swift(path: Path) -> None:
    text = path.read_text()
    text = replace_once(
        text,
        '    private static let jitPageSize: UInt64 = 16384\n'
        '    private static let jitPageCommandLength = 19\n'
        '    private static let commandsPerBatch = 128\n',
        '    private static let jitPageSize: UInt64 = 16384\n'
        '    private static let jitAddressHexDigits = 16\n'
        '    private static let jitPageCommandLength = 26\n'
        '    private static let commandsPerBatch = 128\n'
        f'    private static let neoStationPatchID = "{SWIFT_MARKER}"\n',
        'packet geometry',
    )
    text = replace_once(
        text,
        '        let pageCount = Int((length - 1) / Self.jitPageSize + 1)\n\n'
        '        let commandBuffer = Self.makeBlessCommands(startAddress: address, pageCount: pageCount)\n',
        '        let pageCount = Int((length - 1) / Self.jitPageSize + 1)\n'
        '        progress("\\(Self.neoStationPatchID): preparing \\(pageCount) JIT page(s) at 0x\\(String(address, radix: 16))")\n\n'
        '        let commandBuffer = Self.makeBlessCommands(startAddress: address, pageCount: pageCount)\n',
        'runtime patch diagnostic',
    )
    text = replace_once(
        text,
        '''            for _ in 0..<commandsInBatch {
                var response: UnsafeMutablePointer<CChar>?
                let readError = debug_proxy_read_response(debugProxy, &response)
                if let response {
                    idevice_string_free(response)
                }
                if let readError {
                    recordExecutionError(IdeviceFFI.consume(readError, fallback: "debug_proxy_read_response"))
                    return nil
                }
            }
''',
        '''            // A raw batch has already been sent. Consume every reply in that
            // batch before reporting a refusal so the RSP stream stays aligned for
            // the next command. Preserve the first failure as the useful diagnostic.
            var firstBatchFailure: StikJITError?
            for responseIndex in 0..<commandsInBatch {
                var response: UnsafeMutablePointer<CChar>?
                let readError = debug_proxy_read_response(debugProxy, &response)
                var reply = ""
                if let response {
                    reply = String(cString: response)
                    idevice_string_free(response)
                }
                if let readError {
                    let error = IdeviceFFI.consume(readError, fallback: "debug_proxy_read_response")
                    if firstBatchFailure == nil {
                        firstBatchFailure = error
                    }
                    continue
                }
                if reply != "OK", firstBatchFailure == nil {
                    let pageIndex = batchStart + responseIndex
                    let pageAddress = address + UInt64(pageIndex) * Self.jitPageSize
                    let detail = reply.isEmpty ? "<empty>" : reply
                    firstBatchFailure = .scriptExecution(
                        "debugserver rejected JIT page 0x\\(String(pageAddress, radix: 16)) with reply '\\(detail)'"
                    )
                }
            }
            if let firstBatchFailure {
                recordExecutionError(firstBatchFailure)
                return nil
            }
''',
        'page response handling',
    )
    text = replace_once(
        text,
        '''            buffer[start + 11] = UInt8(ascii: ",")
            buffer[start + 12] = UInt8(ascii: "1")
            buffer[start + 13] = UInt8(ascii: ":")
            buffer[start + 14] = UInt8(ascii: "6")
            buffer[start + 15] = UInt8(ascii: "9")
            buffer[start + 16] = UInt8(ascii: "#")
            writeChecksum(into: &buffer, bodyStart: start + 1, hashIndex: start + 16)
''',
        '''            buffer[start + 18] = UInt8(ascii: ",")
            buffer[start + 19] = UInt8(ascii: "1")
            buffer[start + 20] = UInt8(ascii: ":")
            buffer[start + 21] = UInt8(ascii: "6")
            buffer[start + 22] = UInt8(ascii: "9")
            buffer[start + 23] = UInt8(ascii: "#")
            writeChecksum(into: &buffer, bodyStart: start + 1, hashIndex: start + 23)
''',
        'full-width packet offsets',
    )
    text = replace_once(
        text,
        '''    private static func writeHexAddress(_ address: UInt64, into buffer: inout [UInt8], at index: Int) {
        for nibble in 0..<9 {
            let shift = UInt64((8 - nibble) * 4)
            buffer[index + nibble] = hexDigit(UInt8((address >> shift) & 0xf))
        }
    }
''',
        '''    private static func writeHexAddress(_ address: UInt64, into buffer: inout [UInt8], at index: Int) {
        for nibble in 0..<Self.jitAddressHexDigits {
            let shift = UInt64((Self.jitAddressHexDigits - 1 - nibble) * 4)
            buffer[index + nibble] = hexDigit(UInt8((address >> shift) & 0xf))
        }
    }
''',
        'full-width address serializer',
    )
    if SWIFT_MARKER not in text:
        raise ValueError('Swift patch marker missing after patch')
    path.write_text(text)


def patch_universal_js(path: Path) -> None:
    text = path.read_text()
    text = replace_once(
        text,
        'const CMD_NEW_BREAKPOINTS = 2;\n',
        'const CMD_NEW_BREAKPOINTS = 2;\n'
        f'const {JS_MARKER} = "{JS_MARKER}";\n',
        'Universal script patch marker',
    )
    text = replace_once(
        text,
        '''    let prepareJITPageResponse = prepare_memory_region(jitPageAddress, x1);
    log(`prepareJITPageResponse = ${prepareJITPageResponse}`);

    let putX0Response = send_command(`P0=${numberToLittleEndianHexString(jitPageAddress)};thread:${tid};`);
''',
        f'''    let prepareJITPageResponse = prepare_memory_region(jitPageAddress, x1);
    log(`prepareJITPageResponse = ${{prepareJITPageResponse}}`);
    if (prepareJITPageResponse !== "OK") {{
        log(`{JS_MARKER}: debugserver page preparation failed; returning zero to the target`);
        let putFailureX0Response = send_command(`P0=${{numberToLittleEndianHexString(0n)}};thread:${{tid}};`);
        log(`putFailureX0Response = ${{putFailureX0Response}}`);
        return;
    }}

    let putX0Response = send_command(`P0=${{numberToLittleEndianHexString(jitPageAddress)}};thread:${{tid}};`);
''',
        'propagate page preparation failure',
    )
    text = replace_once(
        text,
        '    for (let i = 4; i >= 0; i--) {\n',
        '    for (let i = 7; i >= 0; i--) {\n',
        'decode full 64-bit register',
    )
    text = replace_once(
        text,
        '    for (let i = 0; i < 5; i++) {\n',
        '    for (let i = 0; i < 8; i++) {\n',
        'encode full 64-bit register',
    )
    if JS_MARKER not in text:
        raise ValueError('Universal JS patch marker missing after patch')
    path.write_text(text)


def patch(root: Path) -> None:
    swift = root / 'Sources/ScriptRunner.swift'
    universal = root / 'Resources/universal.js'
    if not swift.is_file() or not universal.is_file():
        raise ValueError('Expected StikJIT 1.5.0 source layout was not found')
    patch_swift(swift)
    patch_universal_js(universal)
    print(f'Patched StikJIT RPCS3 transport: {swift.relative_to(root)}, {universal.relative_to(root)}')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: patch_stikjit_rpcs3.py <StikJIT-1.5.0-source>')
    patch(Path(sys.argv[1]))
