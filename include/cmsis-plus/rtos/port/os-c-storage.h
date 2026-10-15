/*
 * The POSIX port's C object storage sizes, in pointer words (included by
 * the kernel's os-c-decls.h). A thread here carries a glibc ucontext_t,
 * signal mask and FPU state included, so os_thread_t needs more room than
 * the kernel's default. Keep in sync with `c_storage_words` in src/port.zig.
 */

#ifndef CMSIS_PLUS_RTOS_PORT_OS_C_STORAGE_H_
#define CMSIS_PLUS_RTOS_PORT_OS_C_STORAGE_H_

#define OS_C_THREAD_STORAGE_WORDS (192)

#endif /* CMSIS_PLUS_RTOS_PORT_OS_C_STORAGE_H_ */
