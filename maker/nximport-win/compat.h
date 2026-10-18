// Windows (mingw-w64) build of upstream's importer (android/wonder/importer) for SMW Maker: the few POSIX calls it
// uses, force-included (-include compat.h) so upstream's files stay as they are.
#pragma once
#include <windows.h>
#include <io.h>
#include <direct.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/types.h>

// Every open() of the importer passes O_CLOEXEC: on Windows the bit that matters there is binary mode (no CR/LF
// translation of the dump or of the files it writes).
#ifndef O_CLOEXEC
#define O_CLOEXEC _O_BINARY
#endif

// Positional read: ReadFile at an offset (the importer reads from several threads).
static inline ssize_t pread(int fd, void* buf, size_t n, int64_t off) {
    HANDLE h = (HANDLE)_get_osfhandle(fd);
    if (h == INVALID_HANDLE_VALUE) { errno = EBADF; return -1; }
    OVERLAPPED ov = {};
    ov.Offset = (DWORD)(uint64_t(off) & 0xffffffffu);
    ov.OffsetHigh = (DWORD)(uint64_t(off) >> 32);
    DWORD want = n > 0x40000000 ? 0x40000000 : (DWORD)n, got = 0;
    if (!ReadFile(h, buf, want, &got, &ov)) {
        if (GetLastError() == ERROR_HANDLE_EOF) return 0;
        errno = EIO;
        return -1;
    }
    return (ssize_t)got;
}

// fdatasync: flush the written file to disk.
static inline int fdatasync(int fd) { return _commit(fd); }

// mkdir(path, mode) and a rename() that replaces the target, as on POSIX.
#define mkdir(path, mode) _mkdir(path)
static inline int smw_rename(const char* from, const char* to) {
    if (MoveFileExA(from, to, MOVEFILE_REPLACE_EXISTING)) return 0;
    errno = EACCES;
    return -1;
}
#define rename(from, to) smw_rename(from, to)
