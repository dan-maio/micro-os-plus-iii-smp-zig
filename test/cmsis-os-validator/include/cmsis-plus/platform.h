/*
 * cmsis-os-validator on the Zig port: the platform header the suite's
 * os-app-config.h includes.
 *
 * The C++ platforms map ARM_CMSIS_VALIDATOR_IRQHandler to the vector of the
 * first external interrupt (WDT_IRQHandler on the Pico 2, WWDG_IRQHandler on
 * the STM32F4). Here main.zig installs IRQ 0 with uos_interrupts and calls
 * ARM_CMSIS_VALIDATOR_IRQHandler(), so nothing is needed.
 */

#ifndef CMSIS_PLUS_PLATFORM_H_
#define CMSIS_PLUS_PLATFORM_H_

#endif /* CMSIS_PLUS_PLATFORM_H_ */
