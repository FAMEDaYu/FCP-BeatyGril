// The source kernels remain available on the supported macOS 12+ range. This
// keeps the processor self contained instead of requiring a separate metallib.
#define CI_SILENCE_GL_DEPRECATION 1
#import "PGFaceProcessor.h"
#include <math.h>
#include <float.h>

static NSString * const PGFaceErrorDomain = @"media.dayu.PaintFCP.Face";
// Contour origin / internal anchor, in the reference's recovered pin order.
// The unused middle entry of each reference triplet is intentionally omitted.
static const uint8_t PGThinPins[17][2] = {
    {75,6},{59,13},{74,47},{60,47},{73,47},{61,47},
    {72,48},{62,48},{71,48},{63,48},{70,49},{64,49},
    {69,49},{65,49},{68,52},{66,52},{67,47}
};

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
    if (region.pointCount != 76 || !region.normalizedPoints) return nil;
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
    // controls. Missing or malformed full topology only disables local thinning.
    NSArray *points76 = PGSanitizedPoints76(value[@"points76"]);
    if (points76) result[@"points76"] = points76;
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
static NSDictionary *PGStableGeometry(NSDictionary *current, NSDictionary *previous, double dt, BOOL stabilizePoints76) {
    CGRect old=PGArrayRect(previous[@"box"]),box=PGArrayRect(current[@"box"]);
    if(!PGValidRect(old) || !PGValidRect(box))return current;
    // Independent stabilization: translate/scale old landmarks into the current
    // detection box first, so normal head motion does not accumulate box lag.
    double weight=.9*fmin(1,fmax(0,dt/.03));
    CGPoint oldLE=PGCenter(PGRegionBounds(previous,@"leftEye",PGInFace(old,.16,.53,.25,.15)));
    CGPoint oldRE=PGCenter(PGRegionBounds(previous,@"rightEye",PGInFace(old,.59,.53,.25,.15)));
    CGPoint newLE=PGCenter(PGRegionBounds(current,@"leftEye",PGInFace(box,.16,.53,.25,.15)));
    CGPoint newRE=PGCenter(PGRegionBounds(current,@"rightEye",PGInFace(box,.59,.53,.25,.15)));
    double ox=oldRE.x-oldLE.x,oy=oldRE.y-oldLE.y,nx=newRE.x-newLE.x,ny=newRE.y-newLE.y;
    double oldLength=hypot(ox,oy),newLength=hypot(nx,ny);
    BOOL axisHold=oldLength>MAX(.003,.055*MIN(old.size.height,box.size.height)) &&
        newLength>MAX(.003,.055*MIN(old.size.height,box.size.height)) &&
        (ox*nx+oy*ny)/(oldLength*newLength)<-.18;
    NSMutableDictionary *stable=[NSMutableDictionary dictionaryWithObject:current[@"box"] forKey:@"box"];
    for(NSString *name in PGGeometryRegions()) {
        NSArray *a=previous[name],*b=current[name];
        if(!a.count || (!axisHold && a.count!=b.count)) {stable[name]=b;continue;}
        NSMutableArray *points=[NSMutableArray arrayWithCapacity:a.count];
        for(NSUInteger i=0;i<a.count;i++) {
            CGPoint p=PGRemapPoint(a[i],old,box);
            if(!axisHold) {p.x+=( [b[i][0] doubleValue]-p.x)*weight;p.y+=([b[i][1] doubleValue]-p.y)*weight;}
            [points addObject:@[@(p.x),@(p.y)]];
        }
        stable[name]=[points copy];
    }
    NSArray *current76 = PGSanitizedPoints76(current[@"points76"]);
    NSArray *previous76 = PGSanitizedPoints76(previous[@"points76"]);
    if (current76) {
        if (stabilizePoints76 && previous76) {
            NSMutableArray *points = [NSMutableArray arrayWithCapacity:76];
            for (NSUInteger i=0; i<76; i++) {
                CGPoint p = PGRemapPoint(previous76[i], old, box);
                if (!axisHold) {
                    p.x += ([current76[i][0] doubleValue]-p.x)*weight;
                    p.y += ([current76[i][1] doubleValue]-p.y)*weight;
                }
                [points addObject:@[@(p.x),@(p.y)]];
            }
            stable[@"points76"] = [points copy];
        } else {
            // Reacquired detections and changes from/to incomplete topology do
            // not borrow a held face's old projected pose or invent missing points.
            stable[@"points76"] = current76;
        }
    }
    return [stable copy];
}

// This live selector is deliberately independent of _targets. Its past-only
// .35s reference window is a documented project policy, not a recovered exact
// vendor formula. Continuous held outputs advance time, so this is not a hold
// timeout. Locks protect state, not global render-order equivalence: a cold seek
// cannot reconstruct frames the host has never supplied.
@interface PGRealtimeFaceTracker : NSObject {
    NSLock *_mutex;
    NSMutableArray<NSDictionary *> *_entries;
    NSUInteger _estimatedBytes;
}
- (NSDictionary *)resultForGeometry:(NSArray<NSDictionary *> *)raw settings:(PGBeautySettings)settings time:(CMTime)time extent:(CGRect)extent;
- (void)reset;
- (NSDictionary *)cacheStatistics;
@end
@implementation PGRealtimeFaceTracker
- (instancetype)init {if((self=[super init])){_mutex=[NSLock new];_entries=[NSMutableArray new];}return self;}
- (void)reset {[_mutex lock];[_entries removeAllObjects];_estimatedBytes=0;[_mutex unlock];}
- (NSDictionary *)cacheStatistics {[_mutex lock];NSDictionary *stats=@{@"frames":@(_entries.count),@"estimatedBytes":@(_estimatedBytes)};[_mutex unlock];return stats;}
- (NSDictionary *)resultForGeometry:(NSArray<NSDictionary *> *)input settings:(PGBeautySettings)s time:(CMTime)time extent:(CGRect)extent {
    NSMutableArray *valid=[NSMutableArray new];
    for(id item in input) {NSDictionary *g=PGSanitizedGeometry(item);if(g && valid.count<16)[valid addObject:g];}
    NSArray *raw=[valid copy];
    NSUInteger mode=s.fastMultiFace?2:(s.singleFace?1:0);
    NSString *key=PGTimeKey(time);
    NSString *context=[NSString stringWithFormat:@"%lu/%u/%lld/%.17g/%.17g/%.17g/%.17g/%.9g",(unsigned long)mode,s.targetIndex,
        (long long)time.epoch,extent.origin.x,extent.origin.y,extent.size.width,extent.size.height,s.faceJumpGuardRange];
    [_mutex lock];
    NSDictionary *head=nil;
    for(NSDictionary *record in _entries) if([record[@"context"] isEqual:context] &&
        (!head || CMTimeCompare(PGRecordTime(record),PGRecordTime(head))>=0)) head=record;
    NSString *scope=@"automatic";
    double seedX=PGClamp(s.selectionX,0,1),seedY=PGClamp(s.selectionY,0,1);
    if(mode==1) {
        // A real point change (> .01) starts a new identity scope. Older render
        // snapshots may use their own past scope, but never replace a newer head.
        NSDictionary *seedRecord=head;
        if(seedRecord && CMTimeCompare(time,PGRecordTime(seedRecord))<0) {
            seedRecord=nil;
            for(NSDictionary *record in _entries) if([record[@"context"] isEqual:context] && PGSeedDistance(record,s)<=.01 &&
                CMTimeCompare(PGRecordTime(record),time)<=0 && (!seedRecord || CMTimeCompare(PGRecordTime(record),PGRecordTime(seedRecord))>=0))seedRecord=record;
        }
        if(seedRecord && PGSeedDistance(seedRecord,s)<=.01) {
            scope=seedRecord[@"scope"];seedX=[seedRecord[@"seedX"] doubleValue];seedY=[seedRecord[@"seedY"] doubleValue];
        } else scope=[NSString stringWithFormat:@"%@/%.9g/%.9g",key?:@"invalid",seedX,seedY];
    }
    NSDictionary *reference=nil;
    if(key) for(NSDictionary *record in _entries) {
        if(![record[@"context"] isEqual:context] || ![record[@"scope"] isEqual:scope])continue;
        if([record[@"key"] isEqual:key] && [record[@"raw"] isEqual:raw]) {[_mutex unlock];return record;}
        CMTime stored=PGRecordTime(record);
        // Same-time changed detections recompute from an earlier frame, never
        // feed an already smoothed result into another pass at that same time.
        if(CMTimeCompare(stored,time)>=0)continue;
        double dt=CMTimeGetSeconds(CMTimeSubtract(time,stored));
        if(dt<=.35 && (!reference || CMTimeCompare(stored,PGRecordTime(reference))>0))reference=record;
    }
    NSArray *prior=reference[@"output"];
    NSDictionary *previous=prior.count?prior.firstObject:nil;
    CGRect previousBox=PGArrayRect(previous[@"box"]);
    NSInteger index=-1;double best=-DBL_MAX;
    if(mode!=2) for(NSUInteger i=0;i<raw.count;i++) {
        CGRect box=PGArrayRect(raw[i][@"box"]);CGPoint center=PGCenter(box);double score;
        if(PGValidRect(previousBox)) {
            CGFloat factor=PGClamp(s.faceJumpGuardRange,1,4);
            CGRect guard=CGRectIntersection(CGRectMake(0,0,1,1),CGRectInset(previousBox,-previousBox.size.width*(factor-1)*.5,-previousBox.size.height*(factor-1)*.5));
            if(center.x<CGRectGetMinX(guard)||center.x>CGRectGetMaxX(guard)||center.y<CGRectGetMinY(guard)||center.y>CGRectGetMaxY(guard))continue;
            CGPoint p=PGCenter(previousBox);score=-((center.x-p.x)*(center.x-p.x)+(center.y-p.y)*(center.y-p.y));
        } else if(mode==1) score=-((center.x-seedX)*(center.x-seedX)+(center.y-seedY)*(center.y-seedY));
        else {CGRect clipped=CGRectIntersection(box,CGRectMake(0,0,1,1));CGPoint p=PGCenter(clipped);
            score=1.8*fmin(1,clipped.size.width*clipped.size.height)+1.1*(1-fmin(1,hypot(p.x-.5,p.y-.5)/.72));}
        if(index<0 || score>best) {index=(NSInteger)i;best=score;}
    }
    NSArray *output;BOOL held=NO;
    if(mode==2) output=raw;
    else if(index>=0) {
        NSDictionary *current=raw[(NSUInteger)index];
        double dt=reference?CMTimeGetSeconds(CMTimeSubtract(time,PGRecordTime(reference))):0;
        output=@[previous?PGStableGeometry(current,previous,dt,![reference[@"held"] boolValue]):current];
    } else {output=prior?:@[];held=output.count>0;}
    NSMutableDictionary *record=[@{@"context":context,@"scope":scope,@"key":key?:@"invalid",@"value":@(time.value),@"scale":@(time.timescale),@"epoch":@(time.epoch),
        @"seedX":@(seedX),@"seedY":@(seedY),@"raw":raw,@"output":output,@"index":@(index),@"held":@(held),@"referenceKey":reference[@"key"]?:@""} mutableCopy];
    if(key) {
        NSData *serialized=[NSPropertyListSerialization dataWithPropertyList:record format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
        NSUInteger bytes=serialized.length+512;
        record[@"bytes"]=@(bytes);
        // Replace changed raw geometry at the same timestamp rather than letting
        // callbacks grow history or make smoothing depend on redraw count.
        for(NSInteger i=(NSInteger)_entries.count-1;i>=0;i--) {
            NSDictionary *old=_entries[(NSUInteger)i];
            if([old[@"context"] isEqual:context] && [old[@"scope"] isEqual:scope] && [old[@"key"] isEqual:key]) {
                _estimatedBytes-=[old[@"bytes"] unsignedIntegerValue];[_entries removeObjectAtIndex:(NSUInteger)i];
            }
        }
        if(bytes<=16*1024*1024) {[_entries addObject:[record copy]];_estimatedBytes+=bytes;}
        while(_entries.count>1200 || _estimatedBytes>16*1024*1024) {
            _estimatedBytes-=[_entries.firstObject[@"bytes"] unsignedIntegerValue];[_entries removeObjectAtIndex:0];
        }
    }
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
}
@end

@implementation PGFaceProcessor

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = [[NSLock alloc] init];
        _realtime = [PGRealtimeFaceTracker new];
        _targets = [NSMutableArray arrayWithObjects:[NSMutableDictionary dictionary], [NSMutableDictionary dictionary], [NSMutableDictionary dictionary], nil];
        // Local thinning reconstructs the recovered 17-pin coordinate math.
        // The other eight controls retain this project's analytic approximation.
        // Each pin changes the sampling coordinate, with only one image resample.
        NSMutableString *source = [NSMutableString stringWithString:
        @"vec2 pgThinPin(vec2 q, vec4 control, float ratio) {"
        " vec2 direction=control.zw-control.xy; float radius=length(direction);"
        " if(radius<=0.0001) return q;"
        " float weight=clamp(1.0-length(q-control.xy)/radius,0.0,1.0);"
        " return clamp(q-direction*ratio*weight,vec2(0.0),vec2(1.0)); }"
        " kernel vec2 pgFaceWarp(vec2 c, vec2 size, vec2 le, vec2 re, vec2 er, float thinRatio, float bigEye, float shortFace, float narrow, float chin, float vFace, float jaw, float cheek, float smallHead, float headRange, vec2 imageOrigin, vec2 imageSize"];
        for (NSUInteger i=0; i<17; i++) [source appendFormat:@", vec4 pin%lu",(unsigned long)i];
        [source appendString:@") { vec2 p=destCoord();"
        " if(thinRatio>0.000001) { vec2 q=(p-imageOrigin)/imageSize; q.y=1.0-q.y;"];
        for (NSUInteger i=0; i<17; i++) [source appendFormat:@" q=pgThinPin(q,pin%lu,thinRatio);",(unsigned long)i];
        [source appendString:@" q.y=1.0-q.y; p=imageOrigin+q*imageSize; }"
        " vec2 n = (p-c)/size;"
        " float body = 1.0-smoothstep(0.38,0.76,length(n*vec2(1.0,0.82)));"
        " float lower = (1.0-smoothstep(-0.12,0.27,n.y))*body;"
        " float sides = smoothstep(0.08,0.32,abs(n.x));"
        " float j=(n.y+0.23)/0.22; float jawBand = exp(-j*j)*body;"
        " float ch=(n.y-0.02)/0.19; float cheekBand = exp(-ch*ch)*body;"
        " float head = 1.0-smoothstep(0.38,0.75+0.32*headRange,length(n*vec2(0.9,0.65)));"
        " p += (p-c)*smallHead*0.18*head;"
        " p.x += size.x*n.x*(narrow*0.30*body + vFace*0.24*jawBand + jaw*0.20*jawBand + cheek*0.18*cheekBand)*sides;"
        " float cn=n.x/0.30; p.y += size.y*(-shortFace*0.16*lower + chin*0.13*exp(-cn*cn)*jawBand - vFace*0.025*lower);"
        " vec2 dl = (p-le)/er; float wl = 1.0-smoothstep(0.0,1.0,length(dl));"
        " p -= (p-le)*bigEye*0.33*wl*wl;"
        " vec2 dr = (p-re)/er; float wr = 1.0-smoothstep(0.0,1.0,length(dr));"
        " p -= (p-re)*bigEye*0.33*wr*wr; return p; }"];
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
    CGRect extent = image.extent;
    CGFloat longest = MAX(extent.size.width, extent.size.height);
    CGFloat scale = MIN(1.0, (settings.fastMultiFace ? 720.0 : 1280.0) / longest);
    CIImage *prepared = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(-extent.origin.x, -extent.origin.y)];
    prepared = [prepared imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    VNDetectFaceLandmarksRequest *request = [[VNDetectFaceLandmarksRequest alloc] init];
    request.revision = VNDetectFaceLandmarksRequestRevision3;
    request.constellation = VNRequestFaceLandmarksConstellation76Points;
    // An image request handler is intentionally local to one invocation. A shared
    // sequence handler would make parallel / reverse render order observable.
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCIImage:prepared options:@{}];
    if (![handler performRequests:@[request] error:error]) return nil;
    NSArray<VNFaceObservation *> *faces = request.results ?: @[];
    return [faces sortedArrayUsingComparator:^NSComparisonResult(VNFaceObservation *a, VNFaceObservation *b) {
        CGRect x = a.boundingBox, y = b.boundingBox;
        if (CGRectGetMidX(x) != CGRectGetMidX(y)) return CGRectGetMidX(x) < CGRectGetMidX(y) ? NSOrderedAscending : NSOrderedDescending;
        if (CGRectGetMidY(x) != CGRectGetMidY(y)) return CGRectGetMidY(x) < CGRectGetMidY(y) ? NSOrderedAscending : NSOrderedDescending;
        return x.size.width > y.size.width ? NSOrderedAscending : NSOrderedDescending;
    }];
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
    NSArray *observations = [self observationsInImage:image settings:settings error:error];
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
        float thinRatio = 0;
        if (points76) {
            double width = hypot(([points76[75][0] doubleValue]-[points76[59][0] doubleValue])*extent.size.width,
                                 ([points76[75][1] doubleValue]-[points76[59][1] doubleValue])*extent.size.height);
            double midX = ([points76[74][0] doubleValue]+[points76[60][0] doubleValue])*.5;
            double midY = ([points76[74][1] doubleValue]+[points76[60][1] doubleValue])*.5;
            double height = 2*hypot(([points76[67][0] doubleValue]-midX)*extent.size.width,
                                    ([points76[67][1] doubleValue]-midY)*extent.size.height);
            double gain = fmin(2.25,fmax(1,280/fmax(1,fmax(width,height))));
            thinRatio = PGClamp(s.faceThin,0,1)*.025*gain;
        }
        BOOL otherControls = s.faceBigEye || s.faceShort || s.faceNarrow || s.faceChin || s.faceV || s.faceJaw || s.faceCheekbone || s.faceSmallHead;
        // No full topology means no guessed bbox thinning. In particular, legacy
        // archives with thinning alone remain an exact image/mask pass-through.
        if (thinRatio <= .000001 && !otherControls) continue;
        CGRect le = PGRegionBounds(face, @"leftEye", PGInFace(box, 0.16, 0.53, 0.25, 0.15));
        CGRect re = PGRegionBounds(face, @"rightEye", PGInFace(box, 0.59, 0.53, 0.25, 0.15));
        CGPoint left = PGCenter(PGToPixels(le, extent)), right = PGCenter(PGToPixels(re, extent));
        NSMutableArray *arguments = [@[PGVector(PGCenter(pixels)), [CIVector vectorWithX:pixels.size.width Y:pixels.size.height],
            PGVector(left), PGVector(right), [CIVector vectorWithX:MAX(2, pixels.size.width * 0.24) Y:MAX(2, pixels.size.height * 0.17)],
            @(thinRatio), @(PGClamp(s.faceBigEye, 0, 1)), @(PGClamp(s.faceShort, -1, 1)),
            @(PGClamp(s.faceNarrow, -1, 1)), @(PGClamp(s.faceChin, -1, 1)), @(PGClamp(s.faceV, 0, 1)),
            @(PGClamp(s.faceJaw, 0, 1)), @(PGClamp(s.faceCheekbone, 0, 1)), @(PGClamp(s.faceSmallHead, 0, 1)), @(PGClamp(s.faceSmallHeadRange, 0, 1)),
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
        NSArray *detected = [self observationsInImage:image settings:settings error:error];
        if (!detected) return nil;
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
            NSDictionary *live=[_realtime resultForGeometry:raw settings:settings time:time extent:extent];
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
