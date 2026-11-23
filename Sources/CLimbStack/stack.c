#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <pthread.h>
#include "CLimbStack.h"

int limb_thread_stack_bounds(void **address, size_t *size) {
    pthread_attr_t attributes;
    int status = pthread_getattr_np(pthread_self(), &attributes);
    if (status == 0) {
        status = pthread_attr_getstack(&attributes, address, size);
        pthread_attr_destroy(&attributes);
    }
    return status;
}
