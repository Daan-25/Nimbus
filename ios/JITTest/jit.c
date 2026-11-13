#include "jit.h"

#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

// From the kernel's code-signing interface; not in the public SDK headers.
int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
#define CS_OPS_STATUS 0
#define CS_DEBUGGED 0x10000000

// Requests to the debugger: a breakpoint with the request number in x16 and its arguments
// in x0 and x1. The debugger steps over the breakpoint and puts the answer in x0.
__attribute__((noinline, optnone, naked)) static void JIT26Detach(void) {
    __asm__("mov x16, #0\n"
            "brk #0xf00d\n"
            "ret\n");
}

__attribute__((noinline, optnone, naked)) static void *JIT26PrepareRegion(void *address, size_t length) {
    __asm__("mov x16, #1\n"
            "brk #0xf00d\n"
            "ret\n");
}

bool jit_debugger_attached(void) {
    uint32_t flags = 0;
    if (csops(getpid(), CS_OPS_STATUS, &flags, sizeof(flags)) != 0) {
        return false;
    }
    return (flags & CS_DEBUGGED) != 0;
}

int jit_run_self_test(char *error, size_t error_size) {
    const size_t length = 0x4000;

    // A null address asks the debugger to allocate the executable region.
    void *executable = JIT26PrepareRegion(NULL, length);
    if (executable == NULL) {
        JIT26Detach();
        snprintf(error, error_size, "The debugger didn't hand over an executable region.");
        return -1;
    }

    // The region can't be written through its executable address, so map the same memory
    // a second time, writable.
    vm_address_t writable = 0;
    vm_prot_t current = 0, maximum = 0;
    kern_return_t result = vm_remap(mach_task_self(), &writable, length, 0, VM_FLAGS_ANYWHERE,
                                    mach_task_self(), (vm_address_t)executable, false,
                                    &current, &maximum, VM_INHERIT_NONE);
    if (result == KERN_SUCCESS) {
        result = vm_protect(mach_task_self(), writable, length, false, VM_PROT_READ | VM_PROT_WRITE);
    }
    if (result != KERN_SUCCESS) {
        JIT26Detach();
        snprintf(error, error_size, "Couldn't map the region writable (%s).", mach_error_string(result));
        return -2;
    }

    // mov w0, #42 ; ret
    const uint32_t code[] = {0x52800540, 0xD65F03C0};
    memcpy((void *)writable, code, sizeof(code));
    sys_icache_invalidate(executable, sizeof(code));

    // Everything executable is in place, so the debugger can let go.
    JIT26Detach();

    int (*function)(void) = (int (*)(void))executable;
    return function();
}
