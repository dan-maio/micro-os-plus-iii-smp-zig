/*
 * cmsis-os-validator on the Zig port: checks of what the Zig CMSIS-RTOS v1
 * layer (micro-os-plus-iii/src/cmsis_os.zig) assumes about the C side.
 */

#include <cmsis_os.h>

// cmsis_os.zig reads the enums as C int.
_Static_assert (sizeof (osStatus) == sizeof (int), "osStatus is not an int");
_Static_assert (sizeof (osPriority) == sizeof (int), "osPriority is not an int");
_Static_assert (sizeof (os_timer_type) == sizeof (int), "os_timer_type is not an int");
