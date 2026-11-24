//! USART1 console driver for the WeAct F412RE (PA9/PA10), the C++
//! test/boards/weactf412/src/uart.cpp: reception interrupt driven (RXNE),
//! transmission DMA driven (DMA2 Stream7, channel 4).
//!
//!   RX: the RXNE interrupt pushes bytes into a 256-byte ring and posts
//!       `rx_ready`; `readChar()` waits on it.
//!   TX: a 512-byte ring is drained by DMA2 Stream7. The transfer-complete
//!       interrupt advances the tail, posts `tx_free` and starts the next
//!       contiguous chunk. `putChar()` waits on `tx_free`.
//!
//! The two handlers run at NVIC priority 5 (masked by the kernel's critical
//! sections, more urgent than PendSV/SysTick) and only touch registers and
//! post semaphores, as in C++.
//!
//! Zig addition: `traceWrite()`, the kernel trace's way in. The trace runs
//! in any context (a tick handler, a critical section, before the
//! scheduler), where it must not block: when the ring is full it services
//! the DMA completion itself, by polling, instead of waiting on `tx_free`.

const uos = @import("uos");
const rtos = uos.rtos;

const RCC_AHB1ENR: *volatile u32 = @ptrFromInt(0x4002_3830);
const RCC_APB2ENR: *volatile u32 = @ptrFromInt(0x4002_3844);

const GPIOA_MODER: *volatile u32 = @ptrFromInt(0x4002_0000);
const GPIOA_OTYPER: *volatile u32 = @ptrFromInt(0x4002_0004);
const GPIOA_OSPEEDR: *volatile u32 = @ptrFromInt(0x4002_0008);
const GPIOA_PUPDR: *volatile u32 = @ptrFromInt(0x4002_000C);

const USART1_SR: *volatile u32 = @ptrFromInt(0x4001_1000);
const USART1_DR: *volatile u32 = @ptrFromInt(0x4001_1004);
const USART1_BRR: *volatile u32 = @ptrFromInt(0x4001_1008);
const USART1_CR1: *volatile u32 = @ptrFromInt(0x4001_100C);
const USART1_CR3: *volatile u32 = @ptrFromInt(0x4001_1014);
const SR_RXNE: u32 = 1 << 5;
const SR_TC: u32 = 1 << 6;
const CR1_RE: u32 = 1 << 2;
const CR1_TE: u32 = 1 << 3;
const CR1_RXNEIE: u32 = 1 << 5;
const CR1_UE: u32 = 1 << 13;
const CR3_DMAT: u32 = 1 << 7;

const DMA2_HISR: *volatile u32 = @ptrFromInt(0x4002_6404);
const DMA2_HIFCR: *volatile u32 = @ptrFromInt(0x4002_640C);
const S7_CR: *volatile u32 = @ptrFromInt(0x4002_64B8);
const S7_NDTR: *volatile u32 = @ptrFromInt(0x4002_64BC);
const S7_PAR: *volatile u32 = @ptrFromInt(0x4002_64C0);
const S7_M0AR: *volatile u32 = @ptrFromInt(0x4002_64C4);
const S7_TCIF: u32 = 1 << 27;
const S7_ALL_FLAGS: u32 = (1 << 22) | (1 << 24) | (1 << 25) | (1 << 26) | (1 << 27);
const SxCR_EN: u32 = 1 << 0;
const SxCR_TCIE: u32 = 1 << 4;
const SxCR_DIR_M2P: u32 = 1 << 6;
const SxCR_MINC: u32 = 1 << 10;
const SxCR_PL_HIGH: u32 = 1 << 17;
const SxCR_CHSEL_4: u32 = 4 << 25;

pub const usart1_irq: u32 = 37;
pub const dma2_stream7_irq: u32 = 70;

const TX_SIZE = 512;
const RX_SIZE = 256;

var tx_buf: [TX_SIZE]u8 = undefined;
var tx_head: usize = 0;
var tx_tail: usize = 0;
var tx_chunk: usize = 0;
var tx_active: bool = false;

var rx_buf: [RX_SIZE]u8 = undefined;
var rx_head: usize = 0;
var rx_tail: usize = 0;

// Free slots in the TX ring (producer waits) and received bytes (consumer
// waits). Posted by the device interrupt handlers.
var tx_free: rtos.Semaphore = .counting("uart-tx-free", TX_SIZE - 1, TX_SIZE - 1);
var rx_ready: rtos.Semaphore = .counting("uart-rx-ready", RX_SIZE, 0);

var ready = false;

fn ringNext(i: usize, size: usize) usize {
    const n = i + 1;
    return if (n == size) 0 else n;
}

inline fn mask() u32 {
    const p = asm volatile ("mrs %[p], primask"
        : [p] "=r" (-> u32),
    );
    asm volatile ("cpsid i" ::: .{ .memory = true });
    return p;
}

inline fn unmask(p: u32) void {
    asm volatile ("msr primask, %[p]"
        :
        : [p] "r" (p),
        : .{ .memory = true });
}

fn gpioConfigAf(comptime pin: u5, comptime af: u32) void {
    // MODER: 10 = alternate function; push-pull, high speed, no pull.
    GPIOA_MODER.* = (GPIOA_MODER.* & ~(@as(u32, 3) << (@as(u5, pin) * 2))) | (@as(u32, 2) << (@as(u5, pin) * 2));
    GPIOA_OTYPER.* &= ~(@as(u32, 1) << pin);
    GPIOA_OSPEEDR.* |= @as(u32, 3) << (@as(u5, pin) * 2);
    GPIOA_PUPDR.* &= ~(@as(u32, 3) << (@as(u5, pin) * 2));
    // AFR[0] for pins 0..7, AFR[1] for pins 8..15.
    const afr: *volatile u32 = @ptrFromInt(0x4002_0020 + 4 * @as(usize, pin / 8));
    const shift: u5 = @as(u5, pin % 8) * 4;
    afr.* = (afr.* & ~(@as(u32, 0xF) << shift)) | (af << shift);
}

// Start a DMA transfer for the contiguous chunk tail..head (or tail..end).
// The caller must hold a critical section.
fn txStart() void {
    if (tx_active or tx_tail == tx_head) return;
    const len = if (tx_head > tx_tail) tx_head - tx_tail else TX_SIZE - tx_tail;
    tx_chunk = len;
    tx_active = true;
    S7_CR.* &= ~SxCR_EN;
    while (S7_CR.* & SxCR_EN != 0) {}
    S7_M0AR.* = @intFromPtr(&tx_buf[tx_tail]);
    S7_NDTR.* = @intCast(len);
    S7_CR.* |= SxCR_EN;
}

fn irqEnable(comptime irq: u32) void {
    // Priority 5: numerically >= the kernel's critical-section level (so the
    // handler is masked while the kernel holds its lock and may signal), and
    // more urgent than PendSV/SysTick (both 15).
    const ipr: *volatile u8 = @ptrFromInt(0xE000_E400 + irq);
    ipr.* = 5 << 4;
    const icpr: *volatile u32 = @ptrFromInt(0xE000_E280 + 4 * (irq / 32));
    const iser: *volatile u32 = @ptrFromInt(0xE000_E100 + 4 * (irq / 32));
    iser.* = @as(u32, 1) << @intCast(irq % 32);
    icpr.* = @as(u32, 1) << @intCast(irq % 32);
}

fn rxPop() u8 {
    const p = mask();
    defer unmask(p);
    const b = rx_buf[rx_tail];
    rx_tail = ringNext(rx_tail, RX_SIZE);
    return b;
}

/// Configure USART1 (8N1) at `f_apb2_hz`, the RXNE interrupt and the TX DMA.
pub fn init(baud: u32, f_apb2_hz: u32) void {
    // Peripheral clocks: GPIOA (AHB1), DMA2 (AHB1) and USART1 (APB2).
    RCC_AHB1ENR.* |= (1 << 0) | (1 << 22);
    RCC_APB2ENR.* |= 1 << 4;
    _ = RCC_APB2ENR.*;

    gpioConfigAf(9, 7);
    gpioConfigAf(10, 7);

    USART1_CR1.* = 0; // disable while configuring
    // BRR = round(f_apb2 / baud) (OVER8 = 0).
    USART1_BRR.* = (f_apb2_hz + baud / 2) / baud;

    // --- TX DMA: DMA2 Stream7, channel 4, memory -> peripheral ----------
    S7_CR.* &= ~SxCR_EN;
    while (S7_CR.* & SxCR_EN != 0) {}
    DMA2_HIFCR.* = S7_ALL_FLAGS;
    S7_PAR.* = @intFromPtr(USART1_DR);
    S7_M0AR.* = @intFromPtr(&tx_buf);
    S7_NDTR.* = 0;
    S7_CR.* = SxCR_CHSEL_4 | SxCR_MINC | SxCR_DIR_M2P | SxCR_PL_HIGH | SxCR_TCIE;
    USART1_CR3.* |= CR3_DMAT;

    // Enable transmitter, receiver and the USART itself (8N1, no parity).
    USART1_CR1.* = CR1_TE | CR1_RE | CR1_UE;
    // Clear any pending flag before enabling the RX interrupt.
    _ = USART1_SR.*;
    _ = USART1_DR.*;
    USART1_CR1.* |= CR1_RXNEIE;

    irqEnable(usart1_irq);
    irqEnable(dma2_stream7_irq);
    ready = true;
}

/// Enqueue one byte (blocks while the TX ring is full). The DMA drains it.
pub fn putChar(c: u8) void {
    tx_free.wait() catch {};
    const p = mask();
    defer unmask(p);
    tx_buf[tx_head] = c;
    tx_head = ringNext(tx_head, TX_SIZE);
    txStart();
}

/// Enqueue `bytes`; '\n' is expanded to "\r\n".
pub fn write(bytes: []const u8) void {
    for (bytes) |c| {
        if (c == '\n') putChar('\r');
        putChar(c);
    }
}

/// Block until a received byte is available, then return it.
pub fn readChar() u8 {
    rx_ready.wait() catch {};
    return rxPop();
}

/// Wait up to `timeout_ms` for a byte; null on timeout.
pub fn timedReadChar(timeout_ms: u32) ?u8 {
    rx_ready.timedWait(timeout_ms) catch return null;
    return rxPop();
}

/// Non-blocking: the next received byte, or null if none.
pub fn tryReadChar() ?u8 {
    rx_ready.tryWait() catch return null;
    return rxPop();
}

/// Number of bytes waiting in the RX ring.
pub fn rxAvailable() usize {
    const p = mask();
    const head = rx_head;
    const tail = rx_tail;
    unmask(p);
    return if (head >= tail) head - tail else RX_SIZE - tail + head;
}

// ---- the trace's way in (Zig) ----------------------------------------------

/// The completion of a DMA chunk: the handler's body, also run by polling.
/// Interrupts masked by the caller.
fn txComplete() void {
    DMA2_HIFCR.* = S7_TCIF;
    const len = tx_chunk;
    var tail = tx_tail + len;
    if (tail >= TX_SIZE) tail -= TX_SIZE;
    tx_tail = tail;
    tx_active = false;
    for (0..len) |_| tx_free.post() catch {};
    txStart();
}

fn traceChar(c: u8) void {
    while (true) {
        if (tx_free.tryWait()) |_| break else |_| {}
        // Full: wait for the running chunk by polling and complete it here.
        const p = mask();
        if (tx_active and DMA2_HISR.* & S7_TCIF != 0) txComplete();
        unmask(p);
    }
    const p = mask();
    defer unmask(p);
    tx_buf[tx_head] = c;
    tx_head = ringNext(tx_head, TX_SIZE);
    txStart();
}

/// Enqueue the trace's bytes without ever blocking; '\n' -> "\r\n".
pub fn traceWrite(bytes: []const u8) void {
    if (!ready) return;
    for (bytes) |c| {
        if (c == '\n') traceChar('\r');
        traceChar(c);
    }
}

/// Send everything queued, by polling, and wait until the last byte left the
/// pin; usable with the interrupts masked (the end of the run).
pub fn flush() void {
    if (!ready) return;
    const p = mask();
    defer unmask(p);
    while (true) {
        if (tx_active) {
            while (DMA2_HISR.* & S7_TCIF == 0) {}
            txComplete();
        } else if (tx_head != tx_tail) {
            txStart();
        } else break;
    }
    while (USART1_SR.* & SR_TC == 0) {}
}

// ---- device interrupt handlers ---------------------------------------------

pub fn usart1Handler() callconv(.c) void {
    if (USART1_SR.* & SR_RXNE != 0) {
        const b: u8 = @truncate(USART1_DR.*);
        const next = ringNext(rx_head, RX_SIZE);
        if (next != rx_tail) {
            rx_buf[rx_head] = b;
            rx_head = next;
            rx_ready.post() catch {};
        }
        // else: ring full, drop the byte
    }
}

pub fn dma2Stream7Handler() callconv(.c) void {
    if (DMA2_HISR.* & S7_TCIF != 0) {
        const p = mask();
        defer unmask(p);
        txComplete();
    }
}
