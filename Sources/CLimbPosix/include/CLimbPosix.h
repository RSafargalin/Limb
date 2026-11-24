#ifndef CLIMB_POSIX_H
#define CLIMB_POSIX_H

#include <stddef.h>

int limb_thread_stack_bounds(void **address, size_t *size);

int limb_cloexec_pipe(int *descriptors);
void limb_name_current_thread(const char *name);

#endif
