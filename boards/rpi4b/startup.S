/*
 * startup.S - Multicore AArch64 startup for µOS++ IIIe on Raspberry Pi 4 B
 *             (BCM2711, 4x Cortex-A72).
 *
 * Handles:
 *   - EL3/EL2 entry -> drop to non-secure EL1h
 *   - FP/SIMD enable (CPACR_EL1)
 *   - Vector table installation (VBAR_EL1)
 *   - Core 0: stack, BSS zeroing, mmu_init, jump to uos_core0_main
 *   - Cores 1-3: park in spin table, wake on release, mmu_enable, boot_coreN
 *   - Full 800-byte scheduler context switch (x0-x30, SPSR, ELR, FPSR, FPCR, q0-q31)
 *   - SMP deferred publication protocol (_smp_pub_addr / _smp_pub_val)
 *   - Preemptive IRQ and cooperative context switch handlers
 */

	.equ FRAME, 800
	.equ PORT_RAM_BASE, 0x00080000
	.equ PORT_RAM_END,  0x3B400000

/* ------------------------------------------------------------------ macros */

	.macro SAVE_FRAME
	sub	sp, sp, #FRAME
	stp	x0,  x1,  [sp, #0]
	stp	x2,  x3,  [sp, #16]
	stp	x4,  x5,  [sp, #32]
	stp	x6,  x7,  [sp, #48]
	stp	x8,  x9,  [sp, #64]
	stp	x10, x11, [sp, #80]
	stp	x12, x13, [sp, #96]
	stp	x14, x15, [sp, #112]
	stp	x16, x17, [sp, #128]
	stp	x18, x19, [sp, #144]
	stp	x20, x21, [sp, #160]
	stp	x22, x23, [sp, #176]
	stp	x24, x25, [sp, #192]
	stp	x26, x27, [sp, #208]
	stp	x28, x29, [sp, #224]
	str	x30,      [sp, #240]
	mrs	x0, spsr_el1
	mrs	x1, elr_el1
	stp	x0, x1,   [sp, #248]
	mrs	x0, fpsr
	mrs	x1, fpcr
	stp	x0, x1,   [sp, #264]
	stp	q0,  q1,  [sp, #288]
	stp	q2,  q3,  [sp, #320]
	stp	q4,  q5,  [sp, #352]
	stp	q6,  q7,  [sp, #384]
	stp	q8,  q9,  [sp, #416]
	stp	q10, q11, [sp, #448]
	stp	q12, q13, [sp, #480]
	stp	q14, q15, [sp, #512]
	stp	q16, q17, [sp, #544]
	stp	q18, q19, [sp, #576]
	stp	q20, q21, [sp, #608]
	stp	q22, q23, [sp, #640]
	stp	q24, q25, [sp, #672]
	stp	q26, q27, [sp, #704]
	stp	q28, q29, [sp, #736]
	stp	q30, q31, [sp, #768]
	.endm

	.macro RESTORE_FRAME_ERET
	ldp	q0,  q1,  [sp, #288]
	ldp	q2,  q3,  [sp, #320]
	ldp	q4,  q5,  [sp, #352]
	ldp	q6,  q7,  [sp, #384]
	ldp	q8,  q9,  [sp, #416]
	ldp	q10, q11, [sp, #448]
	ldp	q12, q13, [sp, #480]
	ldp	q14, q15, [sp, #512]
	ldp	q16, q17, [sp, #544]
	ldp	q18, q19, [sp, #576]
	ldp	q20, q21, [sp, #608]
	ldp	q22, q23, [sp, #640]
	ldp	q24, q25, [sp, #672]
	ldp	q26, q27, [sp, #704]
	ldp	q28, q29, [sp, #736]
	ldp	q30, q31, [sp, #768]
	ldp	x2, x3,   [sp, #264]
	msr	fpsr, x2
	msr	fpcr, x3
	ldp	x2, x3,   [sp, #248]
	msr	spsr_el1, x2
	msr	elr_el1, x3
	ldp	x2,  x3,  [sp, #16]
	ldp	x4,  x5,  [sp, #32]
	ldp	x6,  x7,  [sp, #48]
	ldp	x8,  x9,  [sp, #64]
	ldp	x10, x11, [sp, #80]
	ldp	x12, x13, [sp, #96]
	ldp	x14, x15, [sp, #112]
	ldp	x16, x17, [sp, #128]
	ldp	x18, x19, [sp, #144]
	ldp	x20, x21, [sp, #160]
	ldp	x22, x23, [sp, #176]
	ldp	x24, x25, [sp, #192]
	ldp	x26, x27, [sp, #208]
	ldp	x28, x29, [sp, #224]
	ldr	x30,      [sp, #240]
	ldp	x0,  x1,  [sp, #0]
	add	sp, sp, #FRAME
	eret
	.endm

	/* SMP deferred publish: once SP leaves the outgoing thread's stack,
	 * store {&old->stack_ptr = frame} so other cores may claim it. */
	.macro SMP_PUBLISH
	mrs	x9, mpidr_el1
	and	x9, x9, #0xFF
	adrp	x10, _smp_pub_addr
	add	x10, x10, #:lo12:_smp_pub_addr
	ldr	x11, [x10, x9, lsl #3]
	cbz	x11, 99f
	adrp	x12, _smp_pub_val
	add	x12, x12, #:lo12:_smp_pub_val
	ldr	x13, [x12, x9, lsl #3]
	str	x13, [x11]
	str	xzr, [x10, x9, lsl #3]
	dmb	ish
99:
	.endm

/* ---------------------------------------------------------------- boot */
	.section .text.boot, "ax"
	.global _start
_start:
	msr	daifset, #0xf              // mask D,A,I,F

	mrs	x0, CurrentEL
	lsr	x0, x0, #2
	cmp	x0, #3
	b.eq	el3_entry                 // EL3 -> drop to EL2 first
el2_check:
	mrs	x0, CurrentEL
	lsr	x0, x0, #2
	cmp	x0, #2
	b.ne	el1_entry                 // already at EL1 -> proceed

	/* ---- EL2 setup, drop to EL1 ---- */
	mrs	x0, sctlr_el2
	bic	x0, x0, #(1 << 1)
	bic	x0, x0, #(1 << 3)
	bic	x0, x0, #(1 << 4)
	msr	sctlr_el2, x0

	// Do not trap FP/SIMD to EL2
	mov	x0, #0x33ff
	msr	cptr_el2, x0

	// Let EL1 use physical counter/timer (CNTHCTL_EL2.EL1PCTEN|EL1PCEN)
	mrs	x0, cnthctl_el2
	orr	x0, x0, #0x3
	msr	cnthctl_el2, x0
	msr	cntvoff_el2, xzr

	// EL1 runs in AArch64
	mov	x0, #(1 << 31)
	msr	hcr_el2, x0

	// Minimal SCTLR_EL1 (MMU/caches off, DZE set for memset)
	ldr	x0, =0x30d04800
	msr	sctlr_el1, x0

	// Return to EL1h with all interrupts masked
	mov	x0, #0x3c5                // DAIF=1111, M=EL1h(0b0101)
	msr	spsr_el2, x0
	adr	x0, el1_entry
	msr	elr_el2, x0
	eret

	/* ---- EL3 setup ---- */
el3_entry:
	mrs	x0, cntfrq_el0
	cbnz	x0, 1f
	ldr	x0, =54000000             // BCM2711 generic timer 54 MHz
	msr	cntfrq_el0, x0
1:	msr	cptr_el3, xzr
	mov	x0, #0x5b1                // NS | RES1 | SMD | HCE | RW
	msr	scr_el3, x0
	mov	x0, #0x3c9                // EL2h, DAIF masked
	msr	spsr_el3, x0
	adr	x0, el2_check
	msr	elr_el3, x0
	eret

el1_entry:
	// Enable FP/SIMD at EL1/EL0 (CPACR_EL1.FPEN = 0b11)
	mov	x0, #(3 << 20)
	msr	cpacr_el1, x0
	isb

	// Install exception vectors
	adrp	x0, vector_table
	add	x0, x0, #:lo12:vector_table
	msr	vbar_el1, x0
	isb

	// Dispatch by MPIDR.Aff0
	mrs	x0, mpidr_el1
	and	x0, x0, #0xFF
	cbz	x0, core0_start
	b	secondary_park

/* ---------------------------------------------------------- core 0 */
core0_start:
	ldr	x0, =__stack_top
	mov	sp, x0

	// Zero .bss
	ldr	x0, =__bss_start
	ldr	x1, =__bss_end
1:	cmp	x0, x1
	b.hs	2f
	str	xzr, [x0], #8
	b	1b
2:
	bl	mmu_init
	bl	uos_core0_main
hang0:	wfe
	b	hang0

/* ------------------------------------------------ secondary cores 1-3 */
	.global secondary_park
secondary_park:
	mrs	x4, mpidr_el1
	and	x4, x4, #0xFF
	ldr	x5, =__smp_spin
1:	wfe
	ldr	x6, [x5, x4, lsl #3]       // __smp_spin[core]
	cbz	x6, 1b
	br	x6

	.global core1_entry, core2_entry, core3_entry
core1_entry:
	ldr	x0, =__stack_top_core1
	mov	sp, x0
	bl	mmu_enable
	bl	boot_core1
1:	wfe
	b	1b

core2_entry:
	ldr	x0, =__stack_top_core2
	mov	sp, x0
	bl	mmu_enable
	bl	boot_core2
1:	wfe
	b	1b

core3_entry:
	ldr	x0, =__stack_top_core3
	mov	sp, x0
	bl	mmu_enable
	bl	boot_core3
1:	wfe
	b	1b

/* ---------------------------------------------- cooperative switch */
	.global port_reschedule_call
port_reschedule_call:
	stp	x29, x30, [sp, #-16]!
	mov	x29, sp
	bl	port_ctx_switch_handler
	ldp	x29, x30, [sp], #16
	ret

	.global port_ctx_switch_handler
port_ctx_switch_handler:
	mrs	x9, daif
	orr	x9, x9, #1               // M[0]
	orr	x9, x9, #4               // M[2] -> M = 0b0101 (EL1h)
	msr	daifset, #2               // mask IRQ
	msr	spsr_el1, x9
	msr	elr_el1, x30
	SAVE_FRAME
	mov	x0, sp
	bl	port_switch_stacks        // x0 = next thread's frame SP

	ldr	x1, =PORT_RAM_BASE
	cmp	x0, x1
	b.lo	.Lcoop_corrupt
	ldr	x1, =PORT_RAM_END
	cmp	x0, x1
	b.hs	.Lcoop_corrupt

	mov	sp, x0
	SMP_PUBLISH
	RESTORE_FRAME_ERET

.Lcoop_corrupt:
	msr	daifset, #0xf
	mov	x1, sp
	bl	port_ctx_switch_corrupt
3:	wfi
	b	3b

/* ---------------------------------------------- EL1 vector table */
	.section .text.boot, "ax"
	.align 11
	.global vector_table
vector_table:
	// Current EL with SP0 (unused)
	.align 7
	mov	x19, #0x1
	b	fatal_from_vec
	.align 7
	mov	x19, #0x2
	b	fatal_from_vec
	.align 7
	mov	x19, #0x3
	b	fatal_from_vec
	.align 7
	mov	x19, #0x4
	b	fatal_from_vec

	// Current EL with SPx (EL1h: where threads run and take exceptions)
	.align 7
	b	sync_current
	.align 7
	b	irq_current
	.align 7
	b	irq_current               // FIQ -> same scheduler path
	.align 7
	mov	x19, #0x14
	b	fatal_from_vec

	// Lower EL, AArch64
	.align 7
	mov	x19, #0x21
	b	fatal_from_vec
	.align 7
	mov	x19, #0x22
	b	fatal_from_vec
	.align 7
	mov	x19, #0x23
	b	fatal_from_vec
	.align 7
	mov	x19, #0x24
	b	fatal_from_vec

	// Lower EL, AArch32
	.align 7
	mov	x19, #0x31
	b	fatal_from_vec
	.align 7
	mov	x19, #0x32
	b	fatal_from_vec
	.align 7
	mov	x19, #0x33
	b	fatal_from_vec
	.align 7
	mov	x19, #0x34
	b	fatal_from_vec

/* Preemptive IRQ / FIQ handler */
irq_current:
	SAVE_FRAME
	mov	x0, sp
	bl	port_isr_handler          // returns frame SP to resume
	mov	sp, x0
	SMP_PUBLISH
	RESTORE_FRAME_ERET

sync_current:
	mov	x19, #0x11
	b	fatal_from_vec

fatal_from_vec:
	SAVE_FRAME
	mov	x0, x19
	mrs	x1, esr_el1
	mrs	x2, elr_el1
	mrs	x3, far_el1
	mrs	x4, spsr_el1
	bl	port_fatal_exception
1:	wfi
	b	1b
