/*
 FBD — runtime shims for IOKit's IODP DPCD read path.

 The IODP family is exported by the *public* IOKit framework — the names are in its .tbd, which is
 why they were findable at all — but linking it would hard-link them, and a macOS that drops one
 would fail to launch rather than degrade. Every other private surface here resolves at runtime, so
 this does too.

 Shapes, from docs/PRIVATE_APIS.md: `IODPDeviceCreateWithService` takes the same IOService the DDC
 path already finds (the `DCPAVServiceProxy` / `IOAVService` node), and `IODPDeviceReadDPCD` is the
 AUX read — a 32-bit address, and a length the implementation itself clamps to 0x1000.

 **Read-only by construction.** Only the read is declared. `IODPDeviceWriteDPCD` and the
 retrain/set calls resolve on this macOS and are deliberately absent here: a wrong write can wedge
 the only attached display, and nothing FBD does needs one.

 No IOKit headers, deliberately: the only types crossing this boundary are plain integers, and the
 functions are reached through dlopen/dlsym rather than linked.
 */

#include <dlfcn.h>
#include <stdbool.h>
#include <stdint.h>

#include "fbd_private_api.h"

typedef void *(*fbd_iodp_create_fn)(uint32_t service);
typedef int (*fbd_iodp_read_fn)(void *device, uint32_t address, uint8_t *buffer, uint32_t length);

static void *fbd_iodp_handle(void) {
    static void *handle = NULL;
    static bool tried = false;
    if (!tried) {
        tried = true;
        handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    }
    return handle;
}

bool FBDIodpAvailable(void) {
    void *handle = fbd_iodp_handle();
    if (handle == NULL) {
        return false;
    }
    return dlsym(handle, "IODPDeviceCreateWithService") != NULL
        && dlsym(handle, "IODPDeviceReadDPCD") != NULL;
}

void *FBDIodpDeviceWithService(uint32_t service) {
    void *handle = fbd_iodp_handle();
    if (handle == NULL || service == 0) {
        return NULL;
    }
    fbd_iodp_create_fn create = (fbd_iodp_create_fn)dlsym(handle, "IODPDeviceCreateWithService");
    if (create == NULL) {
        return NULL;
    }
    return create(service);
}

int FBDIodpReadDPCD(void *device, uint32_t address, uint8_t *buffer, uint32_t length) {
    void *handle = fbd_iodp_handle();
    if (handle == NULL || device == NULL || buffer == NULL || length == 0) {
        return -1;
    }
    fbd_iodp_read_fn read = (fbd_iodp_read_fn)dlsym(handle, "IODPDeviceReadDPCD");
    if (read == NULL) {
        return -1;
    }
    /* The status is the implementation's own and is passed through uninterpreted: -1 means "could
       not call it", 0 means success by the family's convention, anything else is the call's own
       refusal. Guessing a convention here would turn a refusal into a silent empty read. */
    return read(device, address, buffer, length);
}
