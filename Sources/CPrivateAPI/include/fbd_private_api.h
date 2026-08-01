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
int DisplayServicesRegisterForBrightnessChangeNotifications(CGDirectDisplayID display, CGDirectDisplayID displayObserver, CFNotificationCallback callback);
int DisplayServicesUnregisterForBrightnessChangeNotifications(CGDirectDisplayID display, CGDirectDisplayID displayObserver);

#pragma mark - IOAVService — DDC/EDID over I2C (Apple Silicon)

typedef struct __IOAVService *IOAVServiceRef;

IOAVServiceRef IOAVServiceCreateWithService(io_service_t service);
CFDictionaryRef IOAVServiceCopyEDID(IOAVServiceRef service);
kern_return_t IOAVServiceReadI2C(IOAVServiceRef service, uint32_t address, uint8_t *data, uint32_t length);
kern_return_t IOAVServiceWriteI2C(IOAVServiceRef service, uint32_t address, uint8_t *data, uint32_t length);

#pragma mark - SkyLight — minimal Tier 1 surface

int SLSMainConnectionID(void);
CGError SLSDetectDisplays(int cid);

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

#endif /* FBD_PRIVATE_API_H */
