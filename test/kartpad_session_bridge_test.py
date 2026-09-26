#!/usr/bin/env python3
"""Execute the checked donor frame bridge, including normal-return epilogue.
No missing emulator skip. --runtime verifies the exact IPA/donor bytes too.
"""
from pathlib import Path
import argparse, random, struct, sys, unittest
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'build-utils/kartpad'))
import patch_donor_session_bridge as bridge
from patch_donor_language_bridge import parse_macho, load_symbols, vm_to_file
from unicorn import Uc, UC_ARCH_ARM64, UC_MODE_ARM, UC_HOOK_CODE
from unicorn import arm64_const as arm

SLIDES=(0,0x1000,0x4000,0x47f1000,0x400000000)

def exercise(patches, slide, stop, seed):
    u=Uc(UC_ARCH_ARM64,UC_MODE_ARM)
    pages=set()
    def put(addr, data):
        for page in range(addr&~4095,(addr+len(data)+4095)&~4095,4096):
            if page not in pages: u.mem_map(page,4096);pages.add(page)
        u.mem_write(addr,data)
    for address, code in patches.items(): put(address+slide,code)
    for address in (bridge.FRAME+4+slide,bridge.RUN+16+slide): put(address,b'\x1f\x20\x03\xd5')
    cpu=0x1234567100; native_sp=0x2345678800; done=0x3456789000; callback=0x345678a000
    put(cpu-0x100,b'\xA5'*4096);put(native_sp-0x800,b'\x5A'*4096)
    put(done,b'\x1f\x20\x03\xd5');put(callback,struct.pack('<I',0xd65f03c0))
    put(bridge.CONTROL+slide,struct.pack('<QQ',callback,callback))
    rng=random.Random(seed)
    values=[rng.getrandbits(64) for _ in range(31)]
    values[19]=cpu
    for i,value in enumerate(values):u.reg_write(getattr(arm,f'UC_ARM64_REG_X{i}'),value)
    qvalues=[rng.getrandbits(128) for _ in range(32)]
    for i,value in enumerate(qvalues):u.reg_write(getattr(arm,f'UC_ARM64_REG_Q{i}'),value)
    u.reg_write(arm.UC_ARM64_REG_SP,native_sp)
    u.reg_write(arm.UC_ARM64_REG_FPCR,0x01000000)
    u.reg_write(arm.UC_ARM64_REG_FPSR,0x0800009F)
    flags=0xA0000000;u.reg_write(arm.UC_ARM64_REG_NZCV,flags)
    # Actual run prologue saved callee registers into its 0xc0-byte frame.
    caller={}
    for r1,r2,offset in ((28,27,0x60),(26,25,0x70),(24,23,0x80),(22,21,0x90),(20,19,0xa0),(29,30,0xb0)):
        first=rng.getrandbits(64);second=done if r2==30 else rng.getrandbits(64)
        caller[r1]=first;caller[r2]=second;u.mem_write(native_sp+offset,struct.pack('<QQ',first,second))
    stack_before=bytes(u.mem_read(native_sp,0xc0))
    memory_before=bytes(u.mem_read(cpu-0x100,4096))
    calls=[]
    def host(uc,address,size,unused):
        if address!=callback:return
        calls.append(address)
        assert uc.reg_read(arm.UC_ARM64_REG_X0)==cpu
        assert uc.reg_read(arm.UC_ARM64_REG_SP)%16==0
        # Deliberately trash ALL caller/callee regs except host return address/SP:
        # the native bridge must preserve more than ordinary C ABI guarantees.
        for i in range(30):uc.reg_write(getattr(arm,f'UC_ARM64_REG_X{i}'),0xBAD000+i)
        for i in range(32):uc.reg_write(getattr(arm,f'UC_ARM64_REG_Q{i}'),i+3)
        uc.reg_write(arm.UC_ARM64_REG_NZCV,0x50000000)
        uc.reg_write(arm.UC_ARM64_REG_FPCR,0)
        uc.reg_write(arm.UC_ARM64_REG_FPSR,0)
        uc.reg_write(arm.UC_ARM64_REG_X0,int(stop))
    u.hook_add(UC_HOOK_CODE,host)
    finish=done if stop else bridge.FRAME+slide+4
    u.emu_start(bridge.FRAME+slide,finish,count=500)
    assert u.reg_read(arm.UC_ARM64_REG_PC)==finish
    assert len(calls)==1
    assert bytes(u.mem_read(cpu-0x100,4096))==memory_before
    assert bytes(u.mem_read(native_sp,0xc0))==stack_before
    assert u.reg_read(arm.UC_ARM64_REG_NZCV)==flags
    assert u.reg_read(arm.UC_ARM64_REG_FPCR)==0x01000000
    assert u.reg_read(arm.UC_ARM64_REG_FPSR)==0x0800009F
    for i,value in enumerate(values):
        expected=caller.get(i,value) if stop else value
        if not stop and i in (6,17):expected=0xA5A5A5A5 # relocated original LDP
        assert u.reg_read(getattr(arm,f'UC_ARM64_REG_X{i}'))==expected,(i,stop,hex(slide))
    for i,value in enumerate(qvalues):assert u.reg_read(getattr(arm,f'UC_ARM64_REG_Q{i}'))==value
    assert u.reg_read(arm.UC_ARM64_REG_SP)==native_sp+(0xc0 if stop else 0)

class SessionBridgeTest(unittest.TestCase):
    def test_machine_registers_stack_memory_and_return_all_slides(self):
        for slide in SLIDES:
            for stop in (False,True):
                for seed in range(10):
                    with self.subTest(slide=slide,stop=stop,seed=seed):exercise(bridge.expected_patches(),slide,stop,seed)
    def test_guest_exit_call_routes_to_host_without_changing_lr_or_cpu(self):
        for slide in SLIDES:
            u=Uc(UC_ARCH_ARM64,UC_MODE_ARM)
            done=bridge.EXIT_CALL+slide+4
            callback=0x4567800000
            for addr in (bridge.EXIT_CALL+slide,bridge.EXIT_GATE+slide,bridge.CONTROL+slide,callback):
                u.mem_map(addr&~4095,4096)
            patches=bridge.expected_patches()
            for addr in (bridge.EXIT_CALL,bridge.EXIT_GATE):u.mem_write(addr+slide,patches[addr])
            u.mem_write(bridge.CONTROL+slide+16,struct.pack('<Q',callback))
            u.mem_write(callback,struct.pack('<I',0xD65F03C0))
            u.reg_write(arm.UC_ARM64_REG_X0,0x123456789100)
            u.reg_write(arm.UC_ARM64_REG_SP,0x2345678000)
            u.emu_start(bridge.EXIT_CALL+slide,done,count=12)
            self.assertEqual(u.reg_read(arm.UC_ARM64_REG_PC),done)
            self.assertEqual(u.reg_read(arm.UC_ARM64_REG_X0),0x123456789100)
            self.assertEqual(u.reg_read(arm.UC_ARM64_REG_SP),0x2345678000)
            self.assertEqual(u.reg_read(arm.UC_ARM64_REG_X30),done)

    def test_reentrant_process_guards_are_exact(self):
        self.assertEqual(
            bridge.cond_branch(bridge.SELECT_FROZEN_BRANCH,
                               bridge.SELECT_FROZEN_RETURN, 0),
            0x54000F00,
        )
        self.assertEqual(
            bridge.cbz_w(17, bridge.DVD_REGISTER_GATE + 8,
                         bridge.DVD_REGISTER_GATE + 16),
            0x34000051,
        )
        gate = bridge.dvd_register_gate_bytes()
        self.assertEqual(len(gate), 36)
        self.assertEqual(gate[12:16], bytes.fromhex("c0035fd6"))
        self.assertEqual(gate[16:32], bridge.REGISTER_FILE_PROLOGUE)
        self.assertEqual(len(bridge.dvd_directory_gate_bytes()), 20)

    def test_dvd_second_session_excludes_synthetic_directories(self):
        # BuildAndPublishRuntimeFst rewrites the host vector with FST indexed
        # entries after the first session. On reentry the root is a directory,
        # not a RegisteredFile; the unguarded loop produced dvd_fst fatal.
        patches = bridge.expected_patches()
        for slide in SLIDES:
            for directory in (False, True):
                with self.subTest(slide=slide, directory=directory):
                    u = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
                    for addr in (bridge.DVD_DIRECTORY_LOOP + slide,
                                 bridge.DVD_DIRECTORY_GATE + slide,
                                 0x3456000000):
                        u.mem_map(addr & ~4095, 4096)
                    for addr in (bridge.DVD_DIRECTORY_LOOP, bridge.DVD_DIRECTORY_GATE):
                        u.mem_write(addr + slide, patches[addr])
                    entry = 0x3456000000
                    u.mem_write(entry + 0x17, b'\x35')  # source string tag
                    u.mem_write(entry + 0x38, bytes([int(directory)]))
                    u.reg_write(arm.UC_ARM64_REG_X19, entry)
                    stop = (bridge.DVD_DIRECTORY_NEXT if directory else
                            bridge.DVD_DIRECTORY_LOOP + 4) + slide
                    u.emu_start(bridge.DVD_DIRECTORY_LOOP + slide, stop, count=10)
                    self.assertEqual(u.reg_read(arm.UC_ARM64_REG_PC), stop)
                    if not directory:
                        self.assertEqual(u.reg_read(arm.UC_ARM64_REG_W8), 0x35)
                    self.assertEqual(u.reg_read(arm.UC_ARM64_REG_X19), entry)

    def test_branch_range_validation(self):
        for pc,dest in ((0,1),(0,1<<28)):
            with self.assertRaises(SystemExit):bridge.branch(pc,dest)
    def test_entry_hook_and_original_prologue_trampoline(self):
        u=Uc(UC_ARCH_ARM64,UC_MODE_ARM)
        for start,length in ((bridge.RUN&~4095,8192),(bridge.TRAMPOLINE&~4095,4096),(bridge.CONTROL&~4095,4096),(0x1234500000,8192)):
            u.mem_map(start,length)
        patches=bridge.expected_patches()
        u.mem_write(bridge.RUN,patches[bridge.RUN]);u.mem_write(bridge.TRAMPOLINE,patches[bridge.TRAMPOLINE])
        # Bind mock host directly to trampoline to observe original prologue.
        u.mem_write(bridge.CONTROL,struct.pack('<Q',bridge.TRAMPOLINE))
        u.reg_write(arm.UC_ARM64_REG_SP,0x1234501000)
        u.reg_write(arm.UC_ARM64_REG_X0,0x123456789ABC)
        u.emu_start(bridge.RUN,bridge.RUN+16,count=20)
        self.assertEqual(u.reg_read(arm.UC_ARM64_REG_PC),bridge.RUN+16)
        self.assertEqual(u.reg_read(arm.UC_ARM64_REG_SP),0x1234501000-0xc0)
        self.assertEqual(u.reg_read(arm.UC_ARM64_REG_X0),0x123456789ABC)


def run_statefree(data, symbol, arg):
    segments,table=parse_macho(data);symbols,_=load_symbols(data,table)
    address=symbols[symbol];offset=vm_to_file(segments,address)
    u=Uc(UC_ARCH_ARM64,UC_MODE_ARM);u.mem_map(address&~4095,8192)
    u.mem_write(address,data[offset:offset+1100]);done=0x1230000000;u.mem_map(done,4096)
    u.reg_write(arm.UC_ARM64_REG_X30,done);u.reg_write(arm.UC_ARM64_REG_X0,arg)
    u.emu_start(address,done,count=2000)
    assert u.reg_read(arm.UC_ARM64_REG_PC)==done
    return u.reg_read(arm.UC_ARM64_REG_Q0)&0xffffffff

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--runtime',type=Path);args=p.parse_args()
    result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(SessionBridgeTest))
    if not result.wasSuccessful():raise SystemExit(1)
    if args.runtime:
        data=args.runtime.read_bytes();report=bridge.validate(data)
        segments,_=parse_macho(data)
        patches={address:data[vm_to_file(segments,address):vm_to_file(segments,address)+len(code)] for address,code in bridge.expected_patches().items()}
        for slide in SLIDES:
            for stop in (False,True):exercise(patches,slide,stop,71)
        # Actual donor instructions prove why TitleFromReset must NOT be used:
        # priority 5 triggers SystemManager::RestartGame from ExitSection.
        assert run_statefree(data,'_func_80634B80_statefree',0x40)==5
        assert run_statefree(data,'_func_80634B80_statefree',0x3f)==1
        assert run_statefree(data,'_func_80631588_statefree',0x3f)==1
        # The actual donor has a process-lifetime data-section guard. The
        # previous session clears guest .sdata, while the old guard skips its
        # reloading, leaving OS::__ThreadInit's callback pointer zero.
        _,table=parse_macho(data);symbols,_=load_symbols(data,table)
        init=symbols['_InitializeDataSections']
        flag=symbols['__ZN12_GLOBAL__N_117g_dataInitializedE']
        assert init==0x10010c72c and flag==0x1051b2208
        guard=init+0x14
        assert data[vm_to_file(segments,guard):vm_to_file(segments,guard)+16]==bytes.fromhex(
            '288502d0092148394940003729008052')
        for initial, expected_pc, expected_flag in ((0,init+0x34,1),(1,init+0x824,1)):
            u=Uc(UC_ARCH_ARM64,UC_MODE_ARM)
            u.mem_map(init&~4095,4096)
            u.mem_map(flag&~4095,4096)
            u.mem_write(guard,data[vm_to_file(segments,guard):vm_to_file(segments,guard)+0x20])
            u.mem_write(flag,bytes([initial]))
            u.emu_start(guard,expected_pc,count=10)
            assert u.reg_read(arm.UC_ARM64_REG_PC)==expected_pc
            assert u.mem_read(flag,1)==bytes([expected_flag])
        print('PASS: exact donor gate; 0x40 system-reset hazard reproduced; safe 0x3f menu scene verified',report)
    print('PASS: 100 machine-state frame-gate cases, native epilogue and entry trampoline')
