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

    def test_manifest_has_exact_reviewed_catalogue_and_pinned_supplement(self):
        audit=json.loads((SCRIPT.parent/'appstore-candidate-audit.json').read_text())
        candidates={c['id']:c for c in audit['softwareCandidatePins']}
        ids={c['id'] for c in package.PINS['cores']}
        self.assertEqual(ids,set(candidates)|{'ppsspp','mupen64plus_next'})
        self.assertEqual(len(candidates),85)
        self.assertEqual([c['id'] for c in package.PINS['cores'][:11]],
            ['fceumm','nestopia','snes9x','gambatte','sameboy','mgba','genesis_plus_gx','picodrive','mednafen_pce_fast','pcsx_rearmed','mednafen_psx'])
        self.assertFalse(ids & package.FORBIDDEN)
        self.assertEqual(package.PINS['frontend']['commit'],'3a6a1e9c4fb4e90044945f84138ae7fad687e1a4')
        for c in package.PINS['cores']:
            self.assertRegex(c['sha256'],r'^[a-f0-9]{64}$')
            self.assertEqual(c['binary'].split('/')[0],'Frameworks')
            if c['id'] in candidates:
                for key,value in candidates[c['id']].items():self.assertEqual(c[key],value)
                self.assertEqual(c['input'],'sourceIpa')
        psp=next(c for c in package.PINS['cores'] if c['id']=='ppsspp')
        self.assertEqual(psp['input'],'supplemental-ppsspp')
        self.assertEqual(psp['forcedOptions'],{'ppsspp_cpu_core':'Interpreter','ppsspp_backend':'opengl'})
        self.assertEqual(psp['sha256'],package.psp_tool().PINS['coreArchive']['binarySha256'])
        systems={s for c in package.PINS['cores'] for s in c['systemIds']}
        self.assertNotIn('3ds',systems)
        self.assertTrue({'ds','psp','pspminis','n64'}<=systems)

    def test_hardware_profile_rejects_dynarec_and_other_renderers(self):
        mupen=next(c for c in package.PINS['cores'] if c['id']=='mupen64plus_next')
        data=b'3.0-Vulkan 12edd2c\0'
        parsed={'hw_render':'true'}
        package.check_hardware_profile(mupen,parsed,data)
        for key,value in [('mupen64plus-cpucore','dynamic_recompiler'),('mupen64plus-rdp-plugin','parallel'),('mupen64plus-rsp-plugin','parallel')]:
            changed={**mupen,'forcedOptions':{**mupen['forcedOptions'],key:value}}
            with self.assertRaises(ValueError):package.check_hardware_profile(changed,parsed,data)
        with self.assertRaises(ValueError):package.check_hardware_profile(mupen,parsed,b'3.0-Vulkan unknown\0')
        with self.assertRaises(ValueError):package.check_hardware_profile({'id':'other'},parsed,data)

    def test_optional_dynarecs_and_dos_voodoo_remain_constrained(self):
        cores={c['id']:c for c in package.PINS['cores']}
        self.assertEqual(cores['mednafen_saturn']['forcedOptions'],
            {'beetle_saturn_sh2_jit':'disabled','beetle_saturn_jit_scu':'disabled','beetle_saturn_jit_scsp':'disabled'})
        self.assertEqual(cores['dosbox_pure']['forcedOptions'],
            {'dosbox_pure_cpu_core':'normal','dosbox_pure_voodoo_perf':'auto'})
        self.assertIs(cores['dosbox_pure']['runtimeProfile']['hardwareRenderingAllowed'],False)
        self.assertIs(cores['dosbox_pure']['runtimeProfile']['iosDynarecCompiled'],False)

    def test_numeric_firmware_required_and_optional_metadata(self):
        parsed=package.parse_info(b'firmware_count = 2\nfirmware0_path = "scph5500.bin"\nfirmware0_desc = "JP BIOS"\nfirmware0_opt = "false"\nfirmware1_path = "bios_CD_U.bin"\nfirmware1_opt = "true"\n')
        self.assertEqual(parsed['firmware_count'],'2')
        self.assertEqual(package.firmware_entries(parsed),[
            {'path':'scph5500.bin','description':'JP BIOS','optional':False},
            {'path':'bios_CD_U.bin','description':'bios_CD_U.bin','optional':True}])
        with self.assertRaises(ValueError):package.firmware_entries({'firmware_count':'1','firmware0_path':'../BIOS.bin'})
        pins={c['id']:c for c in package.PINS['cores']}
        self.assertEqual(len(pins['bsnes']['firmware']),20)
        self.assertTrue(any(not f['optional'] for f in pins['mednafen_psx']['firmware']))

if __name__=='__main__':unittest.main()
