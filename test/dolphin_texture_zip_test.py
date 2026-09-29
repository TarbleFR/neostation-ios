"""Exercise the production streaming ZIP reader; never load an entire HD pack into RAM."""
from pathlib import Path
import os,struct,subprocess,tempfile,warnings,zipfile
ROOT=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as temp:
    folder=Path(temp);binary=folder/'texture-zip'
    subprocess.run([os.environ.get('CXX','clang++'),'-std=c++20','-Wall','-Wextra','-Werror','-fsanitize=address,undefined','-I'+str(ROOT/'packages/dolphin_internal_bridge/ios/Classes'),str(ROOT/'test/dolphin_texture_zip_test.cpp'),'-lz','-o',str(binary)],check=True)
    payload=b'\x89PNG\r\n\x1a\n'+bytes(range(256))*400
    def run(name,entries,method=zipfile.ZIP_DEFLATED,mutate=None):
        archive=folder/(name+'.zip');dest=folder/name
        with warnings.catch_warnings():
            warnings.simplefilter('ignore',UserWarning)
            with zipfile.ZipFile(archive,'w',compression=method) as z:
                for path,data in entries:z.writestr(path,data)
        if mutate:archive.write_bytes(mutate(archive.read_bytes()))
        return subprocess.run([str(binary),str(archive),str(dest)],capture_output=True).returncode,dest
    for method in (zipfile.ZIP_STORED,zipfile.ZIP_DEFLATED):
        code,dest=run('valid'+str(method),[('Pack/Load/Textures/GR8P69/sub/tex1_a.png',payload),('README.txt',b'Info')],method)
        assert code==0 and (dest/'sub/tex1_a.png').read_bytes()==payload
    assert run('wrong-game',[('GR8E69/tex1_a.png',payload)])[0]!=0
    assert run('traversal',[('../GR8P69/tex1_a.png',payload)])[0]!=0
    assert run('absolute',[('/GR8P69/tex1_a.png',payload)])[0]!=0
    assert run('duplicate',[('GR8P69/tex1_a.png',payload),('GR8P69/tex1_a.png',payload)])[0]!=0
    assert run('case-duplicate',[('GR8P69/tex1_a.png',payload),('GR8P69/tex1_A.png',payload)])[0]!=0
    link=zipfile.ZipInfo('GR8P69/tex1_a.png');link.create_system=3;link.external_attr=0o120777<<16
    assert run('symlink',[(link,b'/some/file')])[0]!=0
    def corrupt_crc(data):
        b=bytearray(data);at=b.index(b'PK\x01\x02');b[at+16]^=1;return b
    assert run('bad-crc',[('GR8P69/tex1_a.png',payload)],mutate=corrupt_crc)[0]!=0
    def too_large(data):
        b=bytearray(data);at=b.index(b'PK\x01\x02');struct.pack_into('<I',b,at+24,128*1024*1024+1);return b
    assert run('oversize',[('GR8P69/tex1_a.png',payload)],mutate=too_large)[0]!=0
    assert run('truncated',[('GR8P69/tex1_a.png',payload)],mutate=lambda b:b[:-5])[0]!=0
print('PASS HD ZIP: stored/deflate roundtrip; exact GameID; traversal, links, duplicate/case collision, oversize, bad CRC and truncation rejected')
