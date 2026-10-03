#!/usr/bin/env python3
"""Execute each immutable research profile against the actual iOS storage service."""
from pathlib import Path
import json
import os
import platform
import sys
import tempfile
ROOT=Path(__file__).resolve().parents[1]
HERE=ROOT/'native/neoswap-storage'
sys.path.insert(0,str(HERE))
from run_shader_validation import simulator_service
assert platform.system()=='Darwin','iOS18 Simulator required; cannot silently skip'
output=ROOT/'build/neoswap-research';output.mkdir(parents=True,exist_ok=True)
sources=[str(HERE/name) for name in ('Store.cpp','ShaderCache.cpp','ManagedSwap.cpp','SourceArchive.cpp')]
reports={}
for mode in ('baseline','relay','integrated'):
    mode_output=output/mode;mode_output.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='neoswap-'+mode+'-') as temporary:
        report=simulator_service(Path(temporary),mode_output,sources,mode)
    assert report['passed'] is True and report['researchMode']==mode
    if mode in ('baseline','relay'):assert report['researchStorageIsolationVerified'] is True
    else:assert report['operationJournalHandoffVerified'] is True
    reports[mode]=report
(output/'profiles.json').write_text(json.dumps({'sourceCommit':os.environ.get('GITHUB_SHA'),
    'profiles':reports,'physicalIPhoneValidated':False},indent=2)+'\n')
print('PASS iOS18 research service profiles and actual archive journal handoff')
