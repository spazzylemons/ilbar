#include <stdio.h>
#include <stdlib.h>

#include "util.h"

char *alloc_vprint(const char *fmt, va_list arg) {
    va_list arg2;
    va_copy(arg2, arg);
    int n = vsnprintf(NULL, 0, fmt, arg) + 1;
    if (n <= 0) return NULL;
    char *buf = malloc(n);
    if (!buf) return NULL;
    vsnprintf(buf, n, fmt, arg2);
    return buf;
}

char *alloc_print(const char *fmt, ...) {
    va_list arg;
    va_start(arg, fmt);
    char *buf = alloc_vprint(fmt, arg);
    va_end(arg);
    return buf;
}
