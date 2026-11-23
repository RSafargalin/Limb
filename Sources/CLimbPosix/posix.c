#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <fcntl.h>
#include <pthread.h>
#include <unistd.h>
#include "CLimbPosix.h"

int limb_thread_stack_bounds(void **address, size_t *size) {
    pthread_attr_t attributes;
    int status = pthread_getattr_np(pthread_self(), &attributes);
    if (status == 0) {
        status = pthread_attr_getstack(&attributes, address, size);
        pthread_attr_destroy(&attributes);
    }
    return status;
}

int limb_cloexec_pipe(int *descriptors) {
    return pipe2(descriptors, O_CLOEXEC);
}

void limb_name_current_thread(const char *name) {
    pthread_setname_np(pthread_self(), name);
}
