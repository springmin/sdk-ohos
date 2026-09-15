/*
 * numa-shim.S — aarch64 libc syscall() interposer for .NET on OHOS.
 *
 * 1. SYS_get_mempolicy (236) is blocked by the sandbox seccomp (SIGSYS).
 *    Short-circuit with errno=ENOSYS — CoreCLR treats it as "no NUMA".
 * 2. /tmp is read-only erofs in the OHOS app sandbox; .NET hardcodes
 *    /tmp/.dotnet for shared memory. Redirect path-taking syscalls via
 *    the C helper numa_redirect_path().
 *
 * Syscall arg convention (arm64, via libc syscall()): x0=nr, x1..x6=args.
 * Path arg positions per syscall:
 *   x2-path family: 33 mknodat, 34 mkdirat, 35 unlinkat, 38 renameat(old),
 *                   48 faccessat, 53 fchmodat, 54 fchownat, 56 openat,
 *                   78 readlinkat, 79 fstatat, 88 utimensat, 291 statx
 *   x1-path:        45 truncate, 46 ftruncate(no), 
 *   x3-path:        36 symlinkat(linkpath)
 *   dual-path:      37 linkat(x2 old, x4 new), 38 renameat(x2 old, x4 new),
 *                   276 renameat2(x2 old, x4 new)
 */
    .text
    .globl syscall
    .type syscall, %function
syscall:
    cmp x0, #236
    b.eq .Lblocked
    /* x2-path family */
    cmp x0, #33
    b.eq .Lpath_x2
    cmp x0, #34
    b.eq .Lpath_x2
    cmp x0, #35
    b.eq .Lpath_x2
    cmp x0, #48
    b.eq .Lpath_x2
    cmp x0, #53
    b.eq .Lpath_x2
    cmp x0, #54
    b.eq .Lpath_x2
    cmp x0, #56
    b.eq .Lpath_x2
    cmp x0, #78
    b.eq .Lpath_x2
    cmp x0, #79
    b.eq .Lpath_x2
    cmp x0, #88
    b.eq .Lpath_x2
    cmp x0, #291
    b.eq .Lpath_x2
    /* x1-path: truncate */
    cmp x0, #45
    b.eq .Lpath_x1
    /* x3-path: symlinkat */
    cmp x0, #36
    b.eq .Lpath_x3
    /* dual-path: linkat, renameat, renameat2 */
    cmp x0, #37
    b.eq .Lpath_dual
    cmp x0, #38
    b.eq .Lpath_dual
    cmp x0, #276
    b.eq .Lpath_dual
.Ldispatch:
    mov x8, x0
    mov x0, x1
    mov x1, x2
    mov x2, x3
    mov x3, x4
    mov x4, x5
    mov x5, x6
    svc #0
    cmn x0, #4095
    b.hi .Lerror
    ret

/* --- common: save all args, call helper on specific positions, restore --- */
.Lpath_x1:
    stp x29, x30, [sp, #-96]!
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov x22, x3
    mov x23, x4
    mov x24, x5
    mov x0, x20
    bl numa_redirect_path
    mov x25, x0
    mov x0, x19
    mov x1, x25
    mov x2, x21
    mov x3, x22
    mov x4, x23
    mov x5, x24
    b .Lrestore_dispatch

.Lpath_x3:
    stp x29, x30, [sp, #-96]!
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov x22, x3
    mov x23, x4
    mov x24, x5
    mov x0, x22
    bl numa_redirect_path
    mov x25, x0
    mov x0, x19
    mov x1, x20
    mov x2, x21
    mov x3, x25
    mov x4, x23
    mov x5, x24
    b .Lrestore_dispatch

.Lpath_dual:
    stp x29, x30, [sp, #-96]!
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov x22, x3
    mov x23, x4
    mov x24, x5
    mov x0, x21
    bl numa_redirect_path
    mov x25, x0          /* redirected oldpath */
    mov x0, x23
    bl numa_redirect_path
    mov x26, x0          /* redirected newpath */
    mov x0, x19
    mov x1, x20
    mov x2, x25
    mov x3, x22
    mov x4, x26
    mov x5, x24
    b .Lrestore_dispatch

.Lpath_x2:
    stp x29, x30, [sp, #-96]!
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov x22, x3
    mov x23, x4
    mov x24, x5
    mov x0, x21
    bl numa_redirect_path
    mov x25, x0
    mov x0, x19
    mov x1, x20
    mov x2, x25
    mov x3, x22
    mov x4, x23
    mov x5, x24
    b .Lrestore_dispatch

.Lrestore_dispatch:
    ldp x25, x26, [sp, #64]
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #96
    b .Ldispatch

.Lerror:
    neg x1, x0
    stp x29, x30, [sp, #-32]!
    str x1, [sp, #16]
    bl __errno_location
    ldr x1, [sp, #16]
    str w1, [x0]
    ldp x29, x30, [sp], #32
    mov x0, #-1
    ret
.Lblocked:
    stp x29, x30, [sp, #-16]!
    bl __errno_location
    mov w1, #38             /* ENOSYS */
    str w1, [x0]
    ldp x29, x30, [sp], #16
    mov x0, #-1
    ret
    .size syscall, .-syscall
    .section .note.GNU-stack,"",%progbits
