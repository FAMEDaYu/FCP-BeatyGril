// The source kernels remain available on the supported macOS 12+ range. This
// keeps the processor self contained instead of requiring a separate metallib.
#define CI_SILENCE_GL_DEPRECATION 1
#import "PGFaceProcessor.h"
#include <math.h>
#include <float.h>

static NSString * const PGFaceErrorDomain = @"com.dayu.fcpbeautygirl.face";
// Contour origin / internal anchor, in the reference's recovered pin order.
// The unused middle entry of each reference triplet is intentionally omitted.
static const uint8_t PGThinPins[17][2] = {
    {75,6},{59,13},{74,47},{60,47},{73,47},{61,47},
    {72,48},{62,48},{71,48},{63,48},{70,49},{64,49},
    {69,49},{65,49},{68,52},{66,52},{67,47}
};
static const uint8_t PGChinPins[3][2] = {{68,38},{67,37},{66,36}};
// Lower contour to lip anchors, in the 2.4.0 V-face shader's update order.
static const uint8_t PGVFacePins[4][2] = {{69,39},{65,35},{70,26},{64,34}};
// Origin and radius neighbour; all six directions point toward landmark 29.
static const uint8_t PGJawPins[6][2] = {{72,71},{62,63},{71,70},{63,64},{70,71},{64,63}};

@interface PGFaceFrame ()
@property (nonatomic, copy, readwrite) NSArray<VNFaceObservation *> *faces;
@property (nonatomic, copy, readwrite) NSArray<NSDictionary *> *deformationGeometry;
@property (nonatomic, strong, readwrite) CIImage *skinMask;
@property (nonatomic, strong, readwrite) CIImage *colorMask;
@property (nonatomic, strong, readwrite) CIImage *teethMask;
@property (nonatomic, strong, readwrite) CIImage *eyeMask;
@property (nonatomic, strong, readwrite) CIImage *image;
@property (nonatomic, strong, readwrite) CIImage *overlayImage;
@end
@implementation PGFaceFrame
@end

// All geometry in stored records is normalized to the full source image, with
// Y increasing upward. Pixel size, render scale and tile order are not persisted.
static NSString *PGTimeKey(CMTime time) {
    if (!CMTIME_IS_NUMERIC(time) || time.timescale <= 0) return nil;
    int64_t a = time.value, b = time.timescale;
    // Unsigned magnitude avoids overflow for the minimum signed integer.
    uint64_t u = a < 0 ? (uint64_t)(-(a + 1)) + 1 : (uint64_t)a;
    uint64_t v = (uint64_t)b;
    while (v) { uint64_t r = u % v; u = v; v = r; }
    int64_t divisor = (int64_t)(u ?: 1);
    return [NSString stringWithFormat:@"%lld/%lld/%lld", (long long)(a / divisor),
            (long long)(b / divisor), (long long)time.epoch];
}

static float PGClamp(float value, float low, float high) {
    return isfinite(value) ? fminf(high, fmaxf(low, value)) : 0;
}
static NSArray *PGRectArray(CGRect rect) {
    return @[@(rect.origin.x), @(rect.origin.y), @(rect.size.width), @(rect.size.height)];
}
static CGRect PGArrayRect(NSArray *array) {
    if (![array isKindOfClass:NSArray.class] || array.count != 4) return CGRectZero;
    for (id value in array) if (![value isKindOfClass:NSNumber.class] || !isfinite([value doubleValue])) return CGRectZero;
    return CGRectMake([array[0] doubleValue], [array[1] doubleValue], [array[2] doubleValue], [array[3] doubleValue]);
}
static BOOL PGValidRect(CGRect rect) {
    return rect.size.width > 0.001 && rect.size.height > 0.001 &&
        rect.origin.x >= -0.1 && rect.origin.y >= -0.1 && CGRectGetMaxX(rect) <= 1.1 && CGRectGetMaxY(rect) <= 1.1;
}
static CGPoint PGCenter(CGRect rect) { return CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect)); }
static NSArray *PGRegion(VNFaceLandmarkRegion2D *region, CGRect box) {
    if (!region || region.pointCount == 0) return @[];
    NSMutableArray *points = [NSMutableArray arrayWithCapacity:region.pointCount];
    const CGPoint *p = region.normalizedPoints;
    if (!p) return @[];
    for (NSUInteger i = 0; i < MIN(region.pointCount, 256); i++) {
        if (isfinite(p[i].x) && isfinite(p[i].y)) {
            [points addObject:@[@(box.origin.x + p[i].x * box.size.width),
                                @(box.origin.y + p[i].y * box.size.height)]];
        }
    }
    return points;
}
// This optional field has a fixed topology. Never remove an invalid point and
// shift the remaining indices: the local pins refer to exact Vision 76 indices.
static NSArray *PGSanitizedPoints76(id value) {
    if (![value isKindOfClass:NSArray.class] || [value count] != 76) return nil;
    NSMutableArray *points = [NSMutableArray arrayWithCapacity:76];
    for (id point in value) {
        if (![point isKindOfClass:NSArray.class] || [point count] != 2) return nil;
        for (id coordinate in point) {
            if (![coordinate isKindOfClass:NSNumber.class] || !isfinite([coordinate doubleValue]) || fabs([coordinate doubleValue]) > 2) return nil;
        }
        [points addObject:[point copy]];
    }
    return [points copy];
}
static NSArray *PGFullPoints76(VNFaceLandmarkRegion2D *region, CGRect box) {
    if (region.pointCount < 76 || !region.normalizedPoints) return nil;
    const CGPoint *raw = region.normalizedPoints;
    NSMutableArray *points = [NSMutableArray arrayWithCapacity:76];
    for (NSUInteger i=0; i<76; i++) {
        if (!isfinite(raw[i].x) || !isfinite(raw[i].y)) return nil;
        [points addObject:@[@(box.origin.x+raw[i].x*box.size.width),
                            @(box.origin.y+raw[i].y*box.size.height)]];
    }
    return PGSanitizedPoints76(points);
}
static NSDictionary *PGGeometry(VNFaceObservation *observation) {
    CGRect box = observation.boundingBox;
    VNFaceLandmarks2D *lm = observation.landmarks;
    NSMutableDictionary *geometry = [@{@"box": PGRectArray(box),
             @"leftEye": PGRegion(lm.leftEye, box), @"rightEye": PGRegion(lm.rightEye, box),
             @"leftBrow": PGRegion(lm.leftEyebrow, box), @"rightBrow": PGRegion(lm.rightEyebrow, box),
             @"nose": PGRegion(lm.nose, box), @"lips": PGRegion(lm.outerLips, box),
             @"mouth": PGRegion(lm.innerLips, box), @"contour": PGRegion(lm.faceContour, box)} mutableCopy];
    NSArray *points = PGFullPoints76(lm.allPoints, box);
    if (points) geometry[@"points76"] = points;
    geometry[@"landmarkConfidence"] = @(lm ? lm.confidence : 0);
    return [geometry copy];
}
static NSDictionary *PGSanitizedGeometry(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return nil;
    CGRect box = PGArrayRect(value[@"box"]);
    if (!PGValidRect(box)) return nil;
    NSMutableDictionary *result = [NSMutableDictionary dictionaryWithObject:PGRectArray(box) forKey:@"box"];
    for (NSString *name in @[@"leftEye", @"rightEye", @"leftBrow", @"rightBrow", @"nose", @"lips", @"mouth", @"contour"]) {
        id raw = value[name];
        if (![raw isKindOfClass:NSArray.class] || [raw count] > 256) return nil;
        NSMutableArray *points = [NSMutableArray array];
        for (id point in raw) {
            if (![point isKindOfClass:NSArray.class] || [point count] != 2) return nil;
            for (id coordinate in point) if (![coordinate isKindOfClass:NSNumber.class] || !isfinite([coordinate doubleValue]) || fabs([coordinate doubleValue]) > 2) return nil;
            [points addObject:[point copy]];
        }
        result[name] = points;
    }
    // Old archives and partially detected faces remain usable by the other
    // controls. Missing or malformed full topology disables the recovered local
    // thin/chin/jaw/short fields without discarding otherwise usable old records.
    NSArray *points76 = PGSanitizedPoints76(value[@"points76"]);
    if (points76) result[@"points76"] = points76;
    if ([value[@"landmarkConfidence"] isKindOfClass:NSNumber.class]) result[@"landmarkConfidence"] = value[@"landmarkConfidence"];
    return [result copy];
}
static CGRect PGRegionBounds(NSDictionary *geometry, NSString *name, CGRect fallback) {
    NSArray *points = geometry[name];
    if (points.count == 0) return fallback;
    CGFloat minX = 2, minY = 2, maxX = -1, maxY = -1;
    for (NSArray *point in points) {
        CGFloat x = [point[0] doubleValue], y = [point[1] doubleValue];
        minX = MIN(minX, x); minY = MIN(minY, y); maxX = MAX(maxX, x); maxY = MAX(maxY, y);
    }
    return CGRectMake(minX, minY, MAX(0.001, maxX - minX), MAX(0.001, maxY - minY));
}
static CGRect PGInFace(CGRect face, CGFloat x, CGFloat y, CGFloat w, CGFloat h) {
    return CGRectMake(face.origin.x + x * face.size.width, face.origin.y + y * face.size.height,
                      w * face.size.width, h * face.size.height);
}
static CGRect PGToPixels(CGRect normalized, CGRect extent) {
    return CGRectMake(extent.origin.x + normalized.origin.x * extent.size.width,
                      extent.origin.y + normalized.origin.y * extent.size.height,
                      normalized.size.width * extent.size.width, normalized.size.height * extent.size.height);
}
static CIVector *PGVector(CGPoint point) { return [CIVector vectorWithX:point.x Y:point.y]; }
static CIImage *PGBlack(CGRect extent) {
    return [[CIImage imageWithColor:[CIColor colorWithRed:0 green:0 blue:0 alpha:1]] imageByCroppingToRect:extent];
}
static CIImage *PGTransparent(CGRect extent) {
    return [[CIImage imageWithColor:[CIColor colorWithRed:0 green:0 blue:0 alpha:0]] imageByCroppingToRect:extent];
}
static CIImage *PGMaximum(CIImage *a, CIImage *b) {
    return [a imageByApplyingFilter:@"CIMaximumCompositing" withInputParameters:@{kCIInputBackgroundImageKey:b}];
}

static CMTime PGRecordTime(NSDictionary *record) {
    return CMTimeMakeWithEpoch([record[@"value"] longLongValue], [record[@"scale"] intValue], [record[@"epoch"] longLongValue]);
}
static double PGSeedDistance(NSDictionary *record, PGBeautySettings settings) {
    return hypot([record[@"seedX"] doubleValue]-settings.selectionX, [record[@"seedY"] doubleValue]-settings.selectionY);
}
static NSArray<NSString *> *PGGeometryRegions(void) {
    return @[@"leftEye",@"rightEye",@"leftBrow",@"rightBrow",@"nose",@"lips",@"mouth",@"contour"];
}
static CGPoint PGRemapPoint(NSArray *point, CGRect old, CGRect current) {
    return CGPointMake(current.origin.x+([point[0] doubleValue]-old.origin.x)*current.size.width/old.size.width,
                       current.origin.y+([point[1] doubleValue]-old.origin.y)*current.size.height/old.size.height);
}
// 2.4.0's default pin path accepts good points without a temporal blend.
// Geometry remains in our existing bottom-left coordinate convention; distances,
// dot products and the two-axis sign test are invariant to the reference's Y flip.
static CGPoint PGPoint(NSArray *p) { return CGPointMake([p[0] doubleValue], [p[1] doubleValue]); }
static CGPoint PGMeanPoints(NSArray *points, NSUInteger first, NSUInteger count) {
    if (!count || first+count>points.count) return CGPointMake(NAN,NAN);
    CGPoint sum=CGPointZero;
    for(NSUInteger i=first;i<first+count;i++) {CGPoint p=PGPoint(points[i]);sum.x+=p.x;sum.y+=p.y;}
    return CGPointMake(sum.x/count,sum.y/count);
}
static CGPoint PGLocalPoint(CGPoint p,CGRect box) {
    return CGPointMake((p.x-box.origin.x)/box.size.width,(p.y-box.origin.y)/box.size.height);
}
static NSString *PGGeometryQualityReason(NSDictionary *g) {
    CGRect box=PGArrayRect(g[@"box"]);NSArray *points=PGSanitizedPoints76(g[@"points76"]),*contour=g[@"contour"];
    if(!PGValidRect(box)||points.count!=76)return @"incomplete76";
    if(contour.count<=10)return @"contour";
    double confidence=g[@"landmarkConfidence"]?[g[@"landmarkConfidence"] doubleValue]:1;
    if(!isfinite(confidence)||confidence<.55)return @"confidence";
    for(NSArray *point in points) {
        CGPoint p=PGLocalPoint(PGPoint(point),box);
        if(!isfinite(p.x)||!isfinite(p.y)||p.x<-.35||p.x>1.35||p.y<-.35||p.y>1.35)return @"localBounds";
    }
    CGPoint centers[5];NSArray *names=@[@"leftEye",@"rightEye",@"nose",@"lips"];
    for(NSUInteger i=0;i<4;i++) {
        NSArray *region=g[names[i]];if(!region.count)return @"missingRegion";
        centers[i]=PGLocalPoint(PGMeanPoints(region,0,region.count),box);
        if(!isfinite(centers[i].x)||!isfinite(centers[i].y))return @"regionBounds";
    }
    centers[4]=PGLocalPoint(PGMeanPoints(contour,contour.count/2-1,3),box);
    CGPoint left=centers[0],right=centers[1],nose=centers[2],mouth=centers[3],chin=centers[4];
    double dx=right.x-left.x,dy=right.y-left.y,length=hypot(dx,dy);
    if(!isfinite(length)||length<.1)return @"eyeDistance";
    dx/=length;dy/=length;
    CGPoint eye=CGPointMake((left.x+right.x)*.5,(left.y+right.y)*.5);
    double vx=-dy,vy=dx;
    if(vx*(mouth.x-eye.x)+vy*(mouth.y-eye.y)<0){vx=-vx;vy=-vy;}
    double mouthProjection=vx*(mouth.x-eye.x)+vy*(mouth.y-eye.y);
    double noseProjection=vx*(nose.x-eye.x)+vy*(nose.y-eye.y);
    double chinProjection=vx*(chin.x-eye.x)+vy*(chin.y-eye.y);
    double lateral=dx*(chin.x-eye.x)+dy*(chin.y-eye.y);
    if(!isfinite(chinProjection)||mouthProjection<.08||chinProjection-mouthProjection<.06||chinProjection<.2)return @"anatomy";
    if(noseProjection<-.12||noseProjection>mouthProjection+.16||fabs(lateral)>length*.5+.3)return @"anatomy";
    return @"";
}
static double PGBoxIoU(CGRect a,CGRect b) {
    CGRect intersection=CGRectIntersection(a,b);double area=CGRectIsNull(intersection)?0:intersection.size.width*intersection.size.height;
    double total=a.size.width*a.size.height+b.size.width*b.size.height-area;return total>0?area/total:0;
}
static BOOL PGCompatibleBoxes(CGRect a,CGRect b) {
    if(!PGValidRect(a)||!PGValidRect(b))return NO;
    CGPoint x=PGCenter(a),y=PGCenter(b);
    return hypot(x.x-y.x,x.y-y.y)<=MAX(.04,.82*MAX(b.size.width,b.size.height))||PGBoxIoU(a,b)>=.08;
}
static CGPoint PGChinAxis(NSDictionary *g) {
    NSArray *p=g[@"points76"];if(p.count!=76)return CGPointMake(NAN,NAN);
    CGPoint a=PGPoint(p[66]),b=PGPoint(p[67]),c=PGPoint(p[68]),center=PGCenter(PGArrayRect(g[@"box"]));
    return CGPointMake((a.x+1.65*b.x+c.x)/3.65-center.x,(a.y+1.65*b.y+c.y)/3.65-center.y);
}
static BOOL PGGeometryAxisFlip(NSDictionary *current,NSDictionary *previous) {
    CGRect a=PGArrayRect(current[@"box"]),b=PGArrayRect(previous[@"box"]);
    if(!PGCompatibleBoxes(a,b))return NO;
    CGPoint x=PGChinAxis(current),y=PGChinAxis(previous);double lx=hypot(x.x,x.y),ly=hypot(y.x,y.y);
    double threshold=MAX(.003,.055*MIN(a.size.height,b.size.height));
    if(!isfinite(lx)||!isfinite(ly)||lx<.0008||ly<.0008||lx<threshold||ly<threshold)return NO;
    if(x.y*y.y>=0||fabs(x.y)<.35*threshold||fabs(y.y)<.35*threshold)return NO;
    double cosine=fmax(-1,fmin(1,(x.x*y.x+x.y*y.y)/(lx*ly)));
    return cosine<=-.18||fabs(x.y-y.y)>=threshold;
}
static NSDictionary *PGRemappedGeometry(NSDictionary *previous,CGRect box) {
    CGRect old=PGArrayRect(previous[@"box"]);if(!PGValidRect(old)||!PGValidRect(box))return previous;
    NSMutableDictionary *result=[previous mutableCopy];result[@"box"]=PGRectArray(box);
    NSMutableArray *names=[PGGeometryRegions() mutableCopy];[names addObject:@"points76"];
    for(NSString *name in names) {
        NSMutableArray *points=[NSMutableArray new];
        for(NSArray *point in previous[name]) {CGPoint p=PGRemapPoint(point,old,box);[points addObject:@[@(p.x),@(p.y)]];}
        if(points.count)result[name]=points;
    }
    return result;
}
// Reference hold validation uses the 76 points plus the box center. Keep our
// persisted topology at 76 and reconstruct the center rather than changing archives.
static BOOL PGValidHeldGeometry(NSDictionary *g) {
    CGRect box=PGArrayRect(g[@"box"]);NSArray *p=PGSanitizedPoints76(g[@"points76"]);
    if(!PGValidRect(box)||p.count!=76)return NO;
    CGRect expanded=CGRectInset(box,-.4*box.size.width,-.4*box.size.height);
    double minX=CGRectGetMidX(box),maxX=minX,minY=CGRectGetMidY(box),maxY=minY;
    double contourMinX=DBL_MAX,contourMaxX=-DBL_MAX,contourMinY=DBL_MAX,contourMaxY=-DBL_MAX,left=0,mid=0,right=0;
    for(NSUInteger i=0;i<76;i++) {
        CGPoint point=PGPoint(p[i]);
        if(point.x<-.25||point.x>1.25||point.y<-.25||point.y>1.25)return NO;
        minX=MIN(minX,point.x);maxX=MAX(maxX,point.x);minY=MIN(minY,point.y);maxY=MAX(maxY,point.y);
        if(i<59)continue;
        if(!CGRectContainsPoint(expanded,point))return NO;
        contourMinX=MIN(contourMinX,point.x);contourMaxX=MAX(contourMaxX,point.x);
        contourMinY=MIN(contourMinY,point.y);contourMaxY=MAX(contourMaxY,point.y);
        if(i<66)left+=point.x;else if(i<=68)mid+=point.x;else right+=point.x;
    }
    double w=box.size.width,h=box.size.height,cw=contourMaxX-contourMinX,ch=contourMaxY-contourMinY;
    left/=7;mid/=3;right/=7;
    return maxX-minX>=.25*w&&maxY-minY>=.25*h&&cw>=.2*w&&ch>=.04*h&&cw<=1.85*w&&ch<=1.85*h&&
        fabs(right-left)>=.12*w&&mid>=MIN(left,right)-.35*w&&mid<=MAX(left,right)+.35*w;
}
static NSString *PGGeometryTransitionReason(NSDictionary *current,NSDictionary *previous) {
    CGRect box=PGArrayRect(current[@"box"]),old=PGArrayRect(previous[@"box"]);
    if(!PGCompatibleBoxes(box,old))return @"";
    if(PGGeometryAxisFlip(current,previous))return @"axisFlip";
    NSArray *a=current[@"points76"],*b=previous[@"points76"];
    if(a.count!=76||b.count!=76)return @"";
    NSMutableArray *distances=[NSMutableArray new];double scale=MAX(box.size.width,box.size.height);
    for(NSUInteger i=0;i<76;i++) {
        CGPoint p=PGRemapPoint(b[i],old,box),q=PGPoint(a[i]);
        [distances addObject:@(hypot(p.x-q.x,p.y-q.y)/scale)];
    }
    [distances sortUsingSelector:@selector(compare:)];
    return [distances[38] doubleValue]>.30||[distances[67] doubleValue]>.58?@"pointJump":@"";
}
static CIImage *PGPreparedVisionImage(CIImage *image,CGFloat limit) {
    CGRect e=image.extent;
    CIImage *prepared=[image imageByApplyingTransform:CGAffineTransformMakeTranslation(-e.origin.x,-e.origin.y)];
    CGFloat scale=MIN(1,limit/MAX(e.size.width,e.size.height));
    if(scale<1)prepared=[prepared imageByApplyingTransform:CGAffineTransformMakeScale(scale,scale)];
    return [prepared imageByCroppingToRect:CGRectMake(0,0,MAX(1,floor(e.size.width*scale)),MAX(1,floor(e.size.height*scale)))];
}

@interface PGRealtimeFaceTracker : NSObject {
    NSLock *_mutex;
    NSMutableArray<NSDictionary *> *_entries;
    NSUInteger _estimatedBytes;
    NSDictionary *_liveReference;
    VNSequenceRequestHandler *_sequence;
    VNTrackObjectRequest *_objectRequest;
    CGRect _objectBox;
    CMTime _objectTime;
    BOOL _objectValid;
}
- (NSDictionary *)resultForGeometry:(NSArray<NSDictionary *> *)raw settings:(PGBeautySettings)settings time:(CMTime)time extent:(CGRect)extent;
- (NSDictionary *)resultForGeometry:(NSArray<NSDictionary *> *)raw settings:(PGBeautySettings)settings time:(CMTime)time extent:(CGRect)extent image:(CIImage *)image;
- (CGRect)trackedBoxForImage:(CIImage *)image time:(CMTime)time seedBox:(CGRect)seed;
- (void)reset;
- (void)removeCachedResult:(NSDictionary *)result;
- (NSDictionary *)cacheStatistics;
@end
@implementation PGRealtimeFaceTracker
- (instancetype)init {if((self=[super init])){_mutex=[NSLock new];_entries=[NSMutableArray new];_objectTime=kCMTimeInvalid;}return self;}
- (void)resetObjectTracker { _sequence=[VNSequenceRequestHandler new];_objectRequest=nil;_objectBox=CGRectNull;_objectTime=kCMTimeInvalid;_objectValid=NO; }
- (void)reset {[_mutex lock];[_entries removeAllObjects];_estimatedBytes=0;_liveReference=nil;[self resetObjectTracker];[_mutex unlock];}
- (void)removeCachedResult:(NSDictionary *)result {
    [_mutex lock];
    for(NSInteger i=(NSInteger)_entries.count-1;i>=0;i--) {
        NSDictionary *entry=_entries[(NSUInteger)i];
        if([entry[@"context"] isEqual:result[@"context"]]&&[entry[@"scope"] isEqual:result[@"scope"]]&&[entry[@"key"] isEqual:result[@"key"]]) {
            _estimatedBytes-=[entry[@"bytes"] unsignedIntegerValue];[_entries removeObjectAtIndex:(NSUInteger)i];
        }
    }
    [_mutex unlock];
}
- (NSDictionary *)cacheStatistics {[_mutex lock];NSDictionary *stats=@{@"frames":@(_entries.count),@"estimatedBytes":@(_estimatedBytes)};[_mutex unlock];return stats;}
- (CGRect)trackedBoxForImage:(CIImage *)image time:(CMTime)time seedBox:(CGRect)seed {
    if(!image||!PGTimeKey(time)){[self resetObjectTracker];return CGRectNull;}
    BOOL hasSeed=PGValidRect(seed),hasBox=PGValidRect(_objectBox);
    double dt=PGTimeKey(_objectTime)?CMTimeGetSeconds(CMTimeSubtract(time,_objectTime)):NAN;
    BOOL backward=isfinite(dt)&&dt<0;
    if(hasBox&&_objectValid&&isfinite(dt)&&fabs(dt)<=.0005)return _objectBox;
    if(!_sequence)_sequence=[VNSequenceRequestHandler new];
    if(!_objectRequest||!_objectValid||backward||(isfinite(dt)&&dt>.2)) {
        if(!backward&&hasBox&&!_objectValid&&isfinite(dt)&&dt<=.45&&(!hasSeed||!PGCompatibleBoxes(seed,_objectBox)))return _objectBox;
        if(!hasSeed){_objectValid=NO;_objectRequest=nil;_sequence=[VNSequenceRequestHandler new];return CGRectNull;}
        _sequence=[VNSequenceRequestHandler new];
        _objectRequest=[[VNTrackObjectRequest alloc] initWithDetectedObjectObservation:[VNDetectedObjectObservation observationWithBoundingBox:seed]];
        NSUInteger revision=VNTrackObjectRequest.defaultRevision;
        if(![VNTrackObjectRequest.supportedRevisions containsIndex:revision])revision=VNTrackObjectRequest.currentRevision;
        if([VNTrackObjectRequest.supportedRevisions containsIndex:revision])_objectRequest.revision=revision;
        _objectRequest.trackingLevel=VNRequestTrackingLevelAccurate;
        _objectBox=seed;_objectTime=time;_objectValid=YES;return seed;
    }
    NSError *error=nil;
    BOOL ok=[_sequence performRequests:@[_objectRequest] onCIImage:PGPreparedVisionImage(image,960) orientation:kCGImagePropertyOrientationUp error:&error];
    VNDetectedObjectObservation *result=ok?_objectRequest.results.firstObject:nil;
    CGRect box=result.boundingBox;
    if(result&&result.confidence>=.22&&PGValidRect(box)) {
        _objectRequest.inputObservation=result;_objectRequest.trackingLevel=VNRequestTrackingLevelAccurate;
        _objectBox=box;_objectTime=time;_objectValid=YES;return box;
    }
    _objectRequest=nil;_sequence=[VNSequenceRequestHandler new];_objectValid=NO;
    return hasBox?_objectBox:(hasSeed?seed:CGRectNull);
}
- (NSDictionary *)resultForGeometry:(NSArray<NSDictionary *> *)raw settings:(PGBeautySettings)s time:(CMTime)time extent:(CGRect)extent {
    return [self resultForGeometry:raw settings:s time:time extent:extent image:nil];
}
- (NSDictionary *)resultForGeometry:(NSArray<NSDictionary *> *)input settings:(PGBeautySettings)s time:(CMTime)time extent:(CGRect)extent image:(CIImage *)image {
    NSMutableArray *valid=[NSMutableArray new];
    for(id item in input) {NSDictionary *g=PGSanitizedGeometry(item);if(g&&valid.count<16)[valid addObject:g];}
    NSArray *raw=[valid copy];NSUInteger mode=s.fastMultiFace?2:(s.singleFace?1:0);
    NSString *key=PGTimeKey(time);
    NSString *context=[NSString stringWithFormat:@"%lu/%u/%lld/%.17g/%.17g/%.17g/%.17g/%.9g",(unsigned long)mode,s.targetIndex,
        (long long)time.epoch,extent.origin.x,extent.origin.y,extent.size.width,extent.size.height,s.faceJumpGuardRange];
    [_mutex lock];
    BOOL contextChanged=![_liveReference[@"context"] isEqual:context];
    NSDictionary *reference=contextChanged?nil:_liveReference;
    if(contextChanged) {
        // Fast-multi bypasses pin selection. Returning to a prior mode can use
        // its accepted shape, but must never continue another mode's VN sequence.
        for(NSDictionary *record in _entries)if([record[@"context"] isEqual:context]&&CMTimeCompare(PGRecordTime(record),time)<=0&&
            (!reference||CMTimeCompare(PGRecordTime(record),PGRecordTime(reference))>0))reference=record;
    }
    double seedX=PGClamp(s.selectionX,0,1),seedY=PGClamp(s.selectionY,0,1);
    NSString *scope=mode==1?[NSString stringWithFormat:@"%.9g/%.9g",seedX,seedY]:@"automatic";
    if(mode==1&&reference&&PGSeedDistance(reference,s)<=.01){scope=reference[@"scope"];seedX=[reference[@"seedX"] doubleValue];seedY=[reference[@"seedY"] doubleValue];}
    if(reference&&![reference[@"scope"] isEqual:scope])reference=nil;
    // Exact frame reuse is independent of a second Vision result or render count.
    // A new uncached rewind clears live geometry and the stateful sequence handler.
    NSDictionary *cached=nil;
    if(key)for(NSDictionary *record in _entries)if([record[@"context"] isEqual:context]&&[record[@"scope"] isEqual:scope]&&[record[@"key"] isEqual:key]){cached=record;break;}
    BOOL backward=reference&&CMTimeCompare(time,PGRecordTime(reference))<0;
    if(contextChanged||!reference||backward)[self resetObjectTracker];
    if(cached){_liveReference=cached;[_mutex unlock];return cached;}
    if(backward||!key)reference=nil;
    NSDictionary *previous=reference[@"accepted"];
    CGRect previousBox=PGArrayRect(previous[@"box"]);
    CGRect tracked=mode==2?CGRectNull:[self trackedBoxForImage:image time:time seedBox:CGRectNull];
    CGRect selectionBox=PGValidRect(tracked)?tracked:previousBox;
    NSInteger index=-1;double best=-DBL_MAX;
    if(mode!=2)for(NSUInteger i=0;i<raw.count;i++) {
        CGRect box=PGArrayRect(raw[i][@"box"]);CGPoint center=PGCenter(box);double score;
        if(PGValidRect(previousBox)) {
            CGFloat factor=PGClamp(s.faceJumpGuardRange,1,4);
            CGRect guard=CGRectIntersection(CGRectMake(0,0,1,1),CGRectInset(previousBox,-previousBox.size.width*(factor-1)*.5,-previousBox.size.height*(factor-1)*.5));
            if(!CGRectContainsPoint(guard,center))continue;
        }
        if(PGValidRect(selectionBox)) {
            CGPoint p=PGCenter(selectionBox);double distance=hypot(center.x-p.x,center.y-p.y);
            score=8*PGBoxIoU(box,selectionBox)+3.2*(1-MIN(1,distance/.32))-.35*distance;
            if(CGRectContainsPoint(box,p))score+=1.2;
        }else if(mode==1)score=-hypot(center.x-seedX,center.y-seedY);
        else {CGRect clipped=CGRectIntersection(box,CGRectMake(0,0,1,1));CGPoint p=PGCenter(clipped);
            score=1.8*fmin(1,clipped.size.width*clipped.size.height)+1.1*(1-fmin(1,hypot(p.x-.5,p.y-.5)/.72));}
        if(index<0||score>best){index=(NSInteger)i;best=score;}
    }
    NSDictionary *current=index>=0?raw[(NSUInteger)index]:nil;
    if(mode!=2&&!PGValidRect(tracked)&&current)tracked=[self trackedBoxForImage:image time:time seedBox:PGArrayRect(current[@"box"])];
    NSString *reason=current?PGGeometryQualityReason(current):@"missingFace";
    if(!reason.length&&previous)reason=PGGeometryTransitionReason(current,previous);
    BOOL held=NO;NSArray *output=@[];NSDictionary *accepted=previous;
    if(mode==2){output=raw;accepted=nil;reason=@"fastMulti";}
    else if(!reason.length){output=@[current];accepted=current;}
    else if(previous) {
        CGRect box=PGValidRect(tracked)?tracked:(current?PGArrayRect(current[@"box"]):previousBox);
        NSDictionary *mapped=PGRemappedGeometry(previous,box);
        output=@[PGValidHeldGeometry(mapped)?mapped:previous];held=YES;
    }
    NSMutableDictionary *record=[@{@"context":context,@"scope":scope,@"key":key?:@"invalid",@"value":@(time.value),@"scale":@(time.timescale),@"epoch":@(time.epoch),
        @"seedX":@(seedX),@"seedY":@(seedY),@"raw":raw,@"output":output,@"index":@(index),@"held":@(held),@"reason":reason,
        @"trackedBox":PGValidRect(tracked)?PGRectArray(tracked):@[],@"referenceKey":reference[@"key"]?:@""} mutableCopy];
    if(accepted)record[@"accepted"]=accepted;
    // Keep the accepted time distinct from the output/held time for diagnostics.
    record[@"acceptedKey"]=(!reason.length?key:reference[@"acceptedKey"])?:@"";
    if(key) {
        NSData *serialized=[NSPropertyListSerialization dataWithPropertyList:record format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
        NSUInteger bytes=serialized.length+512;record[@"bytes"]=@(bytes);
        if(bytes<=16*1024*1024){[_entries addObject:[record copy]];_estimatedBytes+=bytes;}
        while(_entries.count>1200||_estimatedBytes>16*1024*1024){_estimatedBytes-=[_entries.firstObject[@"bytes"] unsignedIntegerValue];[_entries removeObjectAtIndex:0];}
        _liveReference=[record copy];
    }else{_liveReference=nil;[self resetObjectTracker];}
    [_mutex unlock];return [record copy];
}
@end

@interface PGFaceProcessor () {
    NSLock *_lock;
    NSMutableArray<NSMutableDictionary<NSString *, NSDictionary *> *> *_targets;
    CIWarpKernel *_warp;
    CIColorKernel *_ellipse;
    CIColorKernel *_subtract;
    CIColorKernel *_box;
    PGRealtimeFaceTracker *_realtime;
    NSMutableArray<NSDictionary *> *_observationCache;
    CIContext *_visionContext;
}
@end

@implementation PGFaceProcessor

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = [[NSLock alloc] init];
        _realtime = [PGRealtimeFaceTracker new];
        _observationCache = [NSMutableArray new];
        _visionContext = [CIContext contextWithOptions:@{kCIContextCacheIntermediates:@NO}];
        _targets = [NSMutableArray arrayWithObjects:[NSMutableDictionary dictionary], [NSMutableDictionary dictionary], [NSMutableDictionary dictionary], nil];
        // Thin/V/chin/jaw/short reconstruct recovered local coordinate math.
        // Narrow/cheek/small-head retain this project's analytic approximation.
        // Recovered V -> jaw -> chin -> short order follows the reference. Other
        // analytic body controls still precede V, so the full combined chain
        // with narrow/cheek/small-head/eyes is not claimed reference-equivalent.
        // Each pin changes the sampling coordinate, with only one image resample.
        NSMutableString *source = [NSMutableString stringWithString:
        @"vec2 pgThinPin(vec2 q, vec4 control, float ratio) {"
        " vec2 direction=control.zw-control.xy; float radius=length(direction);"
        " if(radius<=0.0001) return q;"
        " float weight=clamp(1.0-length(q-control.xy)/radius,0.0,1.0);"
        " return clamp(q-direction*ratio*weight,vec2(0.0),vec2(1.0)); }"
        " vec2 pgJawPin(vec2 q, vec4 edge, vec2 anchor, float ratio) {"
        " float radius=length(edge.xy-edge.zw); if(radius<=0.0001) return q;"
        " float weight=clamp(1.0-length(q-edge.xy)/radius,0.0,1.0);"
        " return clamp(q-(anchor-edge.xy)*ratio*weight,vec2(0.0),vec2(1.0)); }"
        " vec2 pgShortEdge(vec2 q, vec2 a, vec2 b) {"
        " vec2 d=b-a; float squared=dot(d,d);"
        " float t=0.0; if(squared>0.000001) t=clamp(dot(q-a,d)/squared,0.0,1.0);"
        " float distance=length(q-(a+t*d)); float crossing=0.0;"
        " if((a.y>q.y && b.y<=q.y) || (b.y>q.y && a.y<=q.y)) {"
        " float dy=b.y-a.y; if(abs(dy)<=0.000001) dy=dy<0.0?-0.000001:0.000001;"
        " if(q.x<a.x+(b.x-a.x)*(q.y-a.y)/dy) crossing=1.0; }"
        " return vec2(distance,crossing); }"
        " kernel vec2 pgFaceWarp(vec2 c, vec2 size, vec2 le, vec2 re, vec2 er, float thinRatio, float bigEye, float shortRatio, float narrow, float chinRatio, float vRatio, float jawRatio, float cheek, float smallHead, float headRange, vec2 imageOrigin, vec2 imageSize"];
        for (NSUInteger i=0; i<17; i++) [source appendFormat:@", vec4 pin%lu",(unsigned long)i];
        for (NSUInteger i=0; i<4; i++) [source appendFormat:@", vec4 vPin%lu",(unsigned long)i];
        for (NSUInteger i=0; i<3; i++) [source appendFormat:@", vec4 chinPin%lu",(unsigned long)i];
        [source appendString:@", vec2 jawAnchor, vec2 shortAxis"];
        for (NSUInteger i=0; i<6; i++) [source appendFormat:@", vec4 jawPin%lu",(unsigned long)i];
        for (NSUInteger i=0; i<11; i++) [source appendFormat:@", vec2 shortPoint%lu",(unsigned long)i];
        [source appendString:@") { vec2 p=destCoord();"
        " if(thinRatio>0.000001) { vec2 q=(p-imageOrigin)/imageSize; q.y=1.0-q.y;"];
        for (NSUInteger i=0; i<17; i++) [source appendFormat:@" q=pgThinPin(q,pin%lu,thinRatio);",(unsigned long)i];
        [source appendString:@" q.y=1.0-q.y; p=imageOrigin+q*imageSize; }"
        " vec2 n = (p-c)/size;"
        " float body = 1.0-smoothstep(0.38,0.76,length(n*vec2(1.0,0.82)));"
        " float sides = smoothstep(0.08,0.32,abs(n.x));"
        " float ch=(n.y-0.02)/0.19; float cheekBand = exp(-ch*ch)*body;"
        " float head = 1.0-smoothstep(0.38,0.75+0.32*headRange,length(n*vec2(0.9,0.65)));"
        " p += (p-c)*smallHead*0.18*head;"
        " p.x += size.x*n.x*(narrow*0.30*body + cheek*0.18*cheekBand)*sides;"
        " if(vRatio>0.000001) { vec2 q=(p-imageOrigin)/imageSize; q.y=1.0-q.y;"];
        for (NSUInteger i=0; i<4; i++) [source appendFormat:@" q=pgThinPin(q,vPin%lu,vRatio);",(unsigned long)i];
        [source appendString:@" q.y=1.0-q.y; p=imageOrigin+q*imageSize; }"
        " if(abs(jawRatio)>0.000001) { vec2 q=(p-imageOrigin)/imageSize; q.y=1.0-q.y;"];
        for (NSUInteger i=0; i<6; i++) [source appendFormat:@" q=pgJawPin(q,jawPin%lu,jawAnchor,jawRatio);",(unsigned long)i];
        [source appendString:@" q.y=1.0-q.y; p=imageOrigin+q*imageSize; }"
        " if(abs(chinRatio)>0.000001) { vec2 q=(p-imageOrigin)/imageSize; q.y=1.0-q.y;"];
        for (NSUInteger i=0; i<3; i++) [source appendFormat:@" q=pgThinPin(q,chinPin%lu,chinRatio);",(unsigned long)i];
        [source appendString:@" q.y=1.0-q.y; p=imageOrigin+q*imageSize; }"
        " if(abs(shortRatio)>0.000001 && length(shortAxis)>0.0001) {"
        " vec2 q=(p-imageOrigin)/imageSize; q.y=1.0-q.y;"
        " float nearest=10.0; float crossings=0.0;"];
        for (NSUInteger i=0; i<11; i++) [source appendFormat:@" { vec2 edge=pgShortEdge(q,shortPoint%lu,shortPoint%lu); nearest=min(nearest,edge.x); crossings+=edge.y; }",(unsigned long)i,(unsigned long)((i+1)%11)];
        [source appendString:@" float weight=mod(crossings,2.0)>0.5?1.0:clamp(1.0-nearest/length(shortAxis),0.0,1.0);"
        " q=clamp(q-shortAxis*shortRatio*weight,vec2(0.0),vec2(1.0));"
        " q.y=1.0-q.y; p=imageOrigin+q*imageSize; }"
        " vec2 dl=p-le; float lr=er.x;"
        " if(lr>0.0001) { float wl=clamp(1.0-dot(dl,dl)/(lr*lr),0.0,1.0); p=le+dl*(1.0-bigEye*wl); }"
        " vec2 dr=p-re; float rr=er.y;"
        " if(rr>0.0001) { float wr=clamp(1.0-dot(dr,dr)/(rr*rr),0.0,1.0); p=re+dr*(1.0-bigEye*wr); } return p; }"];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        _warp = [CIWarpKernel kernelWithString:source];
        _ellipse = [CIColorKernel kernelWithString:@"kernel vec4 pgEllipse(vec2 c, vec2 r, float inner) { float v=1.0-smoothstep(inner,1.0,length((destCoord()-c)/max(r,vec2(0.001)))); return vec4(v,v,v,1.0); }"];
        _subtract = [CIColorKernel kernelWithString:@"kernel vec4 pgSubtract(__sample a, __sample b) { float v=max(0.0,a.r-b.r); return vec4(v,v,v,1.0); }"];
        _box = [CIColorKernel kernelWithString:@"kernel vec4 pgBox(vec4 b, float width, vec4 color) { vec2 p=destCoord(); float inside=step(b.x,p.x)*step(b.y,p.y)*step(p.x,b.z)*step(p.y,b.w); float edge=min(min(abs(p.x-b.x),abs(p.x-b.z)),min(abs(p.y-b.y),abs(p.y-b.w))); float a=inside*(1.0-smoothstep(width,width+1.0,edge)); return color*a; }"];
#pragma clang diagnostic pop
    }
    return self;
}

- (NSArray<VNFaceObservation *> *)observationsInImage:(CIImage *)image settings:(PGBeautySettings)settings error:(NSError **)error {
    // 2.4.0 defaults to a 960-pixel long edge (its configurable downsample
    // limit), not the former 1280-pixel path. The explicit fast mode keeps its
    // lower-cost detector. Both handlers receive an upright, zero-origin image.
    CIImage *prepared=PGPreparedVisionImage(image,settings.fastMultiFace?720:960);
    VNDetectFaceLandmarksRequest *(^newRequest)(void)=^{
        VNDetectFaceLandmarksRequest *r=[VNDetectFaceLandmarksRequest new];
        r.revision=VNDetectFaceLandmarksRequestRevision3;r.constellation=VNRequestFaceLandmarksConstellation76Points;return r;
    };
    VNDetectFaceLandmarksRequest *request=newRequest();NSError *firstError=nil;
    VNImageRequestHandler *handler=[[VNImageRequestHandler alloc] initWithCIImage:prepared orientation:kCGImagePropertyOrientationUp options:@{}];
    BOOL ok=[handler performRequests:@[request] error:&firstError];
    NSArray<VNFaceObservation *> *faces=ok?(request.results?:@[]):@[];
    NSUInteger count=0;for(VNFaceObservation *face in faces)count=MAX(count,face.landmarks.allPoints.pointCount);
    if(!ok||!faces.count||count<76) {
        // The reference retries a materialized RGBA image, not the same lazy
        // CIImage request. Retain a successful first result if retry finds none.
        CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGImageRef cg=[_visionContext createCGImage:prepared fromRect:prepared.extent format:kCIFormatRGBA8 colorSpace:space];
        CGColorSpaceRelease(space);
        if(cg) {
            VNDetectFaceLandmarksRequest *retry=newRequest();NSError *retryError=nil;
            VNImageRequestHandler *fallback=[[VNImageRequestHandler alloc] initWithCGImage:cg orientation:kCGImagePropertyOrientationUp options:@{}];
            BOOL retried=[fallback performRequests:@[retry] error:&retryError];CGImageRelease(cg);
            if(retried){ok=YES;firstError=nil;if(retry.results.count)faces=retry.results;}
            else if(!ok)firstError=retryError?:firstError;
        }
    }
    if(!ok){if(error)*error=firstError;return nil;}
    return [faces sortedArrayUsingComparator:^NSComparisonResult(VNFaceObservation *a,VNFaceObservation *b) {
        CGRect x=a.boundingBox,y=b.boundingBox;
        if(CGRectGetMidX(x)!=CGRectGetMidX(y))return CGRectGetMidX(x)<CGRectGetMidX(y)?NSOrderedAscending:NSOrderedDescending;
        if(CGRectGetMidY(x)!=CGRectGetMidY(y))return CGRectGetMidY(x)<CGRectGetMidY(y)?NSOrderedAscending:NSOrderedDescending;
        return x.size.width>y.size.width?NSOrderedAscending:NSOrderedDescending;
    }];
}
- (NSArray<VNFaceObservation *> *)cachedObservationsInImage:(CIImage *)image settings:(PGBeautySettings)settings time:(CMTime)time error:(NSError **)error {
    NSString *key=PGTimeKey(time);CGRect e=image.extent;
    NSString *context=[NSString stringWithFormat:@"%u/%.17g/%.17g/%.17g/%.17g",settings.fastMultiFace,e.origin.x,e.origin.y,e.size.width,e.size.height];
    @synchronized(_observationCache) {
        if(key)for(NSDictionary *entry in _observationCache)if([entry[@"key"] isEqual:key]&&[entry[@"context"] isEqual:context])return entry[@"faces"];
        NSArray *faces=[self observationsInImage:image settings:settings error:error];
        // A transient API error is retriable; a successful empty result is a
        // real frame result and is cached, so redraws cannot toggle the effect.
        if(key&&faces){[_observationCache addObject:@{@"key":key,@"context":context,@"faces":faces}];while(_observationCache.count>120)[_observationCache removeObjectAtIndex:0];}
        return faces;
    }
}

- (NSDictionary *)recordForTime:(CMTime)time target:(NSUInteger)target nearest:(BOOL)nearest {
    NSString *key = PGTimeKey(time);
    if (!key || target >= 3) return nil;
    [_lock lock];
    NSDictionary *record = _targets[target][key];
    if (nearest && [record[@"faces"] count] == 0) record = nil;
    if (!record && nearest) {
        // Pick a deterministic analyzed identity, retaining the last valid face
        // across lost detections. Only an explicit reset/reselection reacquires
        // a different identity; render ordering never updates this anchor.
        double distance = DBL_MAX;
        CMTime selectedTime = kCMTimeInvalid;
        for (NSDictionary *candidate in _targets[target].allValues) {
            if ([candidate[@"faces"] count] == 0) continue;
            CMTime stored = CMTimeMakeWithEpoch([candidate[@"value"] longLongValue], [candidate[@"scale"] intValue], [candidate[@"epoch"] longLongValue]);
            if (stored.epoch != time.epoch) continue;
            double delta = fabs(CMTimeGetSeconds(CMTimeSubtract(stored, time)));
            if (delta < distance || (delta == distance && CMTIME_IS_VALID(selectedTime) && CMTimeCompare(stored, selectedTime) < 0)) {
                record = candidate; distance = delta; selectedTime = stored;
            }
        }
    }
    [_lock unlock];
    return record;
}

- (NSArray<NSDictionary *> *)geometryForObservations:(NSArray<VNFaceObservation *> *)observations
                                           settings:(PGBeautySettings)settings previous:(NSDictionary *)previous {
    BOOL selectOne = settings.singleFace || settings.trackingEnabled;
    if (!selectOne) {
        NSMutableArray *all = [NSMutableArray array];
        for (VNFaceObservation *face in observations) if (PGValidRect(face.boundingBox) && all.count < 16) [all addObject:PGGeometry(face)];
        return all;
    }
    CGPoint selection = CGPointMake(PGClamp(settings.selectionX, 0, 1), PGClamp(settings.selectionY, 0, 1));
    NSArray *previousFaces = previous[@"faces"];
    CGRect prior = previousFaces.count ? PGArrayRect(previousFaces.firstObject[@"box"]) : CGRectZero;
    BOOL guard = settings.faceJumpGuardRange > 0 && PGValidRect(prior);
    CGPoint reference = guard ? PGCenter(prior) : selection;
    VNFaceObservation *best = nil;
    double bestScore = DBL_MAX;
    for (VNFaceObservation *face in observations) {
        CGRect box = face.boundingBox;
        if (!PGValidRect(box)) continue;
        CGPoint center = PGCenter(box);
        double dx = (center.x - reference.x), dy = (center.y - reference.y);
        if (guard) {
            double radius = MAX(prior.size.width, prior.size.height) * PGClamp(settings.faceJumpGuardRange, 0.1, 8);
            double ratio = box.size.width / prior.size.width;
            if (hypot(dx, dy) > radius || ratio < 0.4 || ratio > 2.5) continue;
        }
        double score = dx * dx + dy * dy;
        if (!guard && CGRectContainsPoint(box, selection)) score -= 2;
        if (score < bestScore) { best = face; bestScore = score; }
    }
    return best ? @[PGGeometry(best)] : @[];
}

- (BOOL)analyzeImage:(CIImage *)image settings:(PGBeautySettings)settings time:(CMTime)time error:(NSError **)error {
    NSString *key = PGTimeKey(time);
    if (!image || !key || CGRectIsInfinite(image.extent) || CGRectIsEmpty(image.extent)) {
        if (error) *error = [NSError errorWithDomain:PGFaceErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey:@"Face analysis requires a finite image and valid frame time."}];
        return NO;
    }
    NSArray *observations = [self cachedObservationsInImage:image settings:settings time:time error:error];
    if (!observations) return NO;
    NSUInteger target = MIN((NSUInteger)settings.targetIndex, 2);
    NSDictionary *prior = [self recordForTime:time target:target nearest:YES];
    NSArray *geometry = [self geometryForObservations:observations settings:settings previous:prior];
    NSDictionary *record = @{@"value":@(time.value), @"scale":@(time.timescale), @"epoch":@(time.epoch), @"faces":geometry};
    [_lock lock];
    _targets[target][key] = record;
    [_lock unlock];
    return YES;
}

- (CIImage *)ellipseInRect:(CGRect)rect extent:(CGRect)extent inner:(CGFloat)inner {
    return [_ellipse applyWithExtent:extent arguments:@[PGVector(PGCenter(rect)), [CIVector vectorWithX:rect.size.width * 0.5 Y:rect.size.height * 0.5], @(inner)]];
}

- (CIImage *)warpImage:(CIImage *)image geometry:(NSArray<NSDictionary *> *)geometry settings:(PGBeautySettings)s extent:(CGRect)extent {
    if (!(s.faceThin || s.faceBigEye || s.faceShort || s.faceNarrow || s.faceChin || s.faceV || s.faceJaw || s.faceCheekbone || s.faceSmallHead)) return [image imageByCroppingToRect:extent];
    CIImage *result = image;
    for (NSDictionary *face in geometry) {
        CGRect box = PGArrayRect(face[@"box"]), pixels = PGToPixels(box, extent);
        NSArray *points76 = PGSanitizedPoints76(face[@"points76"]);
        float thinRatio = 0, chinRatio = 0, jawRatio = 0, shortRatio = 0, vRatio = 0;
        if (points76) {
            double width = hypot(([points76[75][0] doubleValue]-[points76[59][0] doubleValue])*extent.size.width,
                                 ([points76[75][1] doubleValue]-[points76[59][1] doubleValue])*extent.size.height);
            double midX = ([points76[74][0] doubleValue]+[points76[60][0] doubleValue])*.5;
            double midY = ([points76[74][1] doubleValue]+[points76[60][1] doubleValue])*.5;
            double height = 2*hypot(([points76[67][0] doubleValue]-midX)*extent.size.width,
                                    ([points76[67][1] doubleValue]-midY)*extent.size.height);
            double gain = fmin(2.25,fmax(1,280/fmax(1,fmax(width,height))));
            // The 2.4.0 pin shader consumes this CPU coefficient directly;
            // its thin field no longer applies the older 280-pixel size gain.
            thinRatio = PGClamp(s.faceThin,0,1)*.025;
            float chin = PGClamp(s.faceChin,-1,1);
            chinRatio = chin*(chin>0 ? .04 : .02)*gain;
            jawRatio = PGClamp(s.faceJaw,0,1)*.05*gain;
            shortRatio = PGClamp(s.faceShort,-1,1)*.25*gain;
            // The specified 2.4.0 shader takes the CPU-scaled .065 V ratio
            // directly; it no longer applies the older shader's size gain.
            vRatio = PGClamp(s.faceV,0,1)*.065;
        }
        BOOL otherControls = s.faceBigEye || s.faceNarrow || s.faceCheekbone || s.faceSmallHead;
        // No full topology means no guessed bbox thin/V/chin/jaw/short deformation. Legacy
        // archives using only those controls remain exact image/mask pass-through.
        if (thinRatio <= .000001 && vRatio <= .000001 && fabsf(chinRatio) <= .000001 && fabsf(jawRatio) <= .000001 && fabsf(shortRatio) <= .000001 && !otherControls) continue;
        CGRect le = PGRegionBounds(face, @"leftEye", PGInFace(box, 0.16, 0.53, 0.25, 0.15));
        CGRect re = PGRegionBounds(face, @"rightEye", PGInFace(box, 0.59, 0.53, 0.25, 0.15));
        CGPoint left = PGCenter(PGToPixels(le, extent)), right = PGCenter(PGToPixels(re, extent));
        double leftRadius=MAX(2,pixels.size.width*.24),rightRadius=MAX(2,pixels.size.width*.24);
        if(points76) {
            CGPoint lp=PGPoint(points76[6]),rp=PGPoint(points76[13]);
            left=CGPointMake(extent.origin.x+lp.x*extent.size.width,extent.origin.y+lp.y*extent.size.height);
            right=CGPointMake(extent.origin.x+rp.x*extent.size.width,extent.origin.y+rp.y*extent.size.height);
            CGPoint a=PGPoint(points76[0]),b=PGPoint(points76[1]),c=PGPoint(points76[7]),d=PGPoint(points76[8]);
            leftRadius=hypot((a.x-b.x)*extent.size.width,(a.y-b.y)*extent.size.height);
            rightRadius=hypot((c.x-d.x)*extent.size.width,(c.y-d.y)*extent.size.height);
        }
        NSMutableArray *arguments = [@[PGVector(PGCenter(pixels)), [CIVector vectorWithX:pixels.size.width Y:pixels.size.height],
            PGVector(left), PGVector(right), [CIVector vectorWithX:leftRadius Y:rightRadius],
            @(thinRatio), @(PGClamp(s.faceBigEye, 0, 1)*.15), @(shortRatio),
            @(PGClamp(s.faceNarrow, -1, 1)), @(chinRatio), @(vRatio),
            @(jawRatio), @(PGClamp(s.faceCheekbone, 0, 1)), @(PGClamp(s.faceSmallHead, 0, 1)), @(PGClamp(s.faceSmallHeadRange, 0, 1)),
            [CIVector vectorWithX:extent.origin.x Y:extent.origin.y], [CIVector vectorWithX:extent.size.width Y:extent.size.height]] mutableCopy];
        for (NSUInteger i=0; i<17; i++) {
            double ox=0,oy=0,ax=0,ay=0;
            if (points76) {
                NSArray *origin=points76[PGThinPins[i][0]],*anchor=points76[PGThinPins[i][1]];
                ox=[origin[0] doubleValue];oy=1-[origin[1] doubleValue];
                ax=[anchor[0] doubleValue];ay=1-[anchor[1] doubleValue];
            }
            [arguments addObject:[CIVector vectorWithX:ox Y:oy Z:ax W:ay]];
        }
        for (NSUInteger i=0; i<4; i++) {
            double ox=0,oy=0,ax=0,ay=0;
            if (points76) {
                NSArray *origin=points76[PGVFacePins[i][0]],*anchor=points76[PGVFacePins[i][1]];
                ox=[origin[0] doubleValue];oy=1-[origin[1] doubleValue];
                ax=[anchor[0] doubleValue];ay=1-[anchor[1] doubleValue];
            }
            [arguments addObject:[CIVector vectorWithX:ox Y:oy Z:ax W:ay]];
        }
        for (NSUInteger i=0; i<3; i++) {
            double ox=0,oy=0,ax=0,ay=0;
            if (points76) {
                NSArray *origin=points76[PGChinPins[i][0]],*anchor=points76[PGChinPins[i][1]];
                ox=[origin[0] doubleValue];oy=1-[origin[1] doubleValue];
                ax=[anchor[0] doubleValue];ay=1-[anchor[1] doubleValue];
            }
            [arguments addObject:[CIVector vectorWithX:ox Y:oy Z:ax W:ay]];
        }
        CGPoint anchor=CGPointZero,axis=CGPointZero;
        if(points76){
            anchor=CGPointMake([points76[29][0]doubleValue],1-[points76[29][1]doubleValue]);
            axis=CGPointMake([points76[46][0]doubleValue]-[points76[48][0]doubleValue],
                             [points76[48][1]doubleValue]-[points76[46][1]doubleValue]);
        }
        [arguments addObject:PGVector(anchor)];[arguments addObject:PGVector(axis)];
        for(NSUInteger i=0;i<6;i++){
            double ox=0,oy=0,nx=0,ny=0;
            if(points76){NSArray *origin=points76[PGJawPins[i][0]],*neighbour=points76[PGJawPins[i][1]];
                ox=[origin[0]doubleValue];oy=1-[origin[1]doubleValue];nx=[neighbour[0]doubleValue];ny=1-[neighbour[1]doubleValue];}
            [arguments addObject:[CIVector vectorWithX:ox Y:oy Z:nx W:ny]];
        }
        for(NSUInteger i=62;i<=72;i++){
            CGPoint point=CGPointZero;if(points76)point=CGPointMake([points76[i][0]doubleValue],1-[points76[i][1]doubleValue]);
            [arguments addObject:PGVector(point)];
        }
        CIImage *input = [result imageByClampingToExtent];
        result = [_warp applyWithExtent:extent roiCallback:^CGRect(int index, CGRect rect) { (void)index; (void)rect; return extent; } inputImage:input arguments:arguments];
        if (!result) return nil;
    }
    return [result imageByCroppingToRect:extent];
}

- (PGFaceFrame *)processImage:(CIImage *)image settings:(PGBeautySettings)settings time:(CMTime)time error:(NSError **)error {
    CGRect extent = image.extent;
    if (!image || CGRectIsInfinite(extent) || CGRectIsEmpty(extent) || !_ellipse || !_warp || !_box || !_subtract) {
        if (error) *error = [NSError errorWithDomain:PGFaceErrorDomain code:2 userInfo:@{NSLocalizedDescriptionKey:@"Unable to initialize face processing for this image."}];
        return nil;
    }
    NSDictionary *record = settings.trackingEnabled ? [self recordForTime:time target:MIN((NSUInteger)settings.targetIndex, 2) nearest:NO] : nil;
    NSArray<NSDictionary *> *geometry,*appearance;
    NSArray<VNFaceObservation *> *observations;
    if (record) {
        geometry = record[@"faces"];
        appearance = geometry;
        NSMutableArray *restored = [NSMutableArray array];
        for (NSDictionary *face in geometry) [restored addObject:[VNFaceObservation faceObservationWithRequestRevision:VNDetectFaceLandmarksRequestRevision3 boundingBox:PGArrayRect(face[@"box"]) roll:nil yaw:nil pitch:nil]];
        observations = restored;
    } else {
        NSArray *detected = [self cachedObservationsInImage:image settings:settings time:time error:error];
        BOOL transientDetectionFailure=detected==nil;
        if (!detected) {
            if(settings.trackingEnabled)return nil;
            // A failed live detection takes the same shape-hold path as a lost
            // observation; it must not fail the host's entire render request.
            detected=@[];if(error)*error=nil;
        }
        if(settings.trackingEnabled) {
            // Preserve the explicit offline-analysis contract. Its stored
            // identity fallback never reads or writes realtime temporal state.
            NSDictionary *anchor=[self recordForTime:time target:MIN((NSUInteger)settings.targetIndex,2) nearest:YES];
            geometry=[self geometryForObservations:detected settings:settings previous:anchor];
            appearance=geometry;
            NSMutableArray *selected=[NSMutableArray new];
            for(NSDictionary *face in geometry) for(VNFaceObservation *observation in detected)
                if(CGRectEqualToRect(observation.boundingBox,PGArrayRect(face[@"box"]))) {[selected addObject:observation];break;}
            observations=selected;
        } else {
            NSMutableArray *raw=[NSMutableArray new],*validObservations=[NSMutableArray new];
            for(VNFaceObservation *observation in detected) if(PGValidRect(observation.boundingBox) && raw.count<16) {
                [raw addObject:PGGeometry(observation)];[validObservations addObject:observation];
            }
            NSDictionary *live=[_realtime resultForGeometry:raw settings:settings time:time extent:extent image:image];
            // A successful empty detection is frozen; an API error is not. Its
            // temporary held output must allow a same-time retry to acquire a face.
            if(transientDetectionFailure)[_realtime removeCachedResult:live];
            geometry=live[@"output"];
            if(settings.singleFace && !settings.fastMultiFace) {
                NSInteger index=[live[@"index"] integerValue];
                if(index>=0 && (NSUInteger)index<validObservations.count) {
                    // Retain the selected original Vision observation. A stable
                    // geometry box need not equal its unsmoothed detection box.
                    observations=@[validObservations[(NSUInteger)index]];
                    appearance=@[raw[(NSUInteger)index]];
                } else {
                    appearance=geometry;
                    NSMutableArray *held=[NSMutableArray new];
                    for(NSDictionary *face in geometry) [held addObject:[VNFaceObservation faceObservationWithRequestRevision:VNDetectFaceLandmarksRequestRevision3 boundingBox:PGArrayRect(face[@"box"]) roll:nil yaw:nil pitch:nil]];
                    observations=held;
                }
            } else {
                // Default single-primary geometry does not narrow the separate
                // skin/teeth/eyes support, which still covers the detected group.
                appearance=raw;observations=validObservations;
            }
            if(([live[@"held"] boolValue] || transientDetectionFailure) && geometry.count) {
                // Keep beauty masks on the same held primary shape as the warp,
                // while retaining support for independently detected secondary faces.
                NSMutableArray *supported=[appearance mutableCopy];
                NSInteger index=[live[@"index"] integerValue];
                if(!settings.singleFace && index>=0 && (NSUInteger)index<supported.count) supported[(NSUInteger)index]=geometry.firstObject;
                else if(settings.singleFace || !supported.count) supported=[geometry mutableCopy];
                else [supported addObjectsFromArray:geometry];
                appearance=supported;
            }
        }
    }
    CIImage *skin = PGBlack(extent), *teeth = PGBlack(extent), *eyes = PGBlack(extent), *protection = PGBlack(extent), *overlay = PGTransparent(extent);
    for (NSDictionary *face in appearance) {
        CGRect box = PGArrayRect(face[@"box"]);
        CGRect skinRect = PGInFace(box, -0.10, -0.04, 1.20, 1.16);
        skin = PGMaximum(skin, [self ellipseInRect:PGToPixels(skinRect, extent) extent:extent inner:0.78]);
        NSArray *names = @[@"leftEye", @"rightEye", @"leftBrow", @"rightBrow", @"lips", @"nose"];
        NSArray<NSValue *> *fallbacks = @[[NSValue valueWithRect:PGInFace(box, 0.16, 0.53, 0.25, 0.15)],
            [NSValue valueWithRect:PGInFace(box, 0.59, 0.53, 0.25, 0.15)],
            [NSValue valueWithRect:PGInFace(box, 0.12, 0.72, 0.29, 0.08)],
            [NSValue valueWithRect:PGInFace(box, 0.59, 0.72, 0.29, 0.08)],
            [NSValue valueWithRect:PGInFace(box, 0.27, 0.16, 0.46, 0.18)],
            [NSValue valueWithRect:PGInFace(box, 0.39, 0.33, 0.22, 0.16)]];
        for (NSUInteger i = 0; i < names.count; i++) {
            CGRect region = PGToPixels(PGRegionBounds(face, names[i], fallbacks[i].rectValue), extent);
            CGRect expanded = CGRectInset(region, -region.size.width * 0.15, -region.size.height * 0.35);
            CIImage *mask = [self ellipseInRect:expanded extent:extent inner:0.45];
            protection = PGMaximum(protection, mask);
            if (i < 2) eyes = PGMaximum(eyes, [self ellipseInRect:region extent:extent inner:0.45]);
        }
        CGRect mouth = PGRegionBounds(face, @"mouth", PGInFace(box, 0.30, 0.20, 0.40, 0.08));
        teeth = PGMaximum(teeth, [self ellipseInRect:PGToPixels(mouth, extent) extent:extent inner:0.35]);
        if (settings.showFaceBoxes) {
            CGRect pixels = PGToPixels(box, extent);
            CGFloat inset = MAX(1, MIN(pixels.size.width, pixels.size.height) * 0.005);
            CIImage *outline = [_box applyWithExtent:extent arguments:@[[CIVector vectorWithX:CGRectGetMinX(pixels) Y:CGRectGetMinY(pixels) Z:CGRectGetMaxX(pixels) W:CGRectGetMaxY(pixels)], @(inset), [CIVector vectorWithX:0.12 Y:1.0 Z:0.35 W:0.95]]];
            overlay = [outline imageByCompositingOverImage:overlay];
        }
    }
    if(settings.showTrackBox) for(NSDictionary *face in geometry) {
        CGRect pixels=PGToPixels(PGArrayRect(face[@"box"]),extent);
        CGFloat inset=MAX(1,MIN(pixels.size.width,pixels.size.height)*.005);
        CIImage *outline=[_box applyWithExtent:extent arguments:@[[CIVector vectorWithX:CGRectGetMinX(pixels) Y:CGRectGetMinY(pixels) Z:CGRectGetMaxX(pixels) W:CGRectGetMaxY(pixels)],@(inset),[CIVector vectorWithX:1 Y:.8 Z:.2 W:.95]]];
        overlay=[outline imageByCompositingOverImage:overlay];
    }
    CIImage *colorCoverage=skin;
    if (settings.featureProtection) skin = [_subtract applyWithExtent:extent arguments:@[skin, protection]];
    PGFaceFrame *frame = [[PGFaceFrame alloc] init];
    frame.faces = observations ?: @[];
    frame.deformationGeometry=geometry?:@[];
    frame.image = [self warpImage:image geometry:geometry settings:settings extent:extent];
    frame.skinMask = [self warpImage:skin geometry:geometry settings:settings extent:extent];
    frame.colorMask = [self warpImage:colorCoverage geometry:geometry settings:settings extent:extent];
    frame.teethMask = [self warpImage:teeth geometry:geometry settings:settings extent:extent];
    frame.eyeMask = [self warpImage:eyes geometry:geometry settings:settings extent:extent];
    frame.overlayImage = [overlay imageByCroppingToRect:extent];
    if (!frame.image || !frame.skinMask || !frame.colorMask || !frame.teethMask || !frame.eyeMask) {
        if (error) *error = [NSError errorWithDomain:PGFaceErrorDomain code:3 userInfo:@{NSLocalizedDescriptionKey:@"Unable to apply face geometry."}];
        return nil;
    }
    return frame;
}

- (void)resetTracking {
    [_lock lock];
    for (NSMutableDictionary *target in _targets) [target removeAllObjects];
    [_lock unlock];
    [_realtime reset];
    @synchronized(_observationCache) { [_observationCache removeAllObjects]; }
}

- (NSData *)trackingDataForTarget:(NSUInteger)target {
    if (target >= 3) return nil;
    [_lock lock];
    NSDictionary *frames = [_targets[target] copy];
    [_lock unlock];
    if (!frames.count) return nil;
    return [NSPropertyListSerialization dataWithPropertyList:@{@"version":@1, @"frames":frames} format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
}

- (void)setTrackingData:(NSData *)data forTarget:(NSUInteger)target {
    if (target >= 3) return;
    NSMutableDictionary *frames = [NSMutableDictionary dictionary];
    if (data.length && data.length <= 128 * 1024 * 1024) {
        NSDictionary *archive = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:nil];
        if ([archive isKindOfClass:NSDictionary.class] && [archive[@"version"] isEqual:@1] && [archive[@"frames"] isKindOfClass:NSDictionary.class] && [archive[@"frames"] count] <= 250000) {
            for (id key in archive[@"frames"]) {
                id raw = archive[@"frames"][key];
                if (![key isKindOfClass:NSString.class] || ![raw isKindOfClass:NSDictionary.class]) continue;
                NSNumber *value = raw[@"value"], *scale = raw[@"scale"], *epoch = raw[@"epoch"];
                if (![value isKindOfClass:NSNumber.class] || ![scale isKindOfClass:NSNumber.class] || ![epoch isKindOfClass:NSNumber.class] || scale.intValue <= 0) continue;
                CMTime time = CMTimeMakeWithEpoch(value.longLongValue, scale.intValue, epoch.longLongValue);
                if (![key isEqualToString:PGTimeKey(time)] || ![raw[@"faces"] isKindOfClass:NSArray.class] || [raw[@"faces"] count] > 16) continue;
                NSMutableArray *faces = [NSMutableArray array];
                BOOL valid = YES;
                for (id geometry in raw[@"faces"]) {
                    NSDictionary *face = PGSanitizedGeometry(geometry);
                    if (!face) { valid = NO; break; }
                    [faces addObject:face];
                }
                if (valid) frames[key] = @{@"value":value, @"scale":scale, @"epoch":epoch, @"faces":[faces copy]};
            }
        }
    }
    [_lock lock];
    _targets[target] = frames;
    [_lock unlock];
}

@end
