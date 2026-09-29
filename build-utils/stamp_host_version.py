#!/usr/bin/env python3
"""Keep the app and app-extension marketing versions aligned with pubspec."""
from pathlib import Path
import os
import plistlib
import re

ROOT=Path(__file__).resolve().parents[1]
version=re.search(r'^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$',
                  (ROOT/'pubspec.yaml').read_text(),re.M)
if not version:
    raise SystemExit('A semantic version plus numeric build is required in pubspec.yaml')
name=version.group(1)
build=os.environ.get('BUILD_NUMBER',version.group(2))
paths=[ROOT/'ios/Runner/Info.plist']
paths += [p for p in (ROOT/'ios').glob('*/Info.plist') if p.parent.name!='Runner' and
          'NSExtension' in plistlib.loads(p.read_bytes())]
for path in paths:
    data=plistlib.loads(path.read_bytes())
    data['CFBundleShortVersionString']=name
    data['CFBundleVersion']=build
    path.write_bytes(plistlib.dumps(data,fmt=plistlib.FMT_XML,sort_keys=False))
print(f'App and {len(paths)-1} extensions stamped {name} ({build})')
