/*
 * This file is part of the µOS++ project (https://micro-os-plus.github.io/).
 * Copyright (c) 2015-2025 Liviu Ionescu. All rights reserved.
 *
 * Permission to use, copy, modify, and/or distribute this software for any
 * purpose is hereby granted, under the terms of the MIT license.
 *
 * If a copy of the license was not distributed with this file, it can be
 * obtained from https://opensource.org/licenses/mit.
 */

/*
 * The µOS++ trace C API, for the Zig kernel: the output goes to the kernel
 * trace channel (uos.trace). Implemented in src/libc.zig (Options.c_runtime).
 * As in C++, without TRACE the calls compile to nothing.
 */

#ifndef CMSIS_PLUS_DIAG_TRACE_H_
#define CMSIS_PLUS_DIAG_TRACE_H_

#include <stdarg.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C"
{
#endif

#if defined(TRACE)

  int
  trace_printf (const char* format, ...)
      __attribute__ ((format (printf, 1, 2)));
  int
  trace_vprintf (const char* format, va_list ap);
  int
  trace_puts (const char* s);
  int
  trace_putchar (int c);
  // ssize_t in C++; freestanding C has no sys/types.h.
  ptrdiff_t
  trace_write (const void* buf, size_t nbyte);
  void
  trace_flush (void);

#else

#define trace_printf(...) ((void)0)
#define trace_vprintf(format, ap) ((void)0)
#define trace_puts(s) ((void)0)
#define trace_putchar(c) ((void)0)
#define trace_write(buf, nbyte) ((void)0)
#define trace_flush() ((void)0)

#endif

#ifdef __cplusplus
}
#endif

#endif /* CMSIS_PLUS_DIAG_TRACE_H_ */
