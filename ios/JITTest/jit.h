// The app's half of the iOS 26 JIT protocol, plus a self-test. See core/src/jit.rs for the
// debugger's half.

#ifndef NIMBUS_JIT_TEST_H
#define NIMBUS_JIT_TEST_H

#include <stdbool.h>
#include <stddef.h>

// Whether a debugger has attached to this process, which is what allows JIT.
bool jit_debugger_attached(void);

// Asks the debugger for an executable region, writes a small function into it and runs it.
// Only call this once a debugger is attached: without one, the breakpoints crash the app.
// Returns what the function returned (42 when everything works), or a negative number with
// the reason in `error`.
int jit_run_self_test(char *error, size_t error_size);

#endif
