/*
 * The C half of the trace tests: the C trace API (cmsis-plus/diag/trace.h).
 */

#include <cmsis-plus/diag/trace.h>

void
trace_c_message (void);

void
trace_c_message (void)
{
  trace_puts ("C Message");
}
