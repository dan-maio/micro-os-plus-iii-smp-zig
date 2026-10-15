/* linker.ld - the RK3506 Cortex-M0 firmware of smp-test-int5 (the C++
 * smp_test_int5/m0/linker.ld).
 *
 * Linked at 0x00000000: the M0 fetches its initial MSP and reset PC from the
 * vector table at offset 0, which the A7 maps to System SRAM (0xFFF80000) as
 * TCM. System SRAM is 48 KB: 32 KB code/vectors, then 16 KB data/stack. */

ENTRY(g_vectors)

MEMORY
{
    CODE (rx)  : ORIGIN = 0x00000000, LENGTH = 0x00008000
    DATA (rwx) : ORIGIN = 0x00008000, LENGTH = 0x00004000
}

_estack = ORIGIN(DATA) + LENGTH(DATA);

SECTIONS
{
    .isr_vector : { KEEP(*(.isr_vector)) } > CODE
    .text       : { *(.text*) *(.rodata*) } > CODE

    /* g_seq first: the A7 reads it at 0xFFF88000 (DATA's 0x8000). Nothing is
     * initialised at reset, so .data must stay empty. */
    .bss (NOLOAD) : {
        KEEP(*(.m0seq))
        *(.bss*) *(COMMON)
    } > DATA

    .data : { *(.data*) } > DATA AT > CODE
    ASSERT(SIZEOF(.data) == 0, "the M0 firmware must have no initialised data")

    /DISCARD/ : { *(.ARM.exidx*) *(.ARM.extab*) *(.comment) *(.note*) }
}
