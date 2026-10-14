/*
 * This file is part of the µOS++ project (https://micro-os-plus.github.io/).
 * Copyright (c) 2016-2025 Liviu Ionescu. All rights reserved.
 *
 * Permission to use, copy, modify, and/or distribute this software for any
 * purpose is hereby granted, under the terms of the MIT license.
 *
 * If a copy of the license was not distributed with this file, it can be
 * obtained from https://opensource.org/licenses/mit.
 */

/*
 * The µOS++ C API declarations, for the Zig kernel.
 *
 * The types, enumerations and attributes are those of the C++ os-c-decls.h.
 * The objects (os_thread_t, os_mutex_t, ...) are different: in C++ they
 * mirror the C++ class members; here they are opaque storage, large enough
 * for the Zig objects. The application only allocates them and passes
 * pointers to the API, it never reads their members.
 *
 * The storage sizes are in pointer words; src/c_storage.zig holds the same
 * numbers and checks at compile time that each Zig object fits.
 */

#ifndef CMSIS_PLUS_RTOS_OS_C_STRUCTS_H_
#define CMSIS_PLUS_RTOS_OS_C_STRUCTS_H_

// ----------------------------------------------------------------------------

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

// What the Zig kernel always provides.
#define OS_INCLUDE_RTOS_STATISTICS_THREAD_CONTEXT_SWITCHES
#define OS_INCLUDE_RTOS_STATISTICS_THREAD_CPU_CYCLES
#define OS_HAS_INTERRUPTS_STACK

// Storage sizes, in pointer words (keep in sync with src/c_storage.zig).
#define OS_C_THREAD_STORAGE_WORDS (56)
#define OS_C_TIMER_STORAGE_WORDS (20)
#define OS_C_MUTEX_STORAGE_WORDS (20)
#define OS_C_CONDVAR_STORAGE_WORDS (8)
#define OS_C_SEMAPHORE_STORAGE_WORDS (10)
#define OS_C_MEMPOOL_STORAGE_WORDS (24)
#define OS_C_MQUEUE_STORAGE_WORDS (32)
#define OS_C_EVFLAGS_STORAGE_WORDS (10)

#ifdef __cplusplus
extern "C"
{
#endif

  // --------------------------------------------------------------------------

  typedef uint32_t os_result_t;

  typedef uint32_t os_flags_mode_t;
  typedef uint32_t os_flags_mask_t;

  enum
  {
    os_flags_mode_all = 1, //
    os_flags_mode_any = 2, //
    os_flags_mode_clear = 4 //
  };

#define os_flags_any 0
#define os_flags_all 0xFFFFFFFF

  typedef bool os_sched_state_t;
  typedef uint32_t os_irq_state_t;

  typedef uint64_t os_clock_timestamp_t;
  typedef uint32_t os_clock_duration_t;
  typedef int64_t os_clock_offset_t;

  typedef void* os_iterator_t;

  typedef uint64_t os_statistics_counter_t;
  typedef uint64_t os_statistics_duration_t;

  // --------------------------------------------------------------------------
  // Threads.

#define OS_THREAD_PRIO_SHIFT (4)

  enum
  {
    os_thread_priority_none = 0, // not defined
    os_thread_priority_idle = (1 << OS_THREAD_PRIO_SHIFT),
    os_thread_priority_lowest = (2 << OS_THREAD_PRIO_SHIFT), // lowest
    os_thread_priority_low = (2 << OS_THREAD_PRIO_SHIFT),
    os_thread_priority_below_normal = (4 << OS_THREAD_PRIO_SHIFT),
    os_thread_priority_normal = (6 << OS_THREAD_PRIO_SHIFT), // default
    os_thread_priority_above_normal = (8 << OS_THREAD_PRIO_SHIFT),
    os_thread_priority_high = (10 << OS_THREAD_PRIO_SHIFT),
    os_thread_priority_realtime = (12 << OS_THREAD_PRIO_SHIFT),
    os_thread_priority_highest = (((13 + 1) << OS_THREAD_PRIO_SHIFT) - 1),
    os_thread_priority_isr = (((14 + 1) << OS_THREAD_PRIO_SHIFT) - 1),
    os_thread_priority_error = (((15 + 1) << OS_THREAD_PRIO_SHIFT) - 1)
  };

  enum
  {
    os_thread_state_undefined = 0,
    os_thread_state_ready = 1,
    os_thread_state_running = 2,
    os_thread_state_suspended = 3,
    os_thread_state_terminated = 4,
    os_thread_state_destroyed = 5,
    os_thread_state_initialising = 6,
    os_thread_state_destroying = 7
  };

  typedef void* os_thread_func_args_t;
  typedef void* (*os_thread_func_t) (os_thread_func_args_t args);

  typedef uint8_t os_thread_state_t;
  typedef uint8_t os_thread_prio_t;

  typedef uint32_t os_thread_stack_element_t;
  typedef uint64_t os_thread_stack_allocation_element_t;

  // The same layout as the Zig `rtos.ThreadStack` (an extern struct).
  typedef struct os_thread_stack_s
  {
    void* stack_addr;
    size_t stack_size_bytes;
  } os_thread_stack_t;

  typedef struct os_thread_attr_s
  {
    void* clock;
    void* th_stack_address;
    size_t th_stack_size_bytes;
    os_thread_prio_t th_priority;
    bool th_enable_assert_reuse;
    // Always present (the C++ one only with OS_USE_SMP_SCHEDULER).
    uint32_t th_cpu_affinity;
  } os_thread_attr_t;

  typedef struct os_thread_s
  {
    _Alignas (8) void* storage[OS_C_THREAD_STORAGE_WORDS];
  } os_thread_t;

  // --------------------------------------------------------------------------
  // Clocks.

  typedef struct os_clock_s os_clock_t;

  // --------------------------------------------------------------------------
  // Timers.

  enum
  {
    os_timer_once = 0, //
    os_timer_periodic = 1 //
  };

  typedef void* os_timer_func_args_t;
  typedef void (*os_timer_func_t) (os_timer_func_args_t args);

  typedef uint8_t os_timer_type_t;
  typedef uint8_t os_timer_state_t;

  typedef struct os_timer_attr_s
  {
    void* clock;
    os_timer_type_t tm_type;
  } os_timer_attr_t;

  typedef struct os_timer_s
  {
    _Alignas (8) void* storage[OS_C_TIMER_STORAGE_WORDS];
  } os_timer_t;

  // --------------------------------------------------------------------------
  // Mutexes.

  typedef int16_t os_mutex_count_t;
  typedef uint8_t os_mutex_type_t;
  typedef uint8_t os_mutex_protocol_t;
  typedef uint8_t os_mutex_robustness_t;

  enum
  {
    os_mutex_protocol_none = 0,
    os_mutex_protocol_inherit = 1,
    os_mutex_protocol_protect = 2,
    os_mutex_protocol_default = os_mutex_protocol_inherit
  };

  enum
  {
    os_mutex_robustness_stalled = 0,
    os_mutex_robustness_robust = 1,
    os_mutex_robustness_default = os_mutex_robustness_stalled
  };

  enum
  {
    os_mutex_type_normal = 0,
    os_mutex_type_errorcheck = 1,
    os_mutex_type_recursive = 2,
    os_mutex_type_default = os_mutex_type_normal
  };

  typedef struct os_mutex_attr_s
  {
    void* clock;
    os_thread_prio_t mx_priority_ceiling;
    os_mutex_protocol_t mx_protocol;
    os_mutex_robustness_t mx_robustness;
    os_mutex_type_t mx_type;
    os_mutex_count_t mx_max_count;
  } os_mutex_attr_t;

  typedef struct os_mutex_s
  {
    _Alignas (8) void* storage[OS_C_MUTEX_STORAGE_WORDS];
  } os_mutex_t;

  // --------------------------------------------------------------------------
  // Condition variables.

  typedef struct os_condvar_attr_s
  {
    void* clock;
  } os_condvar_attr_t;

  typedef struct os_condvar_s
  {
    _Alignas (8) void* storage[OS_C_CONDVAR_STORAGE_WORDS];
  } os_condvar_t;

  // --------------------------------------------------------------------------
  // Semaphores.

  typedef int16_t os_semaphore_count_t;

  typedef struct os_semaphore_attr_s
  {
    void* clock;
    os_semaphore_count_t sm_max_value;
    os_semaphore_count_t sm_initial_value;
  } os_semaphore_attr_t;

  typedef struct os_semaphore_s
  {
    _Alignas (8) void* storage[OS_C_SEMAPHORE_STORAGE_WORDS];
  } os_semaphore_t;

  // --------------------------------------------------------------------------
  // Memory pools.

  typedef uint16_t os_mempool_size_t;

  typedef struct os_mempool_attr_s
  {
    void* clock;
    void* mp_pool_address;
    size_t mp_pool_size_bytes;
  } os_mempool_attr_t;

  typedef struct os_mempool_s
  {
    _Alignas (8) void* storage[OS_C_MEMPOOL_STORAGE_WORDS];
  } os_mempool_t;

  // --------------------------------------------------------------------------
  // Message queues.

  typedef uint16_t os_mqueue_size_t;
  typedef uint16_t os_mqueue_msg_size_t;
  typedef os_mqueue_size_t os_mqueue_index_t;
  typedef uint8_t os_mqueue_prio_t;

  typedef struct os_mqueue_attr_s
  {
    void* clock;
    void* mq_queue_addr;
    size_t mq_queue_size_bytes;
  } os_mqueue_attr_t;

  typedef struct os_mqueue_s
  {
    _Alignas (8) void* storage[OS_C_MQUEUE_STORAGE_WORDS];
  } os_mqueue_t;

  // --------------------------------------------------------------------------
  // Event flags.

  typedef struct os_evflags_attr_s
  {
    void* clock;
  } os_evflags_attr_t;

  typedef struct os_evflags_s
  {
    _Alignas (8) void* storage[OS_C_EVFLAGS_STORAGE_WORDS];
  } os_evflags_t;

  // --------------------------------------------------------------------------
  // Memory resources.

  typedef struct os_memory_s os_memory_t;

  // --------------------------------------------------------------------------

#ifdef __cplusplus
}
#endif

#endif /* CMSIS_PLUS_RTOS_OS_C_STRUCTS_H_ */
