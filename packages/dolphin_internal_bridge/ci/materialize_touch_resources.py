#!/usr/bin/env python3
"""Package the original, hash-verified DolphiniOS touch layouts and button art."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import urllib.parse
import urllib.request


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path)
    args = parser.parse_args()
    package = Path(__file__).resolve().parents[1]
    manifest = json.loads(Path(__file__).with_name('touch_resources.json').read_text())
    target = package / 'ios/TouchResources'
    target.mkdir(parents=True, exist_ok=True)

    def copy(item):
        relative = item['path']
        upstream = args.source / relative if args.source else None
        if upstream and upstream.is_file():
            data = upstream.read_bytes()
        else:
            url = 'https://raw.githubusercontent.com/OatmealDome/dolphin-ios/' + manifest['commit'] + '/' + urllib.parse.quote(relative)
            with urllib.request.urlopen(url, timeout=45) as response:
                data = response.read()
        digest = hashlib.sha1(f'blob {len(data)}\0'.encode() + data).hexdigest()
        if digest != item['sha']:
            raise ValueError(f'Upstream touch resource changed: {relative}')
        if relative.endswith('.xib'):
            data = data.replace(b'customModule="DolphiniOS"', b'customModule="dolphin_internal_bridge"')
        (target / Path(relative).name).write_bytes(data)

    with ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(copy, manifest['files']))
    print(f"Verified and packaged {len(manifest['files'])} original DolphiniOS touch resources.")


if __name__ == '__main__':
    main()
