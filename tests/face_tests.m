#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
#import <Vision/Vision.h>
#import <ImageIO/ImageIO.h>
#import "PGFaceProcessor.h"

// Injectable detections let geometry, selection and saved-frame behavior be
// tested independently of the separate public-domain NASA portrait fixture.
@interface PGFaceProcessor (TestDetection)
- (NSArray<VNFaceObservation *> *)observationsInImage:(CIImage *)image settings:(PGBeautySettings)settings error:(NSError **)error;
@end
@interface PGFaceFixture : PGFaceProcessor
@property (nonatomic, copy) NSArray<VNFaceObservation *> *detections;
@property (nonatomic) NSUInteger detectionCount;
@end
@implementation PGFaceFixture
- (NSArray<VNFaceObservation *> *)observationsInImage:(CIImage *)image settings:(PGBeautySettings)settings error:(NSError **)error {
    self.detectionCount++;
    return self.detections ?: @[];
}
@end

static NSUInteger PGChecks = 0;
static void Check(BOOL condition, NSString *description) {
    PGChecks++;
    if (!condition) { fprintf(stderr, "FAIL: %s\n", description.UTF8String); exit(1); }
}
static VNFaceObservation *Face(CGRect box) {
    return [VNFaceObservation faceObservationWithRequestRevision:VNDetectFaceLandmarksRequestRevision3 boundingBox:box roll:nil yaw:nil pitch:nil];
}
static NSData *Pixels(CIContext *context, CIImage *image) {
    CGRect bounds = image.extent;
    NSUInteger width = (NSUInteger)bounds.size.width, height = (NSUInteger)bounds.size.height;
    NSMutableData *data = [NSMutableData dataWithLength:width * height * 4];
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    [context render:image toBitmap:data.mutableBytes rowBytes:width * 4 bounds:bounds format:kCIFormatRGBA8 colorSpace:colorSpace];
    CGColorSpaceRelease(colorSpace);
    return data;
}
static unsigned char Channel(CIContext *context, CIImage *image, double x, double y, NSUInteger channel) {
    unsigned char pixel[4] = {0};
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    [context render:image toBitmap:pixel rowBytes:4 bounds:CGRectMake(x, y, 1, 1) format:kCIFormatRGBA8 colorSpace:space];
    CGColorSpaceRelease(space);
    return pixel[channel];
}
static CIImage *Gradient(void) {
    NSMutableData *data = [NSMutableData dataWithLength:128 * 128 * 4];
    unsigned char *p = data.mutableBytes;
    for (NSUInteger y = 0; y < 128; y++) for (NSUInteger x = 0; x < 128; x++) {
        NSUInteger index = 4 * (y * 128 + x);
        p[index] = x * 2; p[index + 1] = y * 2;
        p[index + 2] = ((x / 8 + y / 8) % 2) * 220 + 15; p[index + 3] = 255;
    }
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CIImage *image = [CIImage imageWithBitmapData:data bytesPerRow:128 * 4 size:CGSizeMake(128, 128) format:kCIFormatRGBA8 colorSpace:space];
    CGColorSpaceRelease(space);
    return image;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        CIContext *context = [CIContext contextWithOptions:@{kCIContextCacheIntermediates:@NO}];
        CIImage *image = Gradient();
        PGBeautySettings settings = PGBeautyDefaults();
        PGFaceFixture *processor = [[PGFaceFixture alloc] init];
        VNFaceObservation *left = Face(CGRectMake(0.08, 0.18, 0.36, 0.62));
        VNFaceObservation *right = Face(CGRectMake(0.64, 0.23, 0.28, 0.53));
        processor.detections = @[left, right];
        NSError *error = nil;
        PGFaceFrame *frame = [processor processImage:image settings:settings time:kCMTimeZero error:&error];
        Check(frame != nil && error == nil, @"kernels initialize and process finite input");
        Check(frame.faces.count == 2, @"multi-face mode retains both detections");
        Check([Pixels(context, frame.image) isEqualToData:Pixels(context, image)], @"zero geometry controls preserve original pixels");
        Check(Channel(context, frame.skinMask, 1, 1, 0) == 0, @"skin mask excludes background");
        Check(Channel(context, frame.skinMask, 18, 54, 0) > 150, @"skin mask covers cheek");
        Check(Channel(context, frame.eyeMask, 23, 71, 0) > 40, @"eye mask includes estimated eye region");
        Check(Channel(context, frame.teethMask, 33, 42, 0) > 20, @"teeth mask includes inner mouth region");
        PGBeautySettings unprotected = settings; unprotected.featureProtection = 0;
        PGFaceFrame *withoutProtection = [processor processImage:image settings:unprotected time:kCMTimeZero error:&error];
        Check(Channel(context, frame.skinMask, 23, 71, 0) < Channel(context, withoutProtection.skinMask, 23, 71, 0), @"feature protection removes eye from skin smoothing");

        settings.singleFace = 1; settings.selectionX = 0.78; settings.selectionY = 0.45;
        frame = [processor processImage:image settings:settings time:kCMTimeZero error:&error];
        Check(frame.faces.count == 1 && frame.faces.firstObject.boundingBox.origin.x > 0.5, @"single-face selection uses normalized bottom-left point");
        settings.selectionX = 0.25; settings.selectionY = 0.5;
        settings.trackingEnabled = 1; settings.faceJumpGuardRange = 0.5;
        CMTime first = CMTimeMake(1, 24), second = CMTimeMake(2, 24);
        Check([processor analyzeImage:image settings:settings time:first error:&error], @"analysis stores first precise frame");
        processor.detections = @[right];
        Check([processor analyzeImage:image settings:settings time:second error:&error], @"analysis stores guarded missing-target frame");
        NSUInteger detectionsBeforeRender = processor.detectionCount;
        PGFaceFrame *secondFrame = [processor processImage:image settings:settings time:second error:&error];
        PGFaceFrame *firstFrame = [processor processImage:image settings:settings time:CMTimeMake(2, 48) error:&error];
        Check(secondFrame.faces.count == 0, @"jump guard rejects distant replacement face");
        Check(firstFrame.faces.count == 1 && firstFrame.faces.firstObject.boundingBox.origin.x < 0.5, @"reverse render retrieves exact earlier frame");
        Check(processor.detectionCount == detectionsBeforeRender, @"saved frame lookup does not re-run detection");
        Check(Channel(context, secondFrame.skinMask, 33, 43, 0) == 0, @"rejected target has black mask");
        Check([processor analyzeImage:image settings:settings time:CMTimeMake(3, 24) error:&error], @"analysis continues after a lost target");
        Check([processor processImage:image settings:settings time:CMTimeMake(3, 24) error:&error].faces.count == 0, @"jump guard keeps last valid identity across a missed frame");
        Check([processor processImage:image settings:settings time:CMTimeMake(7, 48) error:&error].faces.count == 0, @"unsaved frame detects current image with deterministic analyzed identity guard");
        Check([processor analyzeImage:image settings:settings time:CMTimeMake(3, 1) error:&error], @"analysis tolerates a seek across lost detections");
        Check([processor processImage:image settings:settings time:CMTimeMake(3, 1) error:&error].faces.count == 0, @"jump guard does not silently reacquire a stranger after a long gap");
        NSData *archive = [processor trackingDataForTarget:0];
        Check(archive.length > 0, @"tracking is persistable");
        PGFaceFixture *restored = [[PGFaceFixture alloc] init];
        [restored setTrackingData:archive forTarget:0];
        PGFaceFrame *restoredFrame = [restored processImage:image settings:settings time:first error:&error];
        Check(restoredFrame.faces.count == 1 && restored.detectionCount == 0, @"restored target serves exact frame without detections");
        Check([Pixels(context, firstFrame.skinMask) isEqualToData:Pixels(context, restoredFrame.skinMask)], @"restored geometry reproduces feature masks");
        Check([restored trackingDataForTarget:1] == nil && [restored trackingDataForTarget:2] == nil, @"three target stores are independent");
        [restored setTrackingData:archive forTarget:2];
        settings.targetIndex = 2;
        Check([restored processImage:image settings:settings time:first error:&error].faces.count == 1, @"third target stores and restores separately");
        settings.targetIndex = 0;
        [restored processImage:image settings:settings time:CMTimeMake(4, 24) error:&error];
        Check(restored.detectionCount == 1, @"missing exact time uses stateless detection");
        [restored setTrackingData:[@"invalid archive" dataUsingEncoding:NSUTF8StringEncoding] forTarget:0];
        Check([restored trackingDataForTarget:0] == nil, @"invalid archive is rejected without exception");
        [restored resetTracking];
        Check([restored trackingDataForTarget:2] == nil, @"reset clears all targets");
        error = nil;
        Check(![restored analyzeImage:image settings:settings time:kCMTimeInvalid error:&error] && error != nil, @"analysis rejects invalid times");

        processor.detections = @[Face(CGRectMake(0.2, 0.15, 0.6, 0.7))];
        settings = PGBeautyDefaults();
        NSData *base = Pixels(context, image);
        NSString *names[] = {@"thin", @"big eyes", @"short", @"narrow", @"chin", @"V", @"jaw", @"cheekbone", @"small head"};
        for (NSUInteger i = 0; i < 9; i++) {
            PGBeautySettings changed = settings;
            float *controls[] = {&changed.faceThin, &changed.faceBigEye, &changed.faceShort, &changed.faceNarrow, &changed.faceChin, &changed.faceV, &changed.faceJaw, &changed.faceCheekbone, &changed.faceSmallHead};
            *controls[i] = 1;
            PGFaceFrame *warped = [processor processImage:image settings:changed time:kCMTimeZero error:&error];
            Check(warped != nil && ![Pixels(context, warped.image) isEqualToData:base], [@"geometry control changes pixels: " stringByAppendingString:names[i]]);
            Check(CGRectEqualToRect(warped.image.extent, image.extent), @"warp preserves image extent");
        }
        settings.faceShort = 0.8;
        NSData *positive = Pixels(context, [processor processImage:image settings:settings time:kCMTimeZero error:&error].image);
        settings.faceShort = -0.8;
        Check(![positive isEqualToData:Pixels(context, [processor processImage:image settings:settings time:kCMTimeZero error:&error].image)], @"signed short-face control has distinct directions");
        settings = PGBeautyDefaults(); settings.showFaceBoxes = 1;
        frame = [processor processImage:image settings:settings time:kCMTimeZero error:&error];
        Check(Channel(context, frame.overlayImage, 26, 64, 3) > 0, @"face outlines provide separate final-composite overlay");
        CIImage *offset = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(30, 40)];
        frame = [processor processImage:offset settings:settings time:kCMTimeZero error:&error];
        Check(CGRectEqualToRect(frame.image.extent, offset.extent), @"nonzero image origins survive masks and warp");

        PGFaceProcessor *vision = [[PGFaceProcessor alloc] init];
        CIImage *blank = [[CIImage imageWithColor:CIColor.grayColor] imageByCroppingToRect:CGRectMake(0, 0, 128, 128)];
        frame = [vision processImage:blank settings:PGBeautyDefaults() time:kCMTimeZero error:&error];
        Check(frame != nil && frame.faces.count == 0, @"real Vision request accepts blank image without false faces");

        NSString *fixturePath = argc > 1 ? @(argv[1]) : @"tests/fixtures/astronaut.png";
        CIImage *portrait = [CIImage imageWithContentsOfURL:[NSURL fileURLWithPath:fixturePath]];
        Check(portrait != nil, @"public-domain NASA portrait fixture opens");
        settings = PGBeautyDefaults();
        PGFaceFrame *portraitFrame = [vision processImage:portrait settings:settings time:kCMTimeZero error:&error];
        Check(portraitFrame.faces.count > 0, @"real Vision detects astronaut portrait");
        Check(CGRectEqualToRect(portraitFrame.skinMask.extent, portrait.extent) && CGRectEqualToRect(portraitFrame.teethMask.extent, portrait.extent) && CGRectEqualToRect(portraitFrame.eyeMask.extent, portrait.extent), @"all real portrait masks have finite input extent");
        VNFaceObservation *actual = portraitFrame.faces.firstObject;
        Check(actual.landmarks.allPoints.pointCount > 30 && actual.landmarks.leftEye.pointCount > 3, @"real Vision returns detailed facial landmarks");
        const CGPoint *eyePoints = actual.landmarks.leftEye.normalizedPoints;
        CGPoint eye = CGPointZero;
        for (NSUInteger i = 0; i < actual.landmarks.leftEye.pointCount; i++) { eye.x += eyePoints[i].x; eye.y += eyePoints[i].y; }
        eye.x /= actual.landmarks.leftEye.pointCount; eye.y /= actual.landmarks.leftEye.pointCount;
        CGRect actualBox = actual.boundingBox;
        eye.x = (actualBox.origin.x + eye.x * actualBox.size.width) * portrait.extent.size.width;
        eye.y = (actualBox.origin.y + eye.y * actualBox.size.height) * portrait.extent.size.height;
        Check(Channel(context, portraitFrame.eyeMask, floor(eye.x), floor(eye.y), 0) > 80, @"landmark-derived eye mask lands on real eye");
        Check(Channel(context, portraitFrame.skinMask, floor(eye.x), floor(eye.y), 0) < 100, @"real facial feature mask excludes eye from smoothing");
        settings.faceThin = 0.4; settings.faceBigEye = 0.25; settings.faceChin = 0.15; settings.faceSmallHead = 0.15;
        settings.faceSmallHeadRange = 0.6; settings.showFaceBoxes = 1;
        PGFaceFrame *beautified = [vision processImage:portrait settings:settings time:kCMTimeZero error:&error];
        Check(beautified != nil && ![Pixels(context, beautified.image) isEqualToData:Pixels(context, portrait)], @"real face geometry changes portrait pixels");
        Check(abs((int)Channel(context, beautified.image, 5, 300, 0) - (int)Channel(context, portrait, 5, 300, 0)) <= 1, @"face warp preserves distant portrait background pixels");
        settings.trackingEnabled = 1; settings.singleFace = 1;
        settings.selectionX = CGRectGetMidX(actualBox); settings.selectionY = CGRectGetMidY(actualBox);
        Check([vision analyzeImage:portrait settings:settings time:first error:&error], @"real landmarks analyze into persistent geometry");
        NSData *realArchive = [vision trackingDataForTarget:0];
        PGFaceFrame *analyzed = [vision processImage:portrait settings:settings time:first error:&error];
        PGFaceProcessor *realRestored = [[PGFaceProcessor alloc] init];
        [realRestored setTrackingData:realArchive forTarget:0];
        PGFaceFrame *restoredPortrait = [realRestored processImage:portrait settings:settings time:first error:&error];
        Check(restoredPortrait.faces.count == analyzed.faces.count && [Pixels(context, restoredPortrait.image) isEqualToData:Pixels(context, analyzed.image)], @"real face warp survives persistence byte-for-byte");
        Check([Pixels(context, restoredPortrait.eyeMask) isEqualToData:Pixels(context, analyzed.eyeMask)], @"real landmark eye mask survives persistence byte-for-byte");
        Check([Pixels(context, restoredPortrait.teethMask) isEqualToData:Pixels(context, analyzed.teethMask)], @"real landmark teeth mask survives persistence byte-for-byte");
        if (argc > 2) {
            CGFloat width = portrait.extent.size.width, height = portrait.extent.size.height;
            CIImage *after = [[beautified.overlayImage imageByCompositingOverImage:beautified.image] imageByCroppingToRect:portrait.extent];
            CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            CGContextRef canvas = CGBitmapContextCreate(NULL, width * 3, height, 8, width * 3 * 4, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
            NSArray *panels = @[portrait, after, portraitFrame.skinMask];
            for (NSUInteger panel = 0; panel < panels.count; panel++) {
                CGImageRef content = [context createCGImage:panels[panel] fromRect:portrait.extent];
                CGContextDrawImage(canvas, CGRectMake(panel * width, 0, width, height), content);
                CGImageRelease(content);
            }
            CGImageRef preview = CGBitmapContextCreateImage(canvas);
            CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:@(argv[2])], CFSTR("public.png"), 1, NULL);
            Check(destination != NULL && preview != NULL, @"portrait comparison preview allocates");
            CGImageDestinationAddImage(destination, preview, NULL);
            Check(CGImageDestinationFinalize(destination), @"portrait comparison preview writes PNG");
            CFRelease(destination); CGImageRelease(preview);
            CGContextRelease(canvas); CGColorSpaceRelease(space);
        }
        printf("Face processing: %lu checks passed\n", (unsigned long)PGChecks);
    }
    return 0;
}
