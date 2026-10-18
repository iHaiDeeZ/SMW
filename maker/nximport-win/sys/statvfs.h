// statvfs() for the importer's free-space check on Windows (SMW Maker): GetDiskFreeSpaceEx.
#pragma once
#include <windows.h>
#include <stdint.h>

struct statvfs {
    uint64_t f_bavail;
    uint64_t f_frsize;
};

static inline int statvfs(const char* path, struct statvfs* vs) {
    ULARGE_INTEGER avail;
    if (!GetDiskFreeSpaceExA(path, &avail, NULL, NULL)) return -1;
    vs->f_bavail = avail.QuadPart;
    vs->f_frsize = 1;
    return 0;
}
