/* Initial curated App Store-compatible frontend: interpreted cores only.
 * Do not probe, attach to, or reconfigure NeoStation's other JIT backends.
 * GPL-3.0-or-later.
 */
#include <stdbool.h>
#include <stddef.h>
#include <libretro.h>
bool jit_available(void) { return false; }
bool jit_possible(void) { return false; }
bool exec_mem_pool_init(void) { return false; }
void exec_mem_pool_reset(void) { }
bool exec_mem_alloc(size_t *size, unsigned *mode, void **rx, void **rw) {
  if (mode) *mode = RETRO_EXEC_MEM_MODE_UNAVAILABLE;
  if (rx) *rx = NULL;
  if (rw) *rw = NULL;
  return false;
}
void exec_mem_free(void *rx, void *rw, size_t size, bool dual) { }
