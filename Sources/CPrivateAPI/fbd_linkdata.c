/*
 FBD — runtime probe for the DisplayPort link-data entry points.

 BetterDisplay 5 reads the DisplayPort link data (DPCD / DSC / link bandwidth / tiling) through
 a pair of IOKit entry points that 4.3.5 did not use:

     IOAVVideoInterfaceCreateWithService
     IOAVVideoInterfaceGetLinkData

 Both resolve in IOKit on macOS 27.0.1 (measured with dlsym; see docs/PRIVATE_APIS.md).

 **Neither is called here, and this file exists so that neither is called by accident.**
 `IOAVVideoInterfaceGetLinkData` returns a structure that no public header describes, so its
 fields cannot be decoded safely: a wrong guess would put invented numbers into a bug report.
 `IOAVVideoInterfaceCreateWithService` was measured raising a kernel trap (SIGTRAP) when handed
 the only display this repository's machine has, so calling it is not free either.

 What this file does is answer one question honestly: *is the entry point present on this
 macOS?* A report can then say "present here, but its result cannot be read", which is a very
 different statement from "this feature does not exist".
 */

#include <dlfcn.h>
#include <stdbool.h>

#include "fbd_private_api.h"

static void *fbd_linkdata_handle(void) {
    static void *handle = NULL;
    static bool tried = false;
    if (!tried) {
        tried = true;
        handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    }
    return handle;
}

bool FBDVideoLinkDataAvailable(void) {
    void *handle = fbd_linkdata_handle();
    if (handle == NULL) {
        return false;
    }
    return dlsym(handle, "IOAVVideoInterfaceCreateWithService") != NULL
        && dlsym(handle, "IOAVVideoInterfaceGetLinkData") != NULL;
}
