/*
 * µOS++ minimal C runtime (Zig kernel, Options.c_runtime): assert.h.
 * A failed assertion ends in the Zig panic handler (src/libc.zig).
 */

#undef assert

#if defined(NDEBUG)
#define assert(expr) ((void)0)
#else
#define assert(expr)                                                         \
  ((expr) ? (void)0 : __assert_func (__FILE__, __LINE__, __func__, #expr))
#endif

#ifndef UOS_C_ASSERT_H_
#define UOS_C_ASSERT_H_

#ifdef __cplusplus
extern "C"
{
#endif

  void
  __assert_func (const char* file, int line, const char* func,
                 const char* expr) __attribute__ ((noreturn));

#if !defined(__cplusplus)
#define static_assert _Static_assert
#endif

#ifdef __cplusplus
}
#endif

#endif /* UOS_C_ASSERT_H_ */
