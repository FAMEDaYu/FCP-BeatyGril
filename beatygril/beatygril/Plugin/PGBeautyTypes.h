#pragma once
#include <stdint.h>
#include <stddef.h>
#include <math.h>

// Persisted FxPlug render state. Append fields and bump version for migrations.
typedef struct {
    uint32_t version;
    float amount, skinBrightness, skinHue, skinSaturation, skinEvenTone;
    float midtoneDetail, highPassDetail, teethWhitening, eyeBrightening;
    float radius, sharpness, mix, maskThreshold, maskSoftness, maskEdgeProtect;
    float faceThin, faceBigEye, faceShort, faceNarrow, faceChin, faceV;
    float faceJaw, faceCheekbone, faceSmallHead, faceSmallHeadRange;
    float faceJumpGuardRange, selectionX, selectionY;
    uint32_t featureProtection, skinTonePreset, showMask, invertMask, debugChannel;
    uint32_t showFaceBoxes, showTrackBox, singleFace, fastMultiFace, trackingEnabled, targetIndex;
    // v2 keeps the entire 160-byte v1 prefix, including legacy bool/strength IDs.
    float featureProtectionAmount, nonSkinProtection, microDetail;
} PGBeautySettings;

enum { PGBeautySettingsV1Size = 160, PGBeautySettingsVersion = 2 };
_Static_assert(offsetof(PGBeautySettings,featureProtectionAmount)==PGBeautySettingsV1Size,
               "The v1 render-state prefix must remain stable");

static inline PGBeautySettings PGBeautyDefaults(void) {
    PGBeautySettings s = {0};
    s.version = PGBeautySettingsVersion;
    s.amount = 1.0f;
    s.radius = 8.0f;
    s.mix = 1.0f;
    s.maskThreshold = 148.0f;
    s.maskSoftness = 0.6f;
    s.maskEdgeProtect = 0.4f;
    s.featureProtection = 1;
    s.featureProtectionAmount = 1;
    s.nonSkinProtection = 1;
    s.faceJumpGuardRange = 1.8f;
    s.selectionX = s.selectionY = 0.5f;
    return s;
}
