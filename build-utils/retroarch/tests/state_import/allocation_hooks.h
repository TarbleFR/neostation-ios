/* Harness-only hook, applied only while compiling the production importer. */
#ifndef NEO_STATE_IMPORT_ALLOCATION_HOOKS_H
#define NEO_STATE_IMPORT_ALLOCATION_HOOKS_H
#include <stddef.h>
void *neo_state_import_test_malloc(size_t size);
void neo_state_import_test_free(void *data);
#endif
