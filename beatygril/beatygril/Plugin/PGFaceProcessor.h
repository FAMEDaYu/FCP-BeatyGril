#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
#import <CoreMedia/CoreMedia.h>
#import <Vision/Vision.h>
#import "PGBeautyTypes.h"

NS_ASSUME_NONNULL_BEGIN

@interface PGFaceFrame : NSObject
/// Vision observations in normalized, bottom-left image coordinates. Restored
/// observations retain their bounding box; render geometry is stored separately.
@property (nonatomic, copy, readonly) NSArray<VNFaceObservation *> *faces;
@property (nonatomic, strong, readonly) CIImage *skinMask;
/// Continuous face support before eye/nose/lip detail-protection cutouts.
@property (nonatomic, strong, readonly) CIImage *colorMask;
@property (nonatomic, strong, readonly) CIImage *teethMask;
@property (nonatomic, strong, readonly) CIImage *eyeMask;
@property (nonatomic, strong, readonly) CIImage *image;
/// Transparent face/target outlines, for compositing after beauty processing.
@property (nonatomic, strong, readonly) CIImage *overlayImage;
@end

@interface PGFaceProcessor : NSObject
- (nullable PGFaceFrame *)processImage:(CIImage *)image
                             settings:(PGBeautySettings)settings
                                 time:(CMTime)time
                                error:(NSError * _Nullable * _Nullable)error;
- (BOOL)analyzeImage:(CIImage *)image
           settings:(PGBeautySettings)settings
               time:(CMTime)time
              error:(NSError * _Nullable * _Nullable)error;
- (void)resetTracking;
/// Targets are zero-based (0, 1, 2). Data is a versioned property-list archive,
/// independent of Vision implementation classes. Only analysis writes frames.
- (nullable NSData *)trackingDataForTarget:(NSUInteger)target;
- (void)setTrackingData:(nullable NSData *)data forTarget:(NSUInteger)target;
@end

NS_ASSUME_NONNULL_END
