#!/usr/bin/env python3
"""Compile changed native translation units with the exact iOS flags, before Ninja."""
import json, shlex, subprocess, sys
from pathlib import Path
path=Path(sys.argv[1])
units={'JITIOS.cpp', 'JITASM.cpp', 'PPUFunction.cpp', 'PPUThread.cpp', 'SPUCommonRecompiler.cpp', 'RPCS3IOS.cpp'}
commands=json.loads(path.read_text())
checked=set()
for entry in commands:
    name=Path(entry['file']).name
    if name not in units: continue
    args=entry.get('arguments') or shlex.split(entry['command'])
    result=[]; skip=False
    for arg in args:
        if skip: skip=False; continue
        if arg in ('-o','-MF','-MT','-MQ'): skip=True; continue
        if arg in ('-c','-MD','-MMD'): continue
        result.append(arg)
    result.append('-fsyntax-only')
    print('iOS syntax gate:', name, flush=True)
    subprocess.run(result,cwd=entry['directory'],check=True)
    checked.add(name)
if checked != units: raise SystemExit('Missing translation units: '+str(units-checked))
print('PASS: exact compiler/target/flags for all six startup translation units')
