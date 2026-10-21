// Offline diagnostic only. It uses Apple's public Vision API, never a host UI
// or the reference plug-in. User media and generated observations stay local.
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <Vision/Vision.h>
#import <ImageIO/ImageIO.h>
#include <math.h>

static NSArray *PGProbePoint(CGPoint p) { return @[@(p.x), @(p.y)]; }
static NSArray *RegionIndices(VNFaceLandmarkRegion2D *region, VNFaceLandmarkRegion2D *all) {
    NSMutableArray *indices = [NSMutableArray array];
    for (NSUInteger i=0; i<region.pointCount; i++) {
        CGPoint p=region.normalizedPoints[i];
        double best=INFINITY; NSUInteger index=NSNotFound;
        for (NSUInteger j=0; j<all.pointCount; j++) {
            CGPoint q=all.normalizedPoints[j];
            double d=hypot(p.x-q.x,p.y-q.y);
            if (d<best) { best=d; index=j; }
        }
        // Preserve an unmatched result instead of inventing a point identity.
        [indices addObject:best<1e-6 ? @(index) : NSNull.null];
    }
    return indices;
}

int main(int argc, const char *argv[]) { @autoreleasepool {
    if (argc<4) {
        fprintf(stderr,"usage: inspect-face-geometry <video> <output.json> <seconds>...\n");
        return 2;
    }
    NSURL *source=[NSURL fileURLWithPath:@(argv[1])];
    NSURL *output=[NSURL fileURLWithPath:@(argv[2])];
    if (![NSFileManager.defaultManager fileExistsAtPath:source.path]) return 2;
    NSError *error=nil;
    if (![NSFileManager.defaultManager createDirectoryAtURL:[output URLByDeletingLastPathComponent]
                              withIntermediateDirectories:YES attributes:nil error:&error]) {
        fprintf(stderr,"%s\n",error.description.UTF8String); return 1;
    }
    AVURLAsset *asset=[AVURLAsset URLAssetWithURL:source options:nil];
    AVAssetImageGenerator *generator=[[AVAssetImageGenerator alloc] initWithAsset:asset];
    generator.appliesPreferredTrackTransform=YES;
    generator.maximumSize=CGSizeMake(1280,1280);
    generator.requestedTimeToleranceBefore=kCMTimeZero;
    generator.requestedTimeToleranceAfter=kCMTimeZero;
    NSMutableArray *frames=[NSMutableArray array];
    for (int a=3; a<argc; a++) { @autoreleasepool {
        char *end=NULL; double seconds=strtod(argv[a],&end);
        if (!end || end==argv[a] || *end || !isfinite(seconds) || seconds<0) return 2;
        CMTime actual=kCMTimeInvalid;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        CGImageRef image=[generator copyCGImageAtTime:CMTimeMakeWithSeconds(seconds,60000)
                                          actualTime:&actual error:&error];
#pragma clang diagnostic pop
        if (!image) { fprintf(stderr,"%s\n",error.description.UTF8String); return 1; }
        VNDetectFaceLandmarksRequest *request=[VNDetectFaceLandmarksRequest new];
        if (![VNDetectFaceLandmarksRequest.supportedRevisions containsIndex:VNDetectFaceLandmarksRequestRevision3] ||
            ![VNDetectFaceLandmarksRequest revision:VNDetectFaceLandmarksRequestRevision3
                             supportsConstellation:VNRequestFaceLandmarksConstellation76Points]) {
            CGImageRelease(image); fprintf(stderr,"Vision revision 3 / 76 points unavailable\n"); return 1;
        }
        request.revision=VNDetectFaceLandmarksRequestRevision3;
        request.constellation=VNRequestFaceLandmarksConstellation76Points;
        VNImageRequestHandler *handler=[[VNImageRequestHandler alloc] initWithCGImage:image options:@{}];
        if (![handler performRequests:@[request] error:&error]) {
            CGImageRelease(image); fprintf(stderr,"%s\n",error.description.UTF8String); return 1;
        }
        NSMutableArray *faces=[NSMutableArray array];
        for (VNFaceObservation *face in request.results) {
            VNFaceLandmarks2D *lm=face.landmarks;
            VNFaceLandmarkRegion2D *all=lm.allPoints;
            CGRect box=face.boundingBox;
            NSMutableArray *points=[NSMutableArray array];
            for (NSUInteger i=0; i<all.pointCount; i++) {
                CGPoint p=all.normalizedPoints[i];
                [points addObject:PGProbePoint(CGPointMake(box.origin.x+p.x*box.size.width,
                                                   box.origin.y+p.y*box.size.height))];
            }
            NSDictionary *regions=@{@"contour":RegionIndices(lm.faceContour,all),
              @"leftEye":RegionIndices(lm.leftEye,all), @"rightEye":RegionIndices(lm.rightEye,all),
              @"leftPupil":RegionIndices(lm.leftPupil,all), @"rightPupil":RegionIndices(lm.rightPupil,all),
              @"nose":RegionIndices(lm.nose,all), @"noseCrest":RegionIndices(lm.noseCrest,all),
              @"outerLips":RegionIndices(lm.outerLips,all), @"innerLips":RegionIndices(lm.innerLips,all)};
            [faces addObject:@{@"box":@[@(box.origin.x),@(box.origin.y),@(box.size.width),@(box.size.height)],
              @"confidence":@(face.confidence), @"yaw":face.yaw?:NSNull.null,
              @"roll":face.roll?:NSNull.null, @"pitch":face.pitch?:NSNull.null,
              @"allPoints":points, @"regions":regions}];
        }
        NSString *name=[NSString stringWithFormat:@"frame-%0.3f.png",seconds];
        NSURL *png=[[output URLByDeletingLastPathComponent] URLByAppendingPathComponent:name];
        CGImageDestinationRef destination=CGImageDestinationCreateWithURL((__bridge CFURLRef)png,CFSTR("public.png"),1,NULL);
        if (!destination) { CGImageRelease(image); return 1; }
        CGImageDestinationAddImage(destination,image,NULL);
        BOOL saved=CGImageDestinationFinalize(destination); CFRelease(destination);
        [frames addObject:@{@"requestedSeconds":@(seconds), @"actualSeconds":@(CMTimeGetSeconds(actual)),
          @"width":@(CGImageGetWidth(image)), @"height":@(CGImageGetHeight(image)),
          @"image":name, @"faces":faces}];
        CGImageRelease(image); if (!saved) return 1;
    }}
    NSDictionary *result=@{@"schema":@1,@"source":source.path,@"coordinateSystem":@"full-image normalized, y up",
      @"authority":@"independent Apple Vision probe, not reference plug-in execution",
      @"requestRevision":@3,@"constellation":@76,@"frames":frames};
    NSData *json=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:&error];
    if (!json || ![json writeToURL:output options:NSDataWritingAtomic error:&error]) {
        fprintf(stderr,"%s\n",error.description.UTF8String); return 1;
    }
    printf("Saved %lu independent frame observations.\n",(unsigned long)frames.count);
    return 0;
}}
