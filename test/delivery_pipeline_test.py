"""Meaningful input-reuse and final-code identity guards for the new lane."""
import importlib.util
import json
from pathlib import Path
import subprocess
import unittest
import struct
import tempfile
import os

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('reuse',ROOT/'build-utils/verify_delivery_reuse.py')
reuse=importlib.util.module_from_spec(spec)
spec.loader.exec_module(reuse)

def module(name):
    spec=importlib.util.spec_from_file_location(name,ROOT/('build-utils/'+name+'.py'))
    value=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value

class DeliveryPipeline(unittest.TestCase):
    def test_reuse_rejects_modified_unrelated_runtime(self):
        file=ROOT/'native/armsx2_internal_helper/Info.plist'
        old=file.read_bytes()
        try:
            file.write_bytes(old+b'\n')
            with self.assertRaisesRegex(ValueError,'Unreviewed validation input changed'):
                reuse.verify_tree()
        finally:
            file.write_bytes(old)

    def test_current_library_and_native_reference_remain_exact(self):
        subprocess.run(['python3','test/retroarch_baseline_scope_test.py'],cwd=ROOT,check=True)
        changed,unchanged=reuse.verify_tree()
        self.assertGreater(len(unchanged),500)
        self.assertIn('lib/services/retroarch_library_service.dart',changed)
        self.assertFalse(any(p.startswith('native/') for p in changed))

    def test_release_device_and_signature_guards_are_active(self):
        workflow=(ROOT/'.github/workflows/retroarch-delivery.yml').read_text()
        self.assertIn("generic/platform=iOS",workflow)
        self.assertIn('-configuration Release -sdk iphoneos',workflow)
        self.assertNotIn('flutter clean',workflow)
        self.assertIn('verify_delivery_reuse.py',workflow)
        self.assertIn('sign_delivery.py',(ROOT/'build-utils/delivery_benchmark.py').read_text().replace('from sign_delivery import sign','sign_delivery.py'))
        self.assertIn('codesign', (ROOT/'build-utils/sign_delivery.py').read_text())
        self.assertIn('allCompiledCodeAndDataSectionsUnchangedBySigning',(ROOT/'build-utils/delivery_benchmark.py').read_text())

    def test_final_payload_check_rejects_changed_device_code(self):
        benchmark=module('delivery_benchmark')
        header=struct.pack('<8I',0xfeedfacf,0x0100000c,0,2,2,176,0,0)
        segment=struct.pack('<II16sQQQQIIII',0x19,152,b'__TEXT',0x100000000,4096,0,212,7,5,1,0)
        section=struct.pack('<16s16sQQIIIIIIII',b'__text',b'__TEXT',0x1000000d0,4,208,2,0,0,0x80000400,0,0,0)
        version=struct.pack('<6I',0x32,24,2,0x00110400,0x001a0200,0)
        original=header+segment+section+version+b'ABCD'
        self.assertNotEqual(benchmark.payload_fingerprint(original),benchmark.payload_fingerprint(original[:-1]+b'E'))

    def test_artifact_encryption_round_trip(self):
        cipher=module('delivery_cipher')
        with tempfile.TemporaryDirectory() as temp:
            folder=Path(temp);(folder/'build-utils').mkdir();source=folder/'source';source.mkdir()
            (source/'NeoStation.ipa').write_bytes(b'private delivery fixture')
            private=folder/'key.pem';public=folder/'build-utils/delivery-422-recipient.pem'
            subprocess.run(['openssl','genpkey','-algorithm','RSA','-pkeyopt','rsa_keygen_bits:2048','-out',str(private)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            subprocess.run(['openssl','pkey','-in',str(private),'-pubout','-out',str(public)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            cipher.ROOT=folder
            cipher.artifact(source,folder/'encrypted')
            password=folder/'password';archive=folder/'archive.tar'
            subprocess.run(['openssl','pkeyutl','-decrypt','-inkey',str(private),'-in',str(folder/'encrypted/password.rsa'),'-out',str(password),'-pkeyopt','rsa_padding_mode:oaep','-pkeyopt','rsa_oaep_md:sha256'],check=True)
            cipher.aes(folder/'encrypted/artifact.tar.enc',archive,password,decrypt=True)
            import tarfile
            with tarfile.open(archive) as tar:
                self.assertEqual(tar.extractfile('./NeoStation.ipa').read(),b'private delivery fixture')

    def test_compilation_cache_rejects_tampering(self):
        from unittest.mock import patch
        cipher=module('delivery_cipher')
        with tempfile.TemporaryDirectory() as temp:
            folder=Path(temp);fixture=folder/'fixture';fixture.mkdir()
            (fixture/'code').write_bytes(b'compiled fixture')
            cipher.ROOT=folder;cipher.CACHE_PATHS=['fixture']
            with patch.dict(os.environ,{'SCREENSCRAPER_DEV_PASSWORD':'test-only-secret','GITHUB_SHA':'a'*40,'BUILD_NUMBER':'422'}):
                cipher.cache()
                (fixture/'code').unlink()
                cipher.cache(True)
                self.assertEqual((fixture/'code').read_bytes(),b'compiled fixture')
                blob=folder/'.ci-cache/device-state.enc'
                raw=bytearray(blob.read_bytes());raw[-1]^=1;blob.write_bytes(raw)
                with self.assertRaisesRegex(ValueError,'authentication failed'):cipher.cache(True)

if __name__=='__main__': unittest.main(verbosity=2)
