/*
 FBD — runtime shims for SkyLight's system appearance (Dark Mode) functions.

 SkyLight is NOT linked by the package, so every symbol is resolved at runtime
 and a missing one reports false rather than failing to launch. This is the same
 discipline as the other private surfaces: never crash, always degrade.

 Selector ground truth: Crisp resolves the same three functions
 (Crisp/Services/CoreBrightnessService.swift) with these names and signatures:

   SLSGetAppearanceThemeLegacy(void) -> bool            (true = Dark Mode)
   SLSSetAppearanceThemeLegacy(bool) -> void
   SLSSetAppearanceThemeNotifying(bool on, bool notify) -> void

 Crisp prefers the notifying variant so the switch goes through the same
 crossfade Control Center uses; `animated` selects it here, falling back to the
 instant flip when it is absent.
 */

#include <dlfcn.h>
#include <stdbool.h>

#include "fbd_private_api.h"

typedef bool (*fbd_appearance_get_fn)(void);
typedef void (*fbd_appearance_set_fn)(bool);
typedef void (*fbd_appearance_set_notifying_fn)(bool, bool);

/* dlopen once; the handle is deliberately never closed. */
static void *fbd_appearance_handle(void) {
    static void *handle = NULL;
    static bool tried = false;
    if (!tried) {
        tried = true;
        handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
    }
    return handle;
}

bool FBDAppearanceAvailable(void) {
    void *handle = fbd_appearance_handle();
    if (handle == NULL) {
        return false;
    }
    return dlsym(handle, "SLSGetAppearanceThemeLegacy") != NULL
        && dlsym(handle, "SLSSetAppearanceThemeLegacy") != NULL;
}

bool FBDAppearanceIsDark(bool *out) {
    void *handle = fbd_appearance_handle();
    if (handle == NULL || out == NULL) {
        return false;
    }
    fbd_appearance_get_fn get = (fbd_appearance_get_fn)dlsym(handle, "SLSGetAppearanceThemeLegacy");
    if (get == NULL) {
        return false;
    }
    *out = get();
    return true;
}

bool FBDAppearanceSetDark(bool on, bool animated) {
    void *handle = fbd_appearance_handle();
    if (handle == NULL) {
        return false;
    }
    if (animated) {
        fbd_appearance_set_notifying_fn setNotifying =
            (fbd_appearance_set_notifying_fn)dlsym(handle, "SLSSetAppearanceThemeNotifying");
        if (setNotifying != NULL) {
            setNotifying(on, true);
            return true;
        }
    }
    fbd_appearance_set_fn set = (fbd_appearance_set_fn)dlsym(handle, "SLSSetAppearanceThemeLegacy");
    if (set == NULL) {
        return false;
    }
    set(on);
    return true;
}
