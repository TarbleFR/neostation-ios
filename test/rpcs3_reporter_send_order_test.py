#!/usr/bin/env python3
"""Protect the helper log -> authoritative-control send ordering."""

from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "packages/rpcs3_jit_helper/ios/Classes/Rpcs3JITRequestHandlerBase.swift"
HARNESS = ROOT / "test/native/rpcs3_reporter_send_order_test.swift"

source = HELPER.read_text()
control = source.split(
    "// Lifecycle/control messages are rare and authoritative.", 1
)[1].split("if let sendError", 1)[0]

lock = control.index("sendLock.lock()")
send = control.index("connection.send(")
unlock = control.index("sendLock.unlock()")
wait = control.index("semaphore.wait(")
assert lock < send < unlock < wait, (
    "control sends must release sendLock after enqueue and before waiting for "
    "Network.framework acknowledgement"
)
assert "defer { sendLock.unlock() }" not in control
assert "Timed out writing control state to NeoStation." in source

compiler = shutil.which("swiftc")
if compiler is None:
    print("RPCS3 reporter lock-order source contract: OK; Swift harness SKIP")
    sys.exit(0)

with tempfile.TemporaryDirectory(prefix="rpcs3-reporter-order-") as directory:
    binary = Path(directory) / "reporter-send-order"
    subprocess.run(
        [compiler, str(HARNESS), "-o", str(binary)],
        check=True,
        timeout=60,
    )
    subprocess.run([str(binary)], check=True, timeout=10)

print("RPCS3 reporter lock-order source and behavior tests: OK")
