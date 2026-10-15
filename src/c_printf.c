/*
 * c_printf.c -- C implementation of printf/vsnprintf for freestanding AArch64
 *
 * Provides AAPCS64 variadic C runtime support for C code linked with µOS++ IIIe.
 */

#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>

extern long trace_write(const char* buf, size_t nbyte);

int vsnprintf(char* buf, size_t size, const char* fmt, va_list ap) {
    size_t pos = 0;
    while (*fmt) {
        if (*fmt != '%') {
            if (buf && pos + 1 < size) buf[pos] = *fmt;
            pos++;
            fmt++;
            continue;
        }
        fmt++;
        if (*fmt == '%') {
            if (buf && pos + 1 < size) buf[pos] = '%';
            pos++;
            fmt++;
            continue;
        }
        if (*fmt == 'c') {
            int ch = va_arg(ap, int);
            if (buf && pos + 1 < size) buf[pos] = (char)ch;
            pos++;
            fmt++;
            continue;
        }
        if (*fmt == 's') {
            const char* s = va_arg(ap, const char*);
            if (!s) s = "(null)";
            while (*s) {
                if (buf && pos + 1 < size) buf[pos] = *s;
                pos++;
                s++;
            }
            fmt++;
            continue;
        }
        int is_unsigned = (*fmt == 'u' || *fmt == 'x' || *fmt == 'X' || *fmt == 'p');
        int is_hex = (*fmt == 'x' || *fmt == 'X' || *fmt == 'p');
        int is_upper = (*fmt == 'X');
        if (*fmt == 'd' || *fmt == 'i' || is_unsigned) {
            uint64_t val;
            if (*fmt == 'p') {
                val = (uintptr_t)va_arg(ap, void*);
                if (buf && pos + 1 < size) buf[pos] = '0'; pos++;
                if (buf && pos + 1 < size) buf[pos] = 'x'; pos++;
            } else if (is_unsigned) {
                val = va_arg(ap, unsigned int);
            } else {
                int64_t sval = va_arg(ap, int);
                if (sval < 0) {
                    if (buf && pos + 1 < size) buf[pos] = '-';
                    pos++;
                    val = (uint64_t)(-sval);
                } else {
                    val = (uint64_t)sval;
                }
            }
            char num_buf[32];
            int nidx = 0;
            uint32_t base = is_hex ? 16 : 10;
            const char* digits = is_upper ? "0123456789ABCDEF" : "0123456789abcdef";
            if (val == 0) {
                num_buf[nidx++] = '0';
            } else {
                while (val > 0) {
                    num_buf[nidx++] = digits[val % base];
                    val /= base;
                }
            }
            while (nidx > 0) {
                nidx--;
                if (buf && pos + 1 < size) buf[pos] = num_buf[nidx];
                pos++;
            }
            fmt++;
            continue;
        }
        // Unknown: print verbatim
        if (buf && pos + 1 < size) buf[pos] = '%'; pos++;
        if (buf && pos + 1 < size) buf[pos] = *fmt; pos++;
        fmt++;
    }
    if (buf && size > 0) {
        if (pos < size) buf[pos] = '\0';
        else buf[size - 1] = '\0';
    }
    return (int)pos;
}

int snprintf(char* buf, size_t size, const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int ret = vsnprintf(buf, size, fmt, ap);
    va_end(ap);
    return ret;
}

int vprintf(const char* fmt, va_list ap) {
    char buf[512];
    int len = vsnprintf(buf, sizeof(buf), fmt, ap);
    if (len > 0) {
        size_t to_write = (size_t)len < sizeof(buf) ? (size_t)len : sizeof(buf) - 1;
        trace_write(buf, to_write);
    }
    return len;
}

int printf(const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int ret = vprintf(fmt, ap);
    va_end(ap);
    return ret;
}

int vfprintf(void* stream, const char* fmt, va_list ap) {
    (void)stream;
    return vprintf(fmt, ap);
}

int fprintf(void* stream, const char* fmt, ...) {
    (void)stream;
    va_list ap;
    va_start(ap, fmt);
    int ret = vprintf(fmt, ap);
    va_end(ap);
    return ret;
}

int trace_vprintf(const char* fmt, va_list ap) {
    return vprintf(fmt, ap);
}

int trace_printf(const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int ret = vprintf(fmt, ap);
    va_end(ap);
    return ret;
}
