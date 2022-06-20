#ifndef ILBAR_UTIL_H
#define ILBAR_UTIL_H

#include <stdarg.h>

#if defined(__GNUC__) || defined(__clang__)
#define UNUSED(_arg_) _unused_ ## _arg_ __attribute__((__unused__))
#else
#define UNUSED(_arg_) _unused_ ## _arg_
#endif

char *alloc_vprint(const char *fmt, va_list arg);

char *alloc_print(const char *fmt, ...);

#endif
