// A disk that stops answering, for tests: loaded into the silent snapshot copy with DYLD_INSERT_LIBRARIES, it makes
// every file call under CDGLASS_HANG_PREFIX block for good once the file CDGLASS_HANG_FLAG exists, the way calls on
// a USB disk that dropped out or an sshfs / SMB link that went down do. Descriptors opened there before the flag
// appeared block too on read, so a track already playing stalls in VLC exactly as on a real disk.
// Build: clang -dynamiclib tests/hang_interpose.c -o hang_interpose.dylib
#include <dirent.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/uio.h>
#include <time.h>
#include <unistd.h>

#define INTERPOSE(replacement, original) \
    __attribute__((used)) static struct { const void *r; const void *o; } _interpose_##original \
    __attribute__((section("__DATA,__interpose"))) = { (const void *)(replacement), (const void *)(original) };

static char tracked[65536];

static int under(const char *path) {
    const char *prefix = getenv("CDGLASS_HANG_PREFIX");
    return path && prefix && *prefix && strncmp(path, prefix, strlen(prefix)) == 0;
}
static time_t loaded;
__attribute__((constructor)) static void start(void) { loaded = time(NULL); }
static int on(void) {
    // CDGLASS_HANG_AFTER=<seconds> makes the disk drop out that long after launch, for builds without the hang verb.
    const char *after = getenv("CDGLASS_HANG_AFTER");
    if (after && *after && time(NULL) - loaded >= atoi(after)) return 1;
    const char *flag = getenv("CDGLASS_HANG_FLAG");
    struct stat info;
    return flag && stat(flag, &info) == 0;       // our own calls are not interposed
}
static void wait_forever(void) { for (;;) pause(); }
static void gate_path(const char *path) { if (under(path) && on()) wait_forever(); }
static void gate_fd(int fd) { if (fd >= 0 && fd < (int)sizeof tracked && tracked[fd] && on()) wait_forever(); }
static int note(int fd, int yes) { if (fd >= 0 && fd < (int)sizeof tracked) tracked[fd] = (char)yes; return fd; }
static int relative_under(int dirfd, const char *path) {
    return under(path) || (path && path[0] != '/' && dirfd >= 0 && dirfd < (int)sizeof tracked && tracked[dirfd]);
}

extern int open_nocancel(const char *, int, ...) __asm("_open$NOCANCEL");
extern int openat_nocancel(int, const char *, int, ...) __asm("_openat$NOCANCEL");
extern ssize_t read_nocancel(int, void *, size_t) __asm("_read$NOCANCEL");
extern ssize_t pread_nocancel(int, void *, size_t, off_t) __asm("_pread$NOCANCEL");
extern ssize_t readv_nocancel(int, const struct iovec *, int) __asm("_readv$NOCANCEL");
extern ssize_t preadv_nocancel(int, const struct iovec *, int, off_t) __asm("_preadv$NOCANCEL");

static int my_open(const char *path, int flags, ...) {
    mode_t mode = 0; if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = (mode_t)va_arg(ap, int); va_end(ap); }
    gate_path(path); return note(open(path, flags, mode), under(path));
}
static int my_open_nocancel(const char *path, int flags, ...) {
    mode_t mode = 0; if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = (mode_t)va_arg(ap, int); va_end(ap); }
    gate_path(path); return note(open_nocancel(path, flags, mode), under(path));
}
static int my_openat(int dirfd, const char *path, int flags, ...) {
    mode_t mode = 0; if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = (mode_t)va_arg(ap, int); va_end(ap); }
    int inside = relative_under(dirfd, path);
    if (inside && on()) wait_forever();
    return note(openat(dirfd, path, flags, mode), inside);
}
static int my_openat_nocancel(int dirfd, const char *path, int flags, ...) {
    mode_t mode = 0; if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = (mode_t)va_arg(ap, int); va_end(ap); }
    int inside = relative_under(dirfd, path);
    if (inside && on()) wait_forever();
    return note(openat_nocancel(dirfd, path, flags, mode), inside);
}
static int my_close(int fd) { note(fd, 0); return close(fd); }
static ssize_t my_read(int fd, void *buf, size_t n) { gate_fd(fd); return read(fd, buf, n); }
static ssize_t my_read_nocancel(int fd, void *buf, size_t n) { gate_fd(fd); return read_nocancel(fd, buf, n); }
static ssize_t my_pread(int fd, void *buf, size_t n, off_t at) { gate_fd(fd); return pread(fd, buf, n, at); }
static ssize_t my_pread_nocancel(int fd, void *buf, size_t n, off_t at) { gate_fd(fd); return pread_nocancel(fd, buf, n, at); }
static ssize_t my_readv(int fd, const struct iovec *v, int n) { gate_fd(fd); return readv(fd, v, n); }
static ssize_t my_readv_nocancel(int fd, const struct iovec *v, int n) { gate_fd(fd); return readv_nocancel(fd, v, n); }
static ssize_t my_preadv(int fd, const struct iovec *v, int n, off_t at) { gate_fd(fd); return preadv(fd, v, n, at); }
static ssize_t my_preadv_nocancel(int fd, const struct iovec *v, int n, off_t at) { gate_fd(fd); return preadv_nocancel(fd, v, n, at); }
static void *my_mmap(void *addr, size_t n, int prot, int flags, int fd, off_t at) { gate_fd(fd); return mmap(addr, n, prot, flags, fd, at); }
static int my_fstat(int fd, struct stat *info) { gate_fd(fd); return fstat(fd, info); }
static int my_stat(const char *path, struct stat *info) { gate_path(path); return stat(path, info); }
static int my_lstat(const char *path, struct stat *info) { gate_path(path); return lstat(path, info); }
static int my_fstatat(int dirfd, const char *path, struct stat *info, int flags) { if (relative_under(dirfd, path) && on()) wait_forever(); return fstatat(dirfd, path, info, flags); }
static int my_access(const char *path, int mode) { gate_path(path); return access(path, mode); }
static int my_faccessat(int dirfd, const char *path, int mode, int flags) { if (relative_under(dirfd, path) && on()) wait_forever(); return faccessat(dirfd, path, mode, flags); }
static int my_getattrlist(const char *path, void *list, void *buf, size_t n, unsigned int options) { gate_path(path); return getattrlist(path, list, buf, n, options); }
static int my_getattrlistat(int dirfd, const char *path, void *list, void *buf, size_t n, unsigned long options) { if (relative_under(dirfd, path) && on()) wait_forever(); return getattrlistat(dirfd, path, list, buf, n, options); }
static int my_fgetattrlist(int fd, void *list, void *buf, size_t n, unsigned int options) { gate_fd(fd); return fgetattrlist(fd, list, buf, n, options); }
static int my_getattrlistbulk(int fd, void *list, void *buf, size_t n, uint64_t options) { gate_fd(fd); return getattrlistbulk(fd, list, buf, n, options); }
static int my_statfs(const char *path, struct statfs *info) { gate_path(path); return statfs(path, info); }
static ssize_t my_readlink(const char *path, char *buf, size_t n) { gate_path(path); return readlink(path, buf, n); }
static char *my_realpath(const char *path, char *resolved) { gate_path(path); return realpath(path, resolved); }

INTERPOSE(my_open, open)
INTERPOSE(my_open_nocancel, open_nocancel)
INTERPOSE(my_openat, openat)
INTERPOSE(my_openat_nocancel, openat_nocancel)
INTERPOSE(my_close, close)
INTERPOSE(my_read, read)
INTERPOSE(my_read_nocancel, read_nocancel)
INTERPOSE(my_pread, pread)
INTERPOSE(my_pread_nocancel, pread_nocancel)
INTERPOSE(my_readv, readv)
INTERPOSE(my_readv_nocancel, readv_nocancel)
INTERPOSE(my_preadv, preadv)
INTERPOSE(my_preadv_nocancel, preadv_nocancel)
INTERPOSE(my_mmap, mmap)
INTERPOSE(my_fstat, fstat)
INTERPOSE(my_stat, stat)
INTERPOSE(my_lstat, lstat)
INTERPOSE(my_fstatat, fstatat)
INTERPOSE(my_access, access)
INTERPOSE(my_faccessat, faccessat)
INTERPOSE(my_getattrlist, getattrlist)
INTERPOSE(my_getattrlistat, getattrlistat)
INTERPOSE(my_fgetattrlist, fgetattrlist)
INTERPOSE(my_getattrlistbulk, getattrlistbulk)
INTERPOSE(my_statfs, statfs)
INTERPOSE(my_readlink, readlink)
INTERPOSE(my_realpath, realpath)
