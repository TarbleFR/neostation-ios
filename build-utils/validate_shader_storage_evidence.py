#!/usr/bin/env python3
"""Strict exact-source check; SDK/simulator/GPU tests are not physical game tests."""
import hashlib,json,os
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def validate(report,sha,root=ROOT):
    assert report['passed'] is True and report['sourceCommit']==sha
    for field in ('productionClientExecuted','productionHostServiceIOSLinked','realIOSSimulatorServiceExecuted','realVulkanModule'):
        assert report[field] is True,field
    assert report['physicalIPhoneValidated'] is False and report['realRPCS3GameplayValidated'] is False
    assert report['kernelSwapPorted'] is False
    gpu=report['gpu'];assert gpu['passed'] and gpu['sourceBuilds']==gpu['sourceBuildsBeforeRestore']>=1 and gpu['realComputeDispatchCompleted']
    assert gpu['cpuBytesReleasedBeforePipeline'] and gpu['diskReadBytes']>0 and gpu['diskWriteBytes']>0
    sim=report['simulator'];assert sim['passed'] and sim['epochIsolation'] and sim['leaseSurvivedSessionEnd'] and sim['privateFileRoundTrip']
    for field in ('sourceArchiveRoundTrip','sourceEpochIsolation','sourcePressureRefusal'):
        assert sim[field] is True,field
    source=sim['sourceDiagnostics']
    assert source['archivedSourceBytesCumulative']>0 and source['stagingRamBytes']==0
    assert source['diskReadBytes']>0 and source['diskWriteBytes']>0
    paths={str(p.relative_to(root)) for p in (root/'native/neoswap-storage').glob('*') if p.suffix in ('.h','.cpp','.py')}
    paths|={str(p.relative_to(root)) for p in (root/'native/neoswap-storage/tests').glob('*') if p.suffix in ('.cpp','.mm')}
    paths|={'build-utils/configure_neoswap_storage.py','packages/neo_swap/ios/Classes/NeoSwapStorageService.h',
            'packages/neo_swap/ios/Classes/NeoSwapStorageService.mm','packages/neo_swap/ios/Classes/StorageABI.h'}
    paths.add('packages/neo_swap/ios/Classes/SourceABI.h')
    assert set(report['inputSHA256'])==paths,'Incomplete/extraneous storage input identity'
    for path,want in report['inputSHA256'].items():assert hashlib.sha256((root/path).read_bytes()).hexdigest()==want,path
if __name__=='__main__':
    import sys
    validate(json.loads(Path(sys.argv[1]).read_text()),os.environ['GITHUB_SHA']);print('PASS exact host/client source, simulator and real macOS GPU proof; no physical game inference')
