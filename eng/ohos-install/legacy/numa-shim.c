/*
 * numa-shim.c — path redirection helper for numa-shim.S
 * Redirects "/tmp/..." paths to $TMPDIR so .NET's shared-memory dir
 * (/tmp/.dotnet) and NuGet temp files work on read-only /tmp (OHOS sandbox).
 */
#include <stdlib.h>
#include <string.h>
#include <limits.h>

/* TLS buffer so nested/concurrent calls don't clobber each other */
static __thread char g_redirect_buf[PATH_MAX];

/* Returns a writable equivalent of path if it lives under /tmp, else path. */
const char *numa_redirect_path(const char *path)
{
    const char *tmpdir;
    size_t plen, tlen;

    if (path == NULL)
        return path;

    /* only redirect paths under /tmp (or exactly /tmp) */
    if (strncmp(path, "/tmp", 4) != 0)
        return path;
    if (path[4] != '/' && path[4] != '\0')
        return path;

    tmpdir = getenv("TMPDIR");
    if (tmpdir == NULL || tmpdir[0] == '\0')
        tmpdir = "/data/storage/el2/base/tmp";

    plen = strlen(path);
    tlen = strlen(tmpdir);

    /* /tmp -> $TMPDIR, /tmp/xxx -> $TMPDIR/xxx */
    if (plen == 4) {
        if (tlen >= PATH_MAX)
            return path;
        memcpy(g_redirect_buf, tmpdir, tlen + 1);
        return g_redirect_buf;
    }
    if (tlen + plen - 4 >= PATH_MAX)
        return path;
    memcpy(g_redirect_buf, tmpdir, tlen);
    memcpy(g_redirect_buf + tlen, path + 4, plen - 4 + 1);
    return g_redirect_buf;
}

/* ------------------------------------------------------------------ */
/* libc file-function wrappers: /tmp -> $TMPDIR redirection            */
/* Implemented on top of our own syscall() so redirection + errno      */
/* handling is shared. No recursion: we call the asm symbol directly.  */
/* ------------------------------------------------------------------ */
#include <stdarg.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

extern long syscall(long, ...);   /* our asm interposer */

int open(const char *path, int flags, ...)
{
    va_list ap;
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_start(ap, flags);
        mode = va_arg(ap, mode_t);
        va_end(ap);
    }
    return (int)syscall(56, -100, path, flags, mode); /* openat(AT_FDCWD) */
}

int openat(int dirfd, const char *path, int flags, ...)
{
    va_list ap;
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_start(ap, flags);
        mode = va_arg(ap, mode_t);
        va_end(ap);
    }
    return (int)syscall(56, dirfd, path, flags, mode);
}

int mkdir(const char *path, mode_t mode)
{
    return (int)syscall(34, -100, path, mode); /* mkdirat(AT_FDCWD) */
}

int mkdirat(int dirfd, const char *path, mode_t mode)
{
    return (int)syscall(34, dirfd, path, mode);
}

int stat(const char *path, struct stat *buf)
{
    return (int)syscall(79, -100, path, buf, 0); /* fstatat(AT_FDCWD) */
}

int lstat(const char *path, struct stat *buf)
{
    return (int)syscall(79, -100, path, buf, 0x100); /* AT_SYMLINK_NOFOLLOW */
}

int fstatat(int dirfd, const char *path, struct stat *buf, int flags)
{
    return (int)syscall(79, dirfd, path, buf, flags);
}

int unlink(const char *path)
{
    return (int)syscall(35, -100, path, 0); /* unlinkat(AT_FDCWD) */
}

int unlinkat(int dirfd, const char *path, int flags)
{
    return (int)syscall(35, dirfd, path, flags);
}

int rename(const char *oldpath, const char *newpath)
{
    return (int)syscall(38, -100, oldpath, -100, newpath);
}

int renameat(int olddirfd, const char *oldpath, int newdirfd, const char *newpath)
{
    return (int)syscall(38, olddirfd, oldpath, newdirfd, newpath);
}

int access(const char *path, int amode)
{
    return (int)syscall(48, -100, path, amode, 0); /* faccessat(AT_FDCWD) */
}

int faccessat(int dirfd, const char *path, int amode, int flags)
{
    return (int)syscall(48, dirfd, path, amode, flags);
}

/* more libc wrappers: chmod/chown/utimens/readlink families */
#include <sys/time.h>

int chmod(const char *path, mode_t mode)
{
    return (int)syscall(53, -100, path, mode, 0); /* fchmodat(AT_FDCWD) */
}

int fchmodat(int dirfd, const char *path, mode_t mode, int flags)
{
    return (int)syscall(53, dirfd, path, mode, flags);
}

int chown(const char *path, uid_t owner, gid_t group)
{
    return (int)syscall(54, -100, path, owner, group, 0); /* fchownat */
}

int lchown(const char *path, uid_t owner, gid_t group)
{
    return (int)syscall(54, -100, path, owner, group, 0x100); /* AT_SYMLINK_NOFOLLOW */
}

int fchownat(int dirfd, const char *path, uid_t owner, gid_t group, int flags)
{
    return (int)syscall(54, dirfd, path, owner, group, flags);
}

int utimensat(int dirfd, const char *path, const struct timespec times[2], int flags)
{
    return (int)syscall(88, dirfd, path, times, flags);
}

ssize_t readlink(const char *path, char *buf, size_t bufsiz)
{
    return (ssize_t)syscall(78, -100, path, buf, bufsiz);
}

ssize_t readlinkat(int dirfd, const char *path, char *buf, size_t bufsiz)
{
    return (ssize_t)syscall(78, dirfd, path, buf, bufsiz);
}

int link(const char *oldpath, const char *newpath)
{
    return (int)syscall(37, -100, oldpath, -100, newpath, 0);
}

int linkat(int olddirfd, const char *oldpath, int newdirfd, const char *newpath, int flags)
{
    return (int)syscall(37, olddirfd, oldpath, newdirfd, newpath, flags);
}

int symlink(const char *target, const char *linkpath)
{
    return (int)syscall(36, target, -100, linkpath);
}

int symlinkat(const char *target, int newdirfd, const char *linkpath)
{
    return (int)syscall(36, target, newdirfd, linkpath);
}

int mknod(const char *path, mode_t mode, dev_t dev)
{
    return (int)syscall(33, -100, path, mode, dev);
}

int mknodat(int dirfd, const char *path, mode_t mode, dev_t dev)
{
    return (int)syscall(33, dirfd, path, mode, dev);
}

int truncate(const char *path, off_t length)
{
    return (int)syscall(45, path, length);
}

int statx(int dirfd, const char *path, int flags, unsigned int mask, void *buf)
{
    return (int)syscall(291, dirfd, path, flags, mask, buf);
}
