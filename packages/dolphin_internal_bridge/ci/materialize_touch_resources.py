#!/usr/bin/env python3
"""Package the original, hash-verified DolphiniOS touch layouts and button art."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET


def adapt_touch_layout(data: bytes) -> bytes:
    """Keep original constraints/art, but do not use UIKit system-button effects."""
    root = ET.fromstring(data)
    for view in root.iter():
        if view.get('customModule') == 'DolphiniOS':
            view.set('customModule', 'dolphin_internal_bridge')
        if view.tag == 'button' and view.get('customClass') == 'TCButton':
            view.set('buttonType', 'custom')
            for state in view.findall('state'):
                state.attrib.pop('title', None)
            for configuration in view.findall('buttonConfiguration'):
                view.remove(configuration)
        if view.tag == 'view':
            view.set('multipleTouchEnabled', 'YES')
    return ET.tostring(root, encoding='utf-8', xml_declaration=True)


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
            data = adapt_touch_layout(data)
        (target / Path(relative).name).write_bytes(data)

    with ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(copy, manifest['files']))
    print(f"Verified and packaged {len(manifest['files'])} original DolphiniOS touch resources.")


if __name__ == '__main__':
    main()
