/*
 * The host C interfaces the POSIX port uses, translated by the build
 * (translate-c) into the `host_c` module: the same headers the C++
 * os-core.cpp, host_cpu.cpp and exception_handler.cpp include.
 *
 * The context switch is glibc's <ucontext.h> (getcontext, makecontext,
 * swapcontext), as the C++ smp branch builds it (no libucontext).
 */

#define _GNU_SOURCE 1

#include <dlfcn.h>
#include <errno.h>
#include <execinfo.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/utsname.h>
#include <time.h>
#include <ucontext.h>
#include <unistd.h>
