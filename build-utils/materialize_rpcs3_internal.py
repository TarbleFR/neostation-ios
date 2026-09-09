#!/usr/bin/env python3
"""Materialize the pinned RPCS3 iOS Core and required NeoStation host entitlements."""
from __future__ import annotations

import argparse
import hashlib
import os
import plistlib
import shutil
import subprocess
import tempfile
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FRAMEWORKS = ROOT / 'packages' / 'rpcs3_internal_bridge' / 'ios' / 'Frameworks'
CORE = FRAMEWORKS / 'libRPCS3Core.dylib'

RPCS3_TAG = 'v0.8.1'
RPCS3_IPA_URL = 'https://github.com/XITRIX/RPCS3-iOS-Releases/releases/download/v0.8.1/RPCS3.ipa'
RPCS3_IPA_SHA256 = 'cd6910cb27e41a24cad224e04254f885aa90be176013569d05fb169c322f4522'
RPCS3_CORE_SHA256 = 'a2053a59c1ea6ee18dd681f5e1ab9d6c991b0cebc32284a891250d0d9c2424a7'
CORE_MEMBER = 'Payload/RPCS3.app/Frameworks/libRPCS3Core.dylib'


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def materialize_core(local_ipa: str | None) -> None:
    FRAMEWORKS.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='neostation-rpcs3-') as tmp:
        ipa = Path(tmp) / 'RPCS3.ipa'
        if local_ipa:
            shutil.copy2(Path(local_ipa).expanduser().resolve(), ipa)
        else:
            print(f'Downloading pinned RPCS3 iOS {RPCS3_TAG} release...')
            request = urllib.request.Request(
                RPCS3_IPA_URL,
                headers={'User-Agent': 'NeoStation-iOS-build'},
            )
            with urllib.request.urlopen(request, timeout=120) as response, ipa.open('wb') as output:
                shutil.copyfileobj(response, output)

        ipa_digest = sha256(ipa)
        if ipa_digest != RPCS3_IPA_SHA256:
            raise SystemExit(f'RPCS3 IPA digest mismatch: {ipa_digest}')

        with zipfile.ZipFile(ipa) as archive:
            names = archive.namelist()
            if CORE_MEMBER not in names:
                raise SystemExit(f'Missing {CORE_MEMBER} in pinned RPCS3 IPA')
            with archive.open(CORE_MEMBER) as source, CORE.open('wb') as output:
                shutil.copyfileobj(source, output)

        core_digest = sha256(CORE)
        if core_digest != RPCS3_CORE_SHA256:
            CORE.unlink(missing_ok=True)
            raise SystemExit(f'RPCS3 Core digest mismatch: {core_digest}')
        CORE.chmod(0o755)

        # The extracted dylib is re-signed with NeoStation by the user's
        # sideloading tool. Remove the original container signature so the
        # standalone RPCS3 signing identity is never preserved in our bundle.
        codesign = shutil.which('codesign')
        if codesign:
            subprocess.run([codesign, '--remove-signature', str(CORE)], check=False)

    print(f'RPCS3 Core ready: {CORE} ({CORE.stat().st_size} bytes)')


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
    sub = parser.add_subparsers(dest='command', required=True)
    core = sub.add_parser('core')
    core.add_argument('--ipa', help='Optional local RPCS3 0.8.1 IPA for offline verification')
    sub.add_parser('host')
    args = parser.parse_args()
    if args.command == 'core':
        materialize_core(args.ipa)
    else:
        configure_host()


if __name__ == '__main__':
    main()
