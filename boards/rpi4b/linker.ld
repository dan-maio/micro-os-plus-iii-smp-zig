/*
 * linker.ld - µOS++ IIIe AArch64 for Raspberry Pi 4 B (BCM2711, 4x Cortex-A72).
 * Loaded at 0x80000 in DRAM by QEMU raspi4b -kernel, firmware kernel8.img, or OpenOCD JTAG.
 */

OUTPUT_FORMAT("elf64-littleaarch64")
OUTPUT_ARCH(aarch64)
ENTRY(_start)

STACK_SIZE   = 0x100000;   /* 1 MiB core 0 */
W_STACK_SIZE = 0x80000;    /* 512 KiB each cores 1-3 */

MEMORY
{
    RAM (rwx) : ORIGIN = 0x00080000, LENGTH = 0x3B380000   /* 0x80000 .. 0x3B3FFFFF */
}

SECTIONS
{
    . = ORIGIN(RAM);

    .text : ALIGN(8) {
        KEEP(*(.text.boot))     /* _start + vector_table first */
        *(.text*)
    } > RAM

    .rodata : ALIGN(8) {
        *(.rodata*)
    } > RAM

    .data : ALIGN(8) {
        __data_start = .;       /* for the tutorial's region checks */
        *(.data*)
        *(.got*)
        __data_end = .;
    } > RAM

    .bss (NOLOAD) : ALIGN(16) {
        __bss_start = .;
        *(.bss*)
        *(COMMON)
        . = ALIGN(16);
        __bss_end = .;
    } > RAM

    /* Per-core stacks (SP_EL1) */
    .stack (NOLOAD) : ALIGN(16) {
        . = . + STACK_SIZE;   __stack_top = .;
        . = . + W_STACK_SIZE; __stack_top_core1 = .;
        . = . + W_STACK_SIZE; __stack_top_core2 = .;
        . = . + W_STACK_SIZE; __stack_top_core3 = .;
    } > RAM

    /* The end of the image. The RAM from here to the end of RAM (board.zig
       ram_end) is the free store: port.freeRam() hands it to the heap. */
    _end = .;

    /DISCARD/ : {
        *(.comment)
        *(.note*)
    }
}
