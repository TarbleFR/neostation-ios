#!/usr/bin/env python3
"""Validate source-built frontend binary and curated package before signing."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
sys.path.insert(0,str(Path(__file__).resolve().parent))
from package_ipa import verify,macho,PINS

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--package',type=Path,required=True)
    p.add_argument('--host-commit',required=True)
    a=p.parse_args()
    result=verify(a.package)
    frontend=a.package/'Frameworks'/'libRetroArchCore.dylib'
    data=frontend.read_bytes()
    native=macho(data)
    symbols=subprocess.check_output(['nm','-gU',str(frontend)],text=True)
    exported={line.split()[-1] for line in symbols.splitlines() if line.split()}
    if exported!={'_NeoRetroArch_GetAPI'}:
        raise ValueError(f'Unexpected frontend exports: {sorted(exported)}')
    if native['installName']!='@rpath/libRetroArchCore.dylib': raise ValueError('Frontend install name mismatch')
    imports=subprocess.check_output(['nm','-u',str(frontend)],text=True)
    if '_UIApplicationMain' in imports: raise ValueError('Frontend still imports UIApplicationMain')
    result.update({'hostCommit':a.host_commit,'frontendSha256':hashlib.sha256(data).hexdigest(),
        'frontendMacho':native,'abiVersion':1,'runtimeIdentity':PINS['frontend']['runtimeIdentity'],
        'sourceBuild':True,'deviceValidated':False,'standaloneEntry':False})
    (a.package/'frontend-validation.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))

if __name__=='__main__':main()
