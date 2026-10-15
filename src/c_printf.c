/*
 * c_printf.c -- C implementation of printf/vsnprintf for freestanding AArch64
 *
 * Provides AAPCS64 variadic C runtime support for C code linked with µOS++ IIIe.
 * Supports flags (-, 0, +, space, #), field width, precision, length modifiers
 * (hh, h, l, ll, z, j, t) and specifiers (c, s, d, i, u, x, X, o, p, %).
 */

#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

extern long trace_write(const char* buf, size_t nbyte);

static inline void emit_char(char* buf, size_t size, size_t* pos, char c) {
    if (buf && *pos + 1 < size) {
        buf[*pos] = c;
    }
    (*pos)++;
}

int vsnprintf(char* buf, size_t size, const char* fmt, va_list ap) {
    size_t pos = 0;

    while (*fmt) {
        if (*fmt != '%') {
            emit_char(buf, size, &pos, *fmt++);
            continue;
        }

        fmt++; // Skip '%'

        if (*fmt == '%') {
            emit_char(buf, size, &pos, '%');
            fmt++;
            continue;
        }

        // 1. Flags: '-', '0', '+', ' ', '#'
        bool left_align = false;
        bool zero_pad = false;
        bool plus_sign = false;
        bool space_sign = false;
        bool alt_form = false;

        bool parsing_flags = true;
        while (parsing_flags) {
            switch (*fmt) {
                case '-': left_align = true; fmt++; break;
                case '0': zero_pad = true; fmt++; break;
                case '+': plus_sign = true; fmt++; break;
                case ' ': space_sign = true; fmt++; break;
                case '#': alt_form = true; fmt++; break;
                default: parsing_flags = false; break;
            }
        }
        if (left_align) zero_pad = false;

        // 2. Field Width
        int width = 0;
        if (*fmt == '*') {
            width = va_arg(ap, int);
            if (width < 0) {
                left_align = true;
                zero_pad = false;
                width = -width;
            }
            fmt++;
        } else {
            while (*fmt >= '0' && *fmt <= '9') {
                width = width * 10 + (*fmt - '0');
                fmt++;
            }
        }

        // 3. Precision
        int precision = -1;
        if (*fmt == '.') {
            fmt++;
            precision = 0;
            if (*fmt == '*') {
                precision = va_arg(ap, int);
                if (precision < 0) precision = -1;
                fmt++;
            } else {
                while (*fmt >= '0' && *fmt <= '9') {
                    precision = precision * 10 + (*fmt - '0');
                    fmt++;
                }
            }
        }

        // 4. Length Modifiers: hh, h, l, ll, z, j, t
        enum { LEN_NONE, LEN_HH, LEN_H, LEN_L, LEN_LL, LEN_Z, LEN_J, LEN_T } len_mod = LEN_NONE;
        if (*fmt == 'h') {
            fmt++;
            if (*fmt == 'h') {
                len_mod = LEN_HH;
                fmt++;
            } else {
                len_mod = LEN_H;
            }
        } else if (*fmt == 'l') {
            fmt++;
            if (*fmt == 'l') {
                len_mod = LEN_LL;
                fmt++;
            } else {
                len_mod = LEN_L;
            }
        } else if (*fmt == 'z') {
            len_mod = LEN_Z;
            fmt++;
        } else if (*fmt == 'j') {
            len_mod = LEN_J;
            fmt++;
        } else if (*fmt == 't') {
            len_mod = LEN_T;
            fmt++;
        }

        // 5. Conversion Specifiers
        char spec = *fmt++;
        if (!spec) break;

        if (spec == 'c') {
            char ch = (char)va_arg(ap, int);
            if (!left_align) {
                for (int w = 1; w < width; w++) emit_char(buf, size, &pos, ' ');
            }
            emit_char(buf, size, &pos, ch);
            if (left_align) {
                for (int w = 1; w < width; w++) emit_char(buf, size, &pos, ' ');
            }
            continue;
        }

        if (spec == 's') {
            const char* s = va_arg(ap, const char*);
            if (!s) s = "(null)";
            size_t slen = 0;
            while (s[slen] != '\0' && (precision < 0 || (int)slen < precision)) {
                slen++;
            }
            if (!left_align) {
                for (int w = (int)slen; w < width; w++) emit_char(buf, size, &pos, ' ');
            }
            for (size_t i = 0; i < slen; i++) {
                emit_char(buf, size, &pos, s[i]);
            }
            if (left_align) {
                for (int w = (int)slen; w < width; w++) emit_char(buf, size, &pos, ' ');
            }
            continue;
        }

        if (spec == 'd' || spec == 'i' || spec == 'u' || spec == 'x' || spec == 'X' || spec == 'o' || spec == 'p') {
            bool is_signed = (spec == 'd' || spec == 'i');
            bool is_hex = (spec == 'x' || spec == 'X' || spec == 'p');
            bool is_upper = (spec == 'X');
            uint32_t base = is_hex ? 16 : (spec == 'o' ? 8 : 10);

            uint64_t uval = 0;
            bool negative = false;

            if (spec == 'p') {
                void* ptr = va_arg(ap, void*);
                uval = (uintptr_t)ptr;
                alt_form = true;
            } else if (is_signed) {
                int64_t sval = 0;
                switch (len_mod) {
                    case LEN_HH: sval = (signed char)va_arg(ap, int); break;
                    case LEN_H:  sval = (short)va_arg(ap, int); break;
                    case LEN_L:  sval = va_arg(ap, long); break;
                    case LEN_LL: sval = va_arg(ap, long long); break;
                    case LEN_Z:  sval = va_arg(ap, ptrdiff_t); break;
                    case LEN_T:  sval = va_arg(ap, ptrdiff_t); break;
                    default:     sval = va_arg(ap, int); break;
                }
                if (sval < 0) {
                    negative = true;
                    uval = (uint64_t)(-sval);
                } else {
                    uval = (uint64_t)sval;
                }
            } else {
                switch (len_mod) {
                    case LEN_HH: uval = (unsigned char)va_arg(ap, unsigned int); break;
                    case LEN_H:  uval = (unsigned short)va_arg(ap, unsigned int); break;
                    case LEN_L:  uval = va_arg(ap, unsigned long); break;
                    case LEN_LL: uval = va_arg(ap, unsigned long long); break;
                    case LEN_Z:  uval = va_arg(ap, size_t); break;
                    default:     uval = va_arg(ap, unsigned int); break;
                }
            }

            char num_buf[32];
            int nidx = 0;
            const char* digits = is_upper ? "0123456789ABCDEF" : "0123456789abcdef";

            if (uval == 0) {
                if (precision != 0) num_buf[nidx++] = '0';
            } else {
                while (uval > 0) {
                    num_buf[nidx++] = digits[uval % base];
                    uval /= base;
                }
            }

            // Prefix (+, -, space, 0x, 0X)
            char prefix[3];
            int plen = 0;
            if (negative) {
                prefix[plen++] = '-';
            } else if (plus_sign && is_signed) {
                prefix[plen++] = '+';
            } else if (space_sign && is_signed) {
                prefix[plen++] = ' ';
            }
            if (alt_form && is_hex && (spec == 'p' || nidx > 0)) {
                prefix[plen++] = '0';
                prefix[plen++] = is_upper ? 'X' : 'x';
            }

            int num_digits = nidx;
            int num_zeros = 0;
            if (precision >= 0) {
                zero_pad = false;
                if (precision > num_digits) num_zeros = precision - num_digits;
            } else if (zero_pad && width > num_digits + plen) {
                num_zeros = width - num_digits - plen;
            }

            int total_len = plen + num_zeros + num_digits;

            // Left padding (spaces) if right-aligned
            if (!left_align && !zero_pad) {
                for (int w = total_len; w < width; w++) emit_char(buf, size, &pos, ' ');
            }

            // Emit prefix
            for (int i = 0; i < plen; i++) emit_char(buf, size, &pos, prefix[i]);

            // Emit leading zeros
            for (int i = 0; i < num_zeros; i++) emit_char(buf, size, &pos, '0');

            // Emit digits
            while (nidx > 0) {
                emit_char(buf, size, &pos, num_buf[--nidx]);
            }

            // Right padding (spaces) if left-aligned
            if (left_align) {
                for (int w = total_len; w < width; w++) emit_char(buf, size, &pos, ' ');
            }
            continue;
        }

        // Unknown specifier: emit verbatim
        emit_char(buf, size, &pos, '%');
        emit_char(buf, size, &pos, spec);
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
    va_list ap_copy;
    va_copy(ap_copy, ap);
    int len = vsnprintf(buf, sizeof(buf), fmt, ap_copy);
    va_end(ap_copy);
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
