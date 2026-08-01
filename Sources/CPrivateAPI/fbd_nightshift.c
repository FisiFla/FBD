/*
 FBD — runtime shims for the CoreBrightness private ObjC classes
 CBBlueLightClient (Night Shift) and CBTrueToneClient (True Tone),
 plus a dlopen helper that makes the private framework resolvable by
 NSClassFromString (CoreBrightness is NOT linked by the package).

 Selector ground truth: Lunar's CoreBrightness headers (Shifty-derived),
 mirrored in /tmp/lunar/Lunar/Headers:

   -[CBBlueLightClient init]
   -[CBBlueLightClient setStrength:commit:]   (float, BOOL)
   -[CBBlueLightClient getStrength:]          (float *)
   +[CBBlueLightClient supportsBlueLightReduction]   (BOOL)
   -[CBTrueToneClient init]
   -[CBTrueToneClient available]              (BOOL)
   -[CBTrueToneClient enabled]                (BOOL)
   -[CBTrueToneClient setEnabled:]            (BOOL)

 Lunar usage (GammaControl.swift) confirms getStrength: is single-argument
 and strength is a 0…1 float.

 Every call uses an exact non-variadic objc_msgSend cast: variadic calls
 pass floats/structs on the stack while the ObjC ABI expects registers.
 */

#include <dlfcn.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <stdbool.h>

typedef void *fbd_id;

static SEL fbd_sel(const char *s) { return sel_registerName(s); }

/* Load CoreBrightness so NSClassFromString can resolve its classes.
   Idempotent; returns true when the framework is (now) loaded. */
bool FBDLoadCoreBrightness(void) {
    void *handle = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness",
                          RTLD_NOW | RTLD_GLOBAL);
    return handle != NULL;
}

#pragma mark - CBBlueLightClient (Night Shift)

/* alloc/init. Returns a +1 object (Swift takes ownership via takeRetainedValue). */
fbd_id FBDNightShiftCreate(fbd_id cls) {
    fbd_id inst = ((fbd_id (*)(fbd_id, SEL))objc_msgSend)(cls, fbd_sel("alloc"));
    if (!inst) {
        return NULL;
    }
    return ((fbd_id (*)(fbd_id, SEL))objc_msgSend)(inst, fbd_sel("init"));
}

bool FBDNightShiftSupportsBlueLightReduction(fbd_id cls) {
    typedef bool (*Fn)(fbd_id, SEL);
    return ((Fn)objc_msgSend)(cls, fbd_sel("supportsBlueLightReduction"));
}

bool FBDNightShiftGetStrength(fbd_id client, float *strength) {
    typedef bool (*Fn)(fbd_id, SEL, float *);
    return ((Fn)objc_msgSend)(client, fbd_sel("getStrength:"), strength);
}

bool FBDNightShiftSetStrength(fbd_id client, float strength, bool commit) {
    typedef bool (*Fn)(fbd_id, SEL, float, bool);
    return ((Fn)objc_msgSend)(client, fbd_sel("setStrength:commit:"), strength, commit);
}

#pragma mark - CBTrueToneClient (True Tone)

fbd_id FBDTrueToneCreate(fbd_id cls) {
    fbd_id inst = ((fbd_id (*)(fbd_id, SEL))objc_msgSend)(cls, fbd_sel("alloc"));
    if (!inst) {
        return NULL;
    }
    return ((fbd_id (*)(fbd_id, SEL))objc_msgSend)(inst, fbd_sel("init"));
}

bool FBDTrueToneIsAvailable(fbd_id client) {
    typedef bool (*Fn)(fbd_id, SEL);
    return ((Fn)objc_msgSend)(client, fbd_sel("available"));
}

bool FBDTrueToneIsEnabled(fbd_id client) {
    typedef bool (*Fn)(fbd_id, SEL);
    return ((Fn)objc_msgSend)(client, fbd_sel("enabled"));
}

bool FBDTrueToneSetEnabled(fbd_id client, bool enabled) {
    typedef bool (*Fn)(fbd_id, SEL, bool);
    return ((Fn)objc_msgSend)(client, fbd_sel("setEnabled:"), enabled);
}
