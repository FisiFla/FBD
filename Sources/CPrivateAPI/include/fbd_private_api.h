#ifndef FBD_PRIVATE_API_H
#define FBD_PRIVATE_API_H

/*
 FBD — typed declarations of macOS private APIs used by the app.
 Signatures verified against the macOS 27 dyld export trie (dyld_info -exports)
 and the FOSS implementations they are modelled on (lunar, displayplacer).

 Only the surface actually needed by FBD is declared here. Add per tier.
 */

#include <CoreGraphics/CoreGraphics.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>

#pragma mark - CoreDisplay — display info dictionary

CFDictionaryRef CoreDisplay_DisplayCreateInfoDictionary(CGDirectDisplayID display);

#pragma mark - CGS (CoreGraphicsServices) — display modes & configuration

struct CGSDisplayModeDescription {
    int displayModeNumber;
    int flags;
    int width;
    int height;
    int depth;
    int rowBytes;
    int bitsPerPixel;
    int bitsPerSample;
    int samplesPerPixel;
    int refreshRate;
    int horizontalResolution;
    int verticalResolution;
    char encoding[129];
    int version;
    int length;
    int fixPtRefreshRate;
    int ioModeInfoFlags;
    int ioDisplayModeNumber;
    int pixelsWide;
    int pixelsHigh;
    float resolution;
};
/* sizeof(struct CGSDisplayModeDescription) == 212 (0xD4) */

CGError CGSGetDisplayList(int maxDisplays, CGDirectDisplayID *displays, int *count);
CGError CGSGetCurrentDisplayMode(CGDirectDisplayID display, int *modeNum);
CGError CGSGetNumberOfDisplayModes(CGDirectDisplayID display, int *nModes);
CGError CGSGetDisplayModeDescriptionOfLength(CGDirectDisplayID display, int idx, struct CGSDisplayModeDescription *desc, int length);
CGError CGSConfigureDisplayMode(CGDisplayConfigRef config, CGDirectDisplayID display, int modeNum);
CGError CGSConfigureDisplayEnabled(CGDisplayConfigRef config, CGDirectDisplayID display, bool enabled);

#pragma mark - DisplayServices — Apple display brightness

int DisplayServicesGetBrightness(CGDirectDisplayID display, float *brightness);
int DisplayServicesSetBrightness(CGDirectDisplayID display, float brightness);
int DisplayServicesGetLinearBrightness(CGDirectDisplayID display, float *brightness);
int DisplayServicesSetLinearBrightness(CGDirectDisplayID display, float brightness);
bool DisplayServicesCanChangeBrightness(CGDirectDisplayID display);
int DisplayServicesHasAmbientLightCompensation(CGDirectDisplayID display);
int DisplayServicesAmbientLightCompensationEnabled(CGDirectDisplayID display, bool *enabled);
int DisplayServicesEnableAmbientLightCompensation(CGDirectDisplayID display, bool enabled);
int DisplayServicesResetAmbientLight(CGDirectDisplayID display1, CGDirectDisplayID display2);
/* Explicit function-pointer typedef: the CFNotificationCallback import crashes
   the Swift compiler when passed a closure argument on this SDK. */
typedef void (*FBDDisplayServicesBrightnessChangeCallback)(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo);
int DisplayServicesRegisterForBrightnessChangeNotifications(CGDirectDisplayID display, CGDirectDisplayID displayObserver, FBDDisplayServicesBrightnessChangeCallback callback);
int DisplayServicesUnregisterForBrightnessChangeNotifications(CGDirectDisplayID display, CGDirectDisplayID displayObserver);

#pragma mark - IOAVService — DDC/EDID over I2C (Apple Silicon)

typedef struct __IOAVService *IOAVServiceRef;

IOAVServiceRef IOAVServiceCreateWithService(io_service_t service);
CFDictionaryRef IOAVServiceCopyEDID(IOAVServiceRef service);
kern_return_t IOAVServiceSetVirtualEDIDMode(IOAVServiceRef service, CFDictionaryRef edid);
kern_return_t IOAVServiceReadI2C(IOAVServiceRef service, uint32_t address, uint8_t *data, uint32_t length);
kern_return_t IOAVServiceWriteI2C(IOAVServiceRef service, uint32_t address, uint8_t *data, uint32_t length);

#pragma mark - SkyLight — minimal Tier 1 surface

int SLSMainConnectionID(void);
CGError SLSDetectDisplays(int cid);

#pragma mark - SkyLight — display presets + HDR mode (Tier 2, verified on macOS 27)

/* Signatures verified empirically: CopyPresetData(display, index) confirmed by
   XDR-Enabler; validity/writability/factory-default confirmed by probe on
   macOS 27 (presets 0–10 valid, 11–15 blank & writable on built-in XDR).
   NOTE: SLSDisplayGetPresetCount returns status 51 with every candidate
   signature on macOS 27 — enumeration uses IsPresetValid/CopyPresetData. */
int SLSDisplayIsPresetValid(int displayID, int presetIndex);
int SLSDisplayIsPresetWritable(int displayID, int presetIndex);
int SLSDisplayGetFactoryDefaultPresetIndex(int displayID);
int SLSDisplayGetActivePresetIndex(int displayID, int *index);
int SLSDisplaySetActivePresetIndex(int displayID, int presetIndex);
CFDictionaryRef SLSDisplayCopyPresetData(int displayID, int presetIndex);
CFDictionaryRef SLSDisplayCopyActivePreset(int displayID);
void SLSDisplaySetPresetData(int displayID, int presetIndex, CFDictionaryRef data);
/* 1-arg (Bool return) per probe; SetHDRModeEnabled 2-arg symmetric (untested
   write — only called with the current state by the controller). */
int SLSDisplaySupportsHDRMode(int displayID);
int SLSDisplaySetUnderscan(int displayID, bool enabled);
int SLSDisplayIsHDRModeEnabled(int displayID);
int SLSDisplaySetHDRModeEnabled(int displayID, bool enabled);

#pragma mark - IOMobileFramebuffer — built-in panel control (Tier 2, experimental)

/* Entitlement-gated on macOS 27 (IOMobileFramebufferOpen → kIOReturnNotPrivileged);
   wrappers degrade gracefully. No Close export exists in the framework. */
typedef struct __IOMobileFramebuffer *IOMobileFramebufferRef;
typedef int IOMobileFramebufferReturn;
typedef struct {
    uint32_t values[771]; /* 257 entries × 3 channels, 16.16 fixed point */
} IOMobileFramebufferGammaTable;

kern_return_t IOMobileFramebufferOpen(io_service_t service, uint32_t type, uint32_t flags, IOMobileFramebufferRef *fb);
IOMobileFramebufferReturn IOMobileFramebufferGetColorRemapMode(IOMobileFramebufferRef fb, int *mode);
IOMobileFramebufferReturn IOMobileFramebufferSetColorRemapMode(IOMobileFramebufferRef fb, int mode);
IOMobileFramebufferReturn IOMobileFramebufferGetGammaTable(IOMobileFramebufferRef fb, uint32_t *table);
IOMobileFramebufferReturn IOMobileFramebufferSetGammaTable(IOMobileFramebufferRef fb, const uint32_t *table);

/* Test helper (used by unit tests only): build a CGSDisplayModeDescription. */
static inline struct CGSDisplayModeDescription fbd_make_test_mode(int modeNumber, int flags, int width, int height, int pixelsWide, int pixelsHigh, int fixPtRefreshRate, const char *encoding) {
    struct CGSDisplayModeDescription desc;
    memset(&desc, 0, sizeof(desc));
    desc.displayModeNumber = modeNumber;
    desc.flags = flags;
    desc.width = width;
    desc.height = height;
    desc.pixelsWide = pixelsWide;
    desc.pixelsHigh = pixelsHigh;
    desc.fixPtRefreshRate = fixPtRefreshRate;
    if (encoding) {
        strncpy(desc.encoding, encoding, sizeof(desc.encoding) - 1);
    }
    return desc;
}

#pragma mark - SLVirtualDisplay runtime shims (macOS 26+; see fbd_virtual_display.c)

typedef struct { float x, y; } fbd_point;
typedef struct { uint32_t w, h; } fbd_size_i;
typedef struct { fbd_point red, green, blue, white; } fbd_chromaticities;

void *FBDVDConfigCreate(void *cls, void *name, uint64_t vendor, uint64_t product, uint64_t serial,
                        fbd_point mm, fbd_size_i maxPixels, fbd_chromaticities chroma, void **err);
void *FBDVDModeCreate(void *cls, fbd_size_i pixels, fbd_size_i points, float refresh, void **err);
void *FBDVDSettingsCreate(void *cls, void *native, void *preferred, void *optionalModes, uint64_t rotations, void **err);
void *FBDVDCreate(void *cls, void *config, void **err);
uint32_t FBDVDDisplayID(void *vd);
int FBDVDApplySettings(void *vd, void *settings, void **err);
void FBDVDDestroy(void *vd);

#endif /* FBD_PRIVATE_API_H */
