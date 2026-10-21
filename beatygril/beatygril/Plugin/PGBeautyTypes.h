#pragma once
#include <stdint.h>

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
} PGBeautySettings;

static inline PGBeautySettings PGBeautyDefaults(void) {
    PGBeautySettings s = {0};
    s.version = 1;
    s.amount = 1.0f;
    s.radius = 8.0f;
    s.mix = 1.0f;
    s.maskThreshold = 148.0f;
    s.maskSoftness = 0.6f;
    s.maskEdgeProtect = 0.4f;
    s.featureProtection = 1;
    s.faceJumpGuardRange = 1.8f;
    s.selectionX = s.selectionY = 0.5f;
    return s;
}
