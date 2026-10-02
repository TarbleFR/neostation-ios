#!/usr/bin/env python3
"""Materialize the single canonical host-owned shader storage implementation."""
from pathlib import Path
import hashlib
import shutil
ROOT=Path(__file__).resolve().parents[1]
SOURCES=('Store.cpp','Store.h','ShaderCache.cpp','ShaderCache.h','ShaderPolicy.h','SessionSlot.h','StorageABI.h','Metrics.cpp')
def materialize(root: Path=ROOT) -> None:
    source=root/'native/neoswap-storage';target=root/'packages/neo_swap/ios/Classes/Storage'
    public=root/'packages/neo_swap/ios/Classes/StorageABI.h'
    if public.read_bytes()!=(source/'StorageABI.h').read_bytes():raise SystemExit('Storage ABI public header differs')
    if target.exists() and {p.name for p in target.iterdir()}-set(SOURCES):raise SystemExit('Unknown generated storage files')
    target.mkdir(parents=True,exist_ok=True)
    for name in SOURCES:
        assert (source/name).is_file() and not (source/name).is_symlink(),name
        if (target/name).is_symlink():raise SystemExit('Generated storage file is a symlink')
        if name=='StorageABI.h':
            (target/name).write_text('#pragma once\n#include "../StorageABI.h"\n')
        else:
            shutil.copyfile(source/name,target/name)
            assert hashlib.sha256((source/name).read_bytes()).digest()==hashlib.sha256((target/name).read_bytes()).digest()
if __name__=='__main__':materialize();print('PASS canonical storage host copies; Core remains ABI-only')
