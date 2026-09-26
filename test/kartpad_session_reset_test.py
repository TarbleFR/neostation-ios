#!/usr/bin/env python3
"""Execute the real donor's VI poll across the old and new session boundary.

Only clock/mutex/guest-memory services are stubbed. The ARM64 poll, deadline,
callback selection and dispatch instructions come unchanged from the IPA.
"""
import argparse,hashlib,json,re,struct,sys
from pathlib import Path
from unicorn import Uc,UC_ARCH_ARM64,UC_MODE_ARM,UC_HOOK_CODE
from unicorn import arm64_const as arm
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'build-utils/kartpad'))
from patch_donor_language_bridge import parse_macho,load_symbols,vm_to_file
p=argparse.ArgumentParser();p.add_argument('--runtime',type=Path,required=True);a=p.parse_args()
data=a.runtime.read_bytes();segments,table=parse_macho(data);symbols,_=load_symbols(data,table)
for name,contract in json.loads((ROOT/'test/kartpad_session_reset_layout.json').read_text()).items():
    address=int(contract['address'],16)
    assert symbols[name]==address,name
    off=vm_to_file(segments,address)
    assert hashlib.sha256(data[off:off+contract['size']]).hexdigest()==contract['sha256'],name
header=(ROOT/'native/kartpad/core/DonorSessionReset.h').read_text()
for offset,raw in re.findall(r'matches\(base \+ (0x[0-9a-f]+), \{([^}]+)\}\)',header):
    expected=bytes(int(x,16) for x in raw.split(','))
    off=vm_to_file(segments,0x100000000+int(offset,16))
    assert data[off:off+len(expected)]==expected,offset

for slide in (0,0x4000,0x400000000):
    for cleaned in (False,True):
        u=Uc(UC_ARCH_ARM64,UC_MODE_ARM)
        pages=set()
        def put(address,value):
            for page in range(address&~4095,(address+len(value)+4095)&~4095,4096):
                if page not in pages:u.mem_map(page,4096);pages.add(page)
            u.mem_write(address,value)
        start=0x100190574; end=0x1001906a0
        off=vm_to_file(segments,0x100190280)
        put(0x100190280+slide,data[off:off+end-0x100190280])
        # This is the actual initialized flag and callback left by VIInit /
        # VISetPreRetraceCallback. Build343 retains both after guest RAM resets.
        state=bytearray(144)
        if not cleaned:
            state[0]=1
            struct.pack_into('<I',state,24,0xdeadbeec)
            struct.pack_into('<q',state,72,16666)
        put(0x1051bb000+slide,bytes(4096));put(0x1051bb2f0+slide,bytes(state))
        put(0x200000,bytes(8192));put(0x300000,bytes(8192))
        done=0x400000;put(done,struct.pack('<I',0xd65f03c0))
        targets={0x104544300:'clock',0x1045442c4:'lock',0x1045442d0:'unlock',
                 0x10019140c:'write',0x10007beac:'wake',0x100063ce4:'invoke'}
        for target in targets:put(target+slide,struct.pack('<I',0xd65f03c0))
        calls=[]
        def call(uc,address,size,_):
            kind=targets.get(address-slide)
            if kind=='clock':uc.reg_write(arm.UC_ARM64_REG_X0,1000000000)
            if kind=='invoke':calls.append(uc.reg_read(arm.UC_ARM64_REG_W0))
        u.hook_add(UC_HOOK_CODE,call)
        # Use AdvanceDueRetraces(serviceAurora=false), the same path installed
        # by RuntimeMain as ServiceGuestTimingDuringAuroraFrameWait.
        u.reg_write(arm.UC_ARM64_REG_PC,0x100190580+slide)
        u.reg_write(arm.UC_ARM64_REG_X0,0x200000)
        u.reg_write(arm.UC_ARM64_REG_W1,1)
        u.reg_write(arm.UC_ARM64_REG_W2,0)
        u.reg_write(arm.UC_ARM64_REG_SP,0x301800)
        u.reg_write(arm.UC_ARM64_REG_X30,done)
        u.emu_start(0x100190580+slide,done,count=1000)
        assert u.reg_read(arm.UC_ARM64_REG_PC)==done
        assert calls==([] if cleaned else [0xdeadbeec]),(slide,cleaned,calls)
print('PASS: Build343 dispatches the old guest callback before second VIInit; clean session state prevents it (3 ASLR slides).')
print('PASS: production reset witnesses and complete native accessor hashes match the packaged donor.')
