/*
 FBD — runtime shims for the SLVirtualDisplay ObjC API (macOS 26+).
 Signature ground truth: method type encodings dumped from SkyLight on macOS 27:

   -[SLVirtualDisplayConfiguration initWithName:vendorID:productID:serialNumber:sizeInMillimeters:maximumSizeInPixels:chromaticities:error:]
       @104@0:8@16Q24Q32Q40{?=ff}48{?=II}56{?={?=ff}{?=ff}{?=ff}{?=ff}}64^@96
   -[SLVirtualDisplayMode initWithSizeInPixels:sizeInPoints:refreshRate:error:]
       @44@0:8{?=II}16{?=II}24f32^@36
   -[SLVirtualDisplaySettings initWithNativeMode:preferredMode:optionalModes:rotations:error:]
       @56@0:8@16@24@32Q40^@48
   -[SLVirtualDisplay initWithConfiguration:error:]  @32@0:8@16^@24
   -[SLVirtualDisplay displayID]  I16@0:8
   -[SLVirtualDisplay applySettings:error:]  B32@0:8@16^@24
   -[SLVirtualDisplay destroy]  v16@0:8

 NOTE: structs are NOT CGSize — millimeters is {float,float}, pixels are
 {uint32,uint32}, refreshRate is a float, chromaticities is 4×{float,float}.
 Variadic objc_msgSend calls pass structs on the stack while the ObjC ABI
 expects registers, so every call uses an exact non-variadic cast.
 */

#include <objc/message.h>
#include <objc/runtime.h>
#include <stdint.h>

typedef void *fbd_id;

typedef struct { float x, y; } fbd_point;
typedef struct { uint32_t w, h; } fbd_size_i;
typedef struct { fbd_point red, green, blue, white; } fbd_chromaticities;

static SEL fbd_sel(const char *s) { return sel_registerName(s); }
static fbd_id fbd_alloc(fbd_id cls) { return ((fbd_id (*)(fbd_id, SEL))objc_msgSend)(cls, fbd_sel("alloc")); }

fbd_id FBDVDConfigCreate(fbd_id cls, fbd_id name, uint64_t vendor, uint64_t product, uint64_t serial,
                         fbd_point mm, fbd_size_i maxPixels, fbd_chromaticities chroma, void **err) {
    fbd_id inst = fbd_alloc(cls);
    typedef fbd_id (*Fn)(fbd_id, SEL, fbd_id, uint64_t, uint64_t, uint64_t, fbd_point, fbd_size_i, fbd_chromaticities, void **);
    return ((Fn)objc_msgSend)(inst, fbd_sel("initWithName:vendorID:productID:serialNumber:sizeInMillimeters:maximumSizeInPixels:chromaticities:error:"),
        name, vendor, product, serial, mm, maxPixels, chroma, err);
}

fbd_id FBDVDModeCreate(fbd_id cls, fbd_size_i pixels, fbd_size_i points, float refresh, void **err) {
    fbd_id inst = fbd_alloc(cls);
    typedef fbd_id (*Fn)(fbd_id, SEL, fbd_size_i, fbd_size_i, float, void **);
    return ((Fn)objc_msgSend)(inst, fbd_sel("initWithSizeInPixels:sizeInPoints:refreshRate:error:"), pixels, points, refresh, err);
}

fbd_id FBDVDSettingsCreate(fbd_id cls, fbd_id native, fbd_id preferred, fbd_id optionalModes, uint64_t rotations, void **err) {
    fbd_id inst = fbd_alloc(cls);
    typedef fbd_id (*Fn)(fbd_id, SEL, fbd_id, fbd_id, fbd_id, uint64_t, void **);
    return ((Fn)objc_msgSend)(inst, fbd_sel("initWithNativeMode:preferredMode:optionalModes:rotations:error:"), native, preferred, optionalModes, rotations, err);
}

fbd_id FBDVDCreate(fbd_id cls, fbd_id config, void **err) {
    fbd_id inst = fbd_alloc(cls);
    typedef fbd_id (*Fn)(fbd_id, SEL, fbd_id, void **);
    return ((Fn)objc_msgSend)(inst, fbd_sel("initWithConfiguration:error:"), config, err);
}

uint32_t FBDVDDisplayID(fbd_id vd) {
    typedef uint32_t (*Fn)(fbd_id, SEL);
    return ((Fn)objc_msgSend)(vd, fbd_sel("displayID"));
}

int FBDVDApplySettings(fbd_id vd, fbd_id settings, void **err) {
    typedef int (*Fn)(fbd_id, SEL, fbd_id, void **);
    return ((Fn)objc_msgSend)(vd, fbd_sel("applySettings:error:"), settings, err);
}

void FBDVDDestroy(fbd_id vd) {
    typedef void (*Fn)(fbd_id, SEL);
    ((Fn)objc_msgSend)(vd, fbd_sel("destroy"));
}
