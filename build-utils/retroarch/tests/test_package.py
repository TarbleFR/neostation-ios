import importlib.util
import json
from pathlib import Path
import struct
import sys
import unittest
import zipfile

SCRIPT=Path(__file__).resolve().parents[1]/'package_ipa.py'
spec=importlib.util.spec_from_file_location('retroarch_package',SCRIPT)
package=importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


def dylib(platform=2,dependency='/usr/lib/libSystem.B.dylib',kind=6,cpu=0x0100000c):
    name=dependency.encode()+b'\0'
    size=(24+len(name)+7)&~7
    dep=struct.pack('<6I',0xc,size,24,0,0,0)+name+b'\0'*(size-24-len(name))
    version=struct.pack('<6I',0x32,24,platform,18<<16,18<<16,0)
    header=struct.pack('<8I',0xfeedfacf,cpu,0,kind,2,len(dep)+len(version),0,0)
    return header+dep+version


class PackageValidation(unittest.TestCase):
    def test_valid_device_dylib(self):
        result=package.macho(dylib())
        self.assertEqual(result['platform'],'iOS')
        self.assertEqual(result['architectures'],['arm64'])

    def test_original_one_slice_fat_supported_without_thinning(self):
        thin=dylib()
        fat=struct.pack('>7I',0xcafebabe,1,0x0100000c,0,32,len(thin),2)+b'\0'*4+thin
        self.assertEqual(package.macho(fat)['architectures'],['arm64'])

    def test_wrong_platform_and_executable_rejected(self):
        for data in [dylib(platform=7),dylib(platform=1),dylib(kind=2),dylib(cpu=0x01000007)]:
            with self.assertRaises(ValueError):package.macho(data)

    def test_private_and_host_paths_rejected(self):
        for dependency in ['/opt/homebrew/lib/libSDL.dylib','/tmp/libcore.dylib','/System/Library/PrivateFrameworks/Unsafe.framework/Unsafe']:
            with self.assertRaises(ValueError):package.macho(dylib(dependency=dependency))

    def test_archive_paths_and_symlinks_rejected(self):
        for name in ['../../Game.rom','/tmp/Game.rom','assets/../../outside','assets\\..\\outside']:
            with self.assertRaises(ValueError):package.safe_name(zipfile.ZipInfo(name))
        link=zipfile.ZipInfo('assets/link');link.external_attr=0o120777<<16
        with self.assertRaises(ValueError):package.safe_name(link)

    def test_manifest_has_exact_conservative_subset_and_identity(self):
        ids={c['id'] for c in package.PINS['cores']}
        self.assertEqual(ids,{'fceumm','nestopia','snes9x','gambatte','sameboy','mgba','genesis_plus_gx','picodrive','mednafen_pce_fast','pcsx_rearmed','mednafen_psx'})
        self.assertFalse(ids & package.FORBIDDEN)
        self.assertEqual(package.PINS['frontend']['commit'],'3a6a1e9c4fb4e90044945f84138ae7fad687e1a4')
        for c in package.PINS['cores']:
            self.assertRegex(c['sha256'],r'^[a-f0-9]{64}$')
            self.assertEqual(c['binary'].split('/')[0],'Frameworks')
        systems={s for c in package.PINS['cores'] for s in c['systemIds']}
        self.assertNotIn('3ds',systems)
        self.assertNotIn('n64',systems)
        self.assertNotIn('psp',systems)
        self.assertNotIn('nds',systems)

if __name__=='__main__':unittest.main()
