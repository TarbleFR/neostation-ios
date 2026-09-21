"""Behavior tests for the real Build302 pre-load reservation; no success stub."""
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
HEADERS = ROOT / 'packages/rpcs3_internal_bridge/ios/Classes'
with tempfile.TemporaryDirectory() as temp:
    exe = str(Path(temp) / 'reservation')
    subprocess.run(['c++', '-std=c++20', '-Wall', '-Wextra', '-Werror',
                    '-I', str(HEADERS), str(ROOT / 'test/native/rpcs3_arena_reservation_test.cpp'),
                    '-o', exe], check=True)
    subprocess.run([exe], check=True)
    if sys.platform == 'darwin':
        source = Path(temp) / 'real.cpp'
        source.write_text('''
#include "Rpcs3ArenaReservation.h"
#include <cassert>
int main() {
  neostation::rpcs3::arena::Reservation reservation;
  assert(reservation.acquire());
  assert(reservation.layout);
  assert(reservation.verify_owned());
  assert(reservation.discard() == 0);
  assert(!reservation.layout);
  assert(reservation.acquire());
  assert(reservation.discard() == 0);
}
''')
        subprocess.run(['clang++', '-std=c++20', '-I', str(HEADERS), str(source), '-o', exe], check=True)
        subprocess.run([exe], check=True)
        print('PASS: actual Darwin reservation/release/retry (not iPhone execution)')
