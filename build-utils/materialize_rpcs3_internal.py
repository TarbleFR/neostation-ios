#!/usr/bin/env python3
"""Configure signing capabilities for NeoStation's embedded RPCS3 Core."""
import argparse
import plistlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def configure_host() -> None:
    entitlements = ROOT / 'ios' / 'Runner' / 'Runner.entitlements'
    payload = plistlib.loads(entitlements.read_bytes()) if entitlements.is_file() else {}
    if not isinstance(payload, dict):
        raise SystemExit('Runner.entitlements is not a dictionary')
    payload['get-task-allow'] = True
    payload['com.apple.developer.kernel.extended-virtual-addressing'] = True
    payload['com.apple.developer.kernel.increased-memory-limit'] = True
    payload['com.apple.developer.kernel.increased-debugging-memory-limit'] = True
    entitlements.parent.mkdir(parents=True, exist_ok=True)
    entitlements.write_bytes(plistlib.dumps(payload, fmt=plistlib.FMT_XML, sort_keys=False))
    print(f'RPCS3 memory/JIT entitlements configured in {entitlements}')



def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=['host'])
    parser.parse_args()
    configure_host()


if __name__ == '__main__':
    main()
