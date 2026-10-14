/*
 * cmsis-os-validator on the Zig port: the part of CMSIS-Core the validator
 * uses (NVIC enable/disable/pend, __NOP, SystemCoreClock). The vendor
 * headers are not used; these are the architectural registers, the same on
 * every Cortex-M.
 */

#ifndef CMSIS_DEVICE_H_
#define CMSIS_DEVICE_H_

#include <stdint.h>

#ifdef __cplusplus
extern "C"
{
#endif

  typedef int IRQn_Type;

#define UOS_NVIC_ISER ((volatile uint32_t*)0xE000E100u)
#define UOS_NVIC_ICER ((volatile uint32_t*)0xE000E180u)
#define UOS_NVIC_ISPR ((volatile uint32_t*)0xE000E200u)

  static inline void
  NVIC_EnableIRQ (IRQn_Type irq)
  {
    UOS_NVIC_ISER[(uint32_t)irq >> 5] = 1u << ((uint32_t)irq & 31u);
  }

  static inline void
  NVIC_DisableIRQ (IRQn_Type irq)
  {
    UOS_NVIC_ICER[(uint32_t)irq >> 5] = 1u << ((uint32_t)irq & 31u);
    __asm__ volatile ("dsb 0xF" ::: "memory");
    __asm__ volatile ("isb 0xF" ::: "memory");
  }

  static inline void
  NVIC_SetPendingIRQ (IRQn_Type irq)
  {
    UOS_NVIC_ISPR[(uint32_t)irq >> 5] = 1u << ((uint32_t)irq & 31u);
  }

  static inline void
  __NOP (void)
  {
    __asm__ volatile ("nop");
  }

  // The core clock, in Hz; main.zig keeps it (the SysTick input clock).
  extern uint32_t SystemCoreClock;

  void
  SystemCoreClockUpdate (void);

#ifdef __cplusplus
}
#endif

#endif /* CMSIS_DEVICE_H_ */
