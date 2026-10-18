// Checks compat.h's mkdir on Windows: drives and folders that exist answer EEXIST, a new folder is made.
//   mkdir_test.exe <a folder to make inside, e.g. %TEMP%/x>
#include "compat.h"
#include <string>

static int check(const char* p, bool want_new) {
    int r = mkdir(p, 0775);
    bool ok = want_new ? r == 0 : (r != 0 && errno == EEXIST);
    printf("%-40s %s (r=%d errno=%d)\n", p, ok ? "ok" : "WRONG", r, r ? errno : 0);
    return ok ? 0 : 1;
}

int main(int argc, char** argv) {
    int bad = 0;
    char drive[3] = {argv[1][0], ':', 0};
    bad += check(drive, false);
    std::string root = std::string(drive) + "/";
    bad += check(root.c_str(), false);
    bad += check("Q:", false);                // a drive letter that may not exist: still not an error for the importer
    bad += check(argv[1], true);
    bad += check(argv[1], false);
    _rmdir(argv[1]);
    return bad;
}
