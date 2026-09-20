"""Compile and execute the real helper-only journal, including crash recovery."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'packages/rpcs3_jit_helper/ios/Classes/Rpcs3HelperJournal.swift'
HARNESS = r'''
import Foundation
let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let one = try Rpcs3HelperJournal(directory: root, targetPID: 42)
one.append("RPCS3_RSP_STOP reply=T05thread:1;")
one.append("pairingData=DO_NOT_STORE")
let evidence = Rpcs3HelperJournal.previous(in: root).joined(separator: "\n")
precondition(evidence.contains("pid=42") && evidence.contains("T05thread:1;"))
precondition(!evidence.contains("DO_NOT_STORE"))
// A previous helper may still own its FD when the host starts a new process.
let two = try Rpcs3HelperJournal(directory: root, targetPID: 43)
one.append("RPCS3_PROTOCOL_ERROR previous helper completed late")
two.append("RPCS3_RSP_STOP new attempt")
for _ in 0..<100 { two.append("RPCS3_RSP_STOP " + String(repeating:"x",count:1700)) }
let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys:nil)
precondition(files.count==2)
for file in files {
 let bytes = try Data(contentsOf:file)
 precondition(bytes.count <= Rpcs3HelperJournal.limit)
}
let recovered=Rpcs3HelperJournal.previous(in:root).joined(separator:"\n")
precondition(recovered.contains("pid=42") && recovered.contains("pid=43"))
two.finishSuccessfully()
precondition(Rpcs3HelperJournal.previous(in:root).count==1)
print("PASS: independent journal, prior PID recovery, concurrent files, bounded size, no pairing data")
'''
with tempfile.TemporaryDirectory() as temporary:
    main = Path(temporary) / 'main.swift'
    main.write_text(HARNESS)
    binary = Path(temporary) / 'test-journal'
    subprocess.run(['swiftc', str(SOURCE), str(main), '-o', str(binary)], check=True, timeout=60)
    subprocess.run([str(binary)], check=True, timeout=10)
