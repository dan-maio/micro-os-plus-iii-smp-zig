/*
 * µOS++ minimal C runtime (Zig kernel, Options.c_runtime): stdio.h.
 * The output goes to the trace channel. Implemented in src/libc.zig.
 */

#ifndef UOS_C_STDIO_H_
#define UOS_C_STDIO_H_

#include <stdarg.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C"
{
#endif

#define EOF (-1)

  int
  printf (const char* format, ...) __attribute__ ((format (printf, 1, 2)));
  int
  vprintf (const char* format, va_list ap);
  int
  snprintf (char* buf, size_t size, const char* format, ...)
      __attribute__ ((format (printf, 3, 4)));
  int
  vsnprintf (char* buf, size_t size, const char* format, va_list ap);
  int
  puts (const char* s);
  int
  putchar (int c);

#ifdef __cplusplus
}
#endif

#endif /* UOS_C_STDIO_H_ */
