#import <CoreImage/CoreImage.h>
#import "PGBeautyTypes.h"

NS_ASSUME_NONNULL_BEGIN

/// Stateless, lazy Core Image graph. All masks use red=coverage and image coordinates.
/// Caller owns face detection, geometric warping, tracking, and the CIContext/Metal device.
/// showMask enables debugChannel 0=skin, 1=teeth, 2=eyes. invertMask affects each preview.
/// If the caller blends geometry plus beauty against the original, pass settings.mix=1.
@interface PGBeautyRenderer : NSObject
- (nullable CIImage *)processImage:(CIImage *)image
                         settings:(PGBeautySettings)settings
                         skinMask:(nullable CIImage *)skinMask
                        teethMask:(nullable CIImage *)teethMask
                          eyeMask:(nullable CIImage *)eyeMask
                            error:(NSError * _Nullable * _Nullable)error;
/// Face-based callers supply uncut coverage for smoothly blended color changes.
- (nullable CIImage *)processImage:(CIImage *)image
                         settings:(PGBeautySettings)settings
                         skinMask:(nullable CIImage *)skinMask
                        colorMask:(nullable CIImage *)colorMask
                        teethMask:(nullable CIImage *)teethMask
                          eyeMask:(nullable CIImage *)eyeMask
                            error:(NSError * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
