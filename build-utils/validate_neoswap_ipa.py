#!/usr/bin/env python3
"""Prove the IPA contains ONE host broker and the RPCS3 v1 client."""
import argparse, hashlib, json, pathlib, plistlib, subprocess, tempfile, zipfile
from configure_neoswap_donor import DONOR_CONTRACTS
p=argparse.ArgumentParser();p.add_argument('ipa');p.add_argument('--build-number',required=True);p.add_argument('--report',required=True)
a=p.parse_args()
with zipfile.ZipFile(a.ipa) as z, tempfile.TemporaryDirectory() as tmp:
    apps={n.split('/')[1] for n in z.namelist() if n.startswith('Payload/') and len(n.split('/'))>2 and n.split('/')[1].endswith('.app')}
    assert len(apps)==1,apps
    root='Payload/'+apps.pop()+'/'
    info=plistlib.loads(z.read(root+'Info.plist'));assert str(info['CFBundleVersion'])==a.build_number
    entries={
      'broker':root+'Frameworks/neo_swap.framework/neo_swap',
      'bridge':root+'Frameworks/rpcs3_internal_bridge.framework/rpcs3_internal_bridge',
    }
    cores=[n for n in z.namelist() if n.startswith(root) and n.endswith('/libRPCS3Core.dylib')]
    assert len(cores)==1,cores
    entries['core']=cores[0];exports={};digests={};paths={}
    for key,name in entries.items():
        data=z.read(name);path=pathlib.Path(tmp)/key;path.write_bytes(data);paths[key]=path
        exports[key]={line.split()[-1] for line in subprocess.check_output(['nm','-gU',str(path)],text=True).splitlines() if line.split()}
        digests[key]=hashlib.sha256(data).hexdigest()
        assert subprocess.check_output(['lipo','-archs',str(path)],text=True).strip()=='arm64',key
    required={'_NeoSwap_GetAPI','_NeoSwap_Configure','_NeoSwap_Snapshot','_NeoSwap_LiveBytes','_NeoSwap_RegisterClient','_NeoSwap_HostSnapshot','_NeoSwap_StorageSnapshot','_NeoSwap_ClaimDonationDemand','_NeoSwap_AcknowledgeDonationDemand','_OBJC_CLASS_$_NeoSwapPlugin','_OBJC_CLASS_$_NeoSwapDonorSession','_OBJC_CLASS_$_NeoSwapMachHandle'}
    assert required<=exports['broker'],required-exports['broker']
    assert '_rpcs3_ios_set_neoswap_api' in exports['core']
    assert '_rpcs3_ios_get_neoswap_client_stats' in exports['core']
    assert not (required & exports['core']), 'Core must borrow the broker, not link a duplicate'
    assert not any('_NeoSwap_Test' in name for name in exports['broker']), 'Test hooks in deliverable'
    deps=subprocess.check_output(['otool','-L',str(paths['bridge'])],text=True)
    assert '/neo_swap.framework/neo_swap' in deps,'RPCS3 host bridge does not link the shared service'
    undefined=subprocess.check_output(['nm','-u',str(paths['bridge'])],text=True)
    assert {'_NeoSwap_GetAPI','_NeoSwap_LiveBytes','_NeoSwap_HostSnapshot'} <= set(undefined.split())
    donor_hashes={}
    eager_mach={'_mach_make_memory_entry_64','_mach_vm_map','_mach_vm_deallocate','_mach_vm_purgable_control'}
    broker_undefined=set(subprocess.check_output(['nm','-u',str(paths['broker'])],text=True).split())
    assert not (eager_mach & broker_undefined), 'Optional Mach APIs must be resolved at runtime'
    for bundle,contract in DONOR_CONTRACTS.items():
        prefix=root+'PlugIns/'+bundle+'/'
        donor_info=plistlib.loads(z.read(prefix+'Info.plist'))
        assert donor_info['NeoStationNeoSwapDonorIndex']==contract['index'],bundle
        assert donor_info['CFBundleIdentifier']==info['CFBundleIdentifier']+contract['bundleSuffix'],bundle
        extension=donor_info['NSExtension']
        assert extension['NSExtensionPointIdentifier']=='com.apple.ar.viewer',bundle
        assert extension['NSExtensionContextClass']=='NSExtensionContext',bundle
        assert extension['NSExtensionContextHostClass']=='NSExtensionContext',bundle
        assert donor_info['XPCService']=={'ServiceType':'Application','_MultipleInstances':True,'_ProcessType':'App'},bundle
        assert donor_info['XPCService']['_MultipleInstances'] is True,bundle
        donor_data=z.read(prefix+donor_info['CFBundleExecutable'])
        donor_path=pathlib.Path(tmp)/pathlib.Path(bundle).stem;donor_path.write_bytes(donor_data)
        donor_hashes[bundle]=hashlib.sha256(donor_data).hexdigest()
        assert subprocess.check_output(['lipo','-archs',str(donor_path)],text=True).strip()=='arm64',bundle
        donor_exports={line.split()[-1] for line in subprocess.check_output(['nm','-gU',str(donor_path)],text=True).splitlines() if line.split()}
        assert '_OBJC_CLASS_$_NeoSwapDonorRequestHandler' in donor_exports,bundle
        assert '_OBJC_CLASS_$_NeoSwapDonorSession' not in donor_exports, 'Donor must not embed its host launcher'
        undefined=set(subprocess.check_output(['nm','-u',str(donor_path)],text=True).split())
        assert not (eager_mach & undefined), 'Optional Mach APIs must be resolved at runtime'
report={'build':a.build_number,'neoswap_abi':1,'single_host_broker':True,'rpc_client_export':True,
 'client_stats_abi':1,'client_stats_export':True,'host_snapshot_exports':True,
 'donation_backend_present':True,'donor_host_launcher_separated':True,'effective_device_profile_validated':False,
 'donor_binaries_sha256':donor_hashes,'packaged_donor_count':1,
 'coverage':'RPCS3 RSX CPU aligned data >= 1 MiB, all titles; not all process/GPU/JIT memory',
 'sha256':digests,'device_runtime_tested':False}
pathlib.Path(a.report).write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
