/*
 * µOS++ minimal C runtime (Zig kernel, Options.c_runtime): stdlib.h, the
 * end of the run (the C++ src/libc/stdlib/exit.c, src/libc.zig).
 */

#ifndef UOS_C_STDLIB_H_
#define UOS_C_STDLIB_H_

#include <stddef.h>

#define EXIT_SUCCESS 0
#define EXIT_FAILURE 1

#ifdef __cplusplus
extern "C"
{
#endif

  /* Trace "exit(N)", then _Exit(). */
  void
  exit (int code) __attribute__ ((noreturn));

  /* The statistics, then the port's os_terminate() (a semihosting SYS_EXIT
     on the test boards). */
  void
  _Exit (int code) __attribute__ ((noreturn));

  void
  _exit (int code) __attribute__ ((noreturn));

  /* "abort(), exiting...", then _Exit(1). */
  void
  abort (void) __attribute__ ((noreturn));

#ifdef __cplusplus
}
#endif

#endif /* UOS_C_STDLIB_H_ */
