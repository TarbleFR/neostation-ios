"""Compatibility normalization for the generated embedded Dolphin core."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def allow_this_module() -> None:
    guard = ROOT / 'build-utils/check_dolphin_isolation_v2.py'
    if not guard.is_file():
        return
    text = guard.read_text(encoding='utf-8')
    if '"build-utils/usercustomize/__init__.py",' not in text:
        text = text.replace(
            '    "build-utils/sitecustomize/__init__.py",\n',
            '    "build-utils/sitecustomize/__init__.py",\n'
            '    "build-utils/usercustomize/__init__.py",\n',
        )
    guard.write_text(text, encoding='utf-8')


def patch_core_generator() -> None:
    generator = ROOT / 'build-utils/patch_dolphin_internal_core_v2.py'
    if not generator.is_file():
        return
    text = generator.read_text(encoding='utf-8')

    text = text.replace(
        '#include <thread>\n',
        '#include <thread>\n#include <pthread.h>\n#include <sys/mman.h>\n',
    )

    old_probe = r'''  constexpr std::size_t probe_size = 0x4000;
  void* rx = Common::AllocateExecutableMemory(probe_size);
  if (rx == nullptr)
  {
    Log("jit.executable_probe_failed", "Dolphin returned no RX probe page.");
    return false;
  }
  const std::ptrdiff_t writable_difference =
      Common::AllocateWritableRegionAndGetDiff(rx, probe_size);
  if (writable_difference == 0)
  {
    Log("jit.executable_probe_failed", "Dolphin returned no writable alias.");
    return false;
  }

  auto* rw = reinterpret_cast<std::uint32_t*>(
      reinterpret_cast<std::uint8_t*>(rx) + writable_difference);
  // mov w0, #42 ; ret
  rw[0] = 0x52800540;
  rw[1] = 0xD65F03C0;
  sys_icache_invalidate(rx, 2 * sizeof(std::uint32_t));
  using Probe = int (*)();
  const int value = reinterpret_cast<Probe>(rx)();
  if (value != 42)
  {
    Log("jit.executable_probe_failed", "Generated ARM64 code returned an unexpected value.");
    return false;
  }
'''
    new_probe = r'''  constexpr std::size_t probe_size = 0x4000;
  void* probe = mmap(nullptr, probe_size,
                     PROT_READ | PROT_WRITE | PROT_EXEC,
                     MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
  if (probe == MAP_FAILED)
  {
    Log("jit.executable_probe_failed", "MAP_JIT probe allocation failed.");
    return false;
  }

  pthread_jit_write_protect_np(0);
  auto* instructions = reinterpret_cast<std::uint32_t*>(probe);
  // mov w0, #42 ; ret
  instructions[0] = 0x52800540;
  instructions[1] = 0xD65F03C0;
  sys_icache_invalidate(probe, 2 * sizeof(std::uint32_t));
  pthread_jit_write_protect_np(1);

  using Probe = int (*)();
  const int value = reinterpret_cast<Probe>(probe)();
  munmap(probe, probe_size);
  if (value != 42)
  {
    Log("jit.executable_probe_failed", "Generated ARM64 code returned an unexpected value.");
    return false;
  }
'''
    if old_probe in text:
        text = text.replace(old_probe, new_probe, 1)

    text = text.replace(
        '''  if (Config::Get(Config::MAIN_CPU_CORE) == PowerPC::CPUCore::JITARM64 &&
      PowerPC::GetCPUCore() != nullptr)
''',
        '''  if (Config::Get(Config::MAIN_CPU_CORE) == PowerPC::CPUCore::JITARM64 &&
      Core::IsRunning(Core::System::GetInstance()))
''',
    )

    generator.write_text(text, encoding='utf-8')


allow_this_module()
patch_core_generator()
