// Contract tests for the 2.4.0 pin-style reconstruction. The source is imported
// once so the quality gate and actual tracker can be exercised without a host,
// real portrait, private Vision construction, or reference binary execution.
#import "../FCP-BeautyGirl/FCP-BeautyGirl/Plugin/PGFaceProcessor.m"
#import "tracking_fixture.h"

static NSUInteger checks=0,failures=0;
static void Check(BOOL ok,NSString *message){checks++;if(!ok){failures++;fprintf(stderr,"FAIL: %s\n",message.UTF8String);}}
static BOOL EqualPoints(NSArray *a,NSArray *b,double tolerance){
    if(a.count!=76||b.count!=76)return NO;
    for(NSUInteger i=0;i<76;i++)for(NSUInteger j=0;j<2;j++)if(fabs([a[i][j] doubleValue]-[b[i][j] doubleValue])>tolerance)return NO;
    return YES;
}
static NSDictionary *First(NSDictionary *result){return [result[@"output"] firstObject];}
static NSDictionary *Live(PGRealtimeFaceTracker *t,NSArray *g,PGBeautySettings s,int64_t tick){return[t resultForGeometry:g settings:s time:CMTimeMake(tick,1000) extent:CGRectMake(0,0,256,256)];}
static NSArray *MappedPoints(NSDictionary *g,CGRect box){
    CGRect old=PGArrayRect(g[@"box"]);NSMutableArray *a=[NSMutableArray new];
    for(NSArray *point in g[@"points76"]){CGPoint p=PGRemapPoint(point,old,box);[a addObject:@[@(p.x),@(p.y)]];}return a;
}
static NSDictionary *Without76(NSDictionary *g){NSMutableDictionary *bad=[g mutableCopy];[bad removeObjectForKey:@"points76"];return bad;}
static NSDictionary *WithPoints(NSDictionary *g,void (^change)(NSMutableArray *)){
    NSMutableDictionary *bad=[g mutableCopy];NSMutableArray *p=[g[@"points76"] mutableCopy];change(p);bad[@"points76"]=p;return bad;
}

@interface PGScriptedTracker : PGRealtimeFaceTracker
@property CGRect proposedBox;
@property NSUInteger followCalls;
@property NSUInteger seedCalls;
@end
@implementation PGScriptedTracker
- (instancetype)init{if((self=[super init]))_proposedBox=CGRectNull;return self;}
- (CGRect)trackedBoxForImage:(CIImage *)image time:(CMTime)time seedBox:(CGRect)seed {
    if(PGValidRect(seed)){self.seedCalls++;return seed;}
    self.followCalls++;return self.proposedBox;
}
@end

@interface PGCountingDetector : PGFaceProcessor
@property (nonatomic,copy) NSArray<VNFaceObservation *> *suppliedFaces;
@property NSUInteger calls;
@property BOOL fail;
@end
@implementation PGCountingDetector
- (NSArray<VNFaceObservation *> *)observationsInImage:(CIImage *)image settings:(PGBeautySettings)s error:(NSError **)error {
    self.calls++;if(self.fail){if(error)*error=[NSError errorWithDomain:@"synthetic-detection" code:1 userInfo:nil];return nil;}return self.suppliedFaces?:@[];
}
@end
@interface PGScriptedOutputTracker : PGRealtimeFaceTracker
@property (nonatomic,copy) NSDictionary *scriptedOutput;
@end
@implementation PGScriptedOutputTracker
- (NSDictionary *)resultForGeometry:(NSArray *)raw settings:(PGBeautySettings)s time:(CMTime)time extent:(CGRect)extent image:(CIImage *)image {return self.scriptedOutput;}
@end

// Objective-C message-compatible test doubles, never supplied to Vision. They
// expose only the public read-only observation/region selectors used by the
// production geometry converter, backed entirely by our authored fixture.
@interface PGAuthoredRegion : NSObject
@property (nonatomic,strong) NSData *storage;
@property NSUInteger pointCount;
- (const CGPoint *)normalizedPoints;
@end
@implementation PGAuthoredRegion
- (const CGPoint *)normalizedPoints{return self.storage.bytes;}
@end
@interface PGAuthoredLandmarks : NSObject
@property (nonatomic,strong) PGAuthoredRegion *allPoints,*leftEye,*rightEye,*leftEyebrow,*rightEyebrow,*nose,*outerLips,*innerLips,*faceContour;
@property VNConfidence confidence;
@end
@implementation PGAuthoredLandmarks @end
@interface PGAuthoredObservation : NSObject
@property CGRect boundingBox;
@property (nonatomic,strong) PGAuthoredLandmarks *landmarks;
@property VNConfidence confidence;
@end
@implementation PGAuthoredObservation @end
static PGAuthoredRegion *AuthoredRegion(NSArray *points,CGRect box){
    NSMutableData *data=[NSMutableData dataWithLength:points.count*sizeof(CGPoint)];CGPoint *p=data.mutableBytes;
    for(NSUInteger i=0;i<points.count;i++)p[i]=PGLocalPoint(CGPointMake([points[i][0] doubleValue],[points[i][1] doubleValue]),box);
    PGAuthoredRegion *region=[PGAuthoredRegion new];region.storage=data;region.pointCount=points.count;return region;
}
static PGAuthoredObservation *AuthoredObservation(NSDictionary *g){
    CGRect box=PGArrayRect(g[@"box"]);PGAuthoredLandmarks *l=[PGAuthoredLandmarks new];l.confidence=.99;
    l.allPoints=AuthoredRegion(g[@"points76"],box);l.leftEye=AuthoredRegion(g[@"leftEye"],box);l.rightEye=AuthoredRegion(g[@"rightEye"],box);
    l.leftEyebrow=AuthoredRegion(g[@"leftBrow"],box);l.rightEyebrow=AuthoredRegion(g[@"rightBrow"],box);l.nose=AuthoredRegion(g[@"nose"],box);
    l.outerLips=AuthoredRegion(g[@"lips"],box);l.innerLips=AuthoredRegion(g[@"mouth"],box);l.faceContour=AuthoredRegion(g[@"contour"],box);
    PGAuthoredObservation *o=[PGAuthoredObservation new];o.boundingBox=box;o.landmarks=l;o.confidence=.99;return o;
}

static void QualityAndAcceptance(void){
    CGRect box=CGRectMake(.15,.12,.70,.78);NSDictionary *good=PGTrackingTestGeometry(box,0);
    Check(PGGeometryQualityReason(good).length==0,@"authored public-layout geometry passes the recovered quality gate");
    NSMutableDictionary *legacy=[good mutableCopy];[legacy removeObjectForKey:@"landmarkConfidence"];
    Check(PGGeometryQualityReason(legacy).length==0,@"missing confidence metadata keeps authored/legacy geometry usable");
    NSMutableDictionary *low=[good mutableCopy];low[@"landmarkConfidence"]=@.2;
    NSMutableDictionary *shortContour=[good mutableCopy];shortContour[@"contour"]=[good[@"contour"] subarrayWithRange:NSMakeRange(0,8)];
    NSMutableDictionary *eyes=[good mutableCopy];eyes[@"rightEye"]=eyes[@"leftEye"];
    NSMutableDictionary *mouth=[good mutableCopy];mouth[@"lips"]=mouth[@"leftEye"];
    NSMutableDictionary *nose=[good mutableCopy];nose[@"nose"]=@[@[@.5,@.99]];
    NSArray *badCases=@[Without76(good),WithPoints(good,^(NSMutableArray *p){p[65]=@[@(NAN),@.5];}),WithPoints(good,^(NSMutableArray *p){p[65]=@[@3,@.5];}),low,shortContour,eyes,mouth,nose];
    PGBeautySettings s=PGBeautyDefaults();s.faceThin=1;
    for(NSUInteger i=0;i<badCases.count;i++){
        NSDictionary *bad=badCases[i];
        Check(PGGeometryQualityReason(bad).length>0,[NSString stringWithFormat:@"quality rejects malformed case %lu",(unsigned long)i]);
        PGRealtimeFaceTracker *t=[PGRealtimeFaceTracker new];Live(t,@[good],s,0);NSDictionary *r=Live(t,@[bad],s,40);
        Check([r[@"held"] boolValue] && EqualPoints(First(r)[@"points76"],good[@"points76"],1e-12),[NSString stringWithFormat:@"malformed case %lu holds the last accepted complete shape",(unsigned long)i]);
        PGRealtimeFaceTracker *cold=[PGRealtimeFaceTracker new];NSDictionary *initial=Live(cold,@[bad],s,0);
        Check([First(initial)[@"points76"] count]==0,[NSString stringWithFormat:@"cold malformed case %lu never invents topology",(unsigned long)i]);
    }
    for(NSNumber *fps in @[@25,@30,@60,@120]){
        PGRealtimeFaceTracker *t=[PGRealtimeFaceTracker new];Live(t,@[good],s,0);NSDictionary *next=PGTrackingTestGeometry(box,.002);
        NSDictionary *r=[t resultForGeometry:@[next] settings:s time:CMTimeMake(1,fps.intValue) extent:CGRectMake(0,0,256,256)];
        Check(![r[@"held"] boolValue] && EqualPoints(First(r)[@"points76"],next[@"points76"],0),[NSString stringWithFormat:@"accepted %ldfps points are copied exactly without legacy temporal blending",(long)fps.integerValue]);
    }
    PGRealtimeFaceTracker *t=[PGRealtimeFaceTracker new];Live(t,@[good],s,0);NSDictionary *middle=Live(t,@[Without76(good)],s,40),*back=Live(t,@[good],s,80);
    Check([middle[@"held"] boolValue] && [First(middle)[@"points76"] count]==76 && EqualPoints(First(back)[@"points76"],good[@"points76"],0),@"76 to missing76 to76 never disables the geometric field");
    NSDictionary *jumpy=PGTrackingTestGeometry(box,.34);
    Check(PGGeometryQualityReason(jumpy).length==0,@"large coherent local jump remains structurally valid before temporal compatibility checks");
    PGRealtimeFaceTracker *jump=[PGRealtimeFaceTracker new];Live(jump,@[good],s,0);NSDictionary *rejected=Live(jump,@[jumpy],s,40);
    Check([rejected[@"held"] boolValue] && EqualPoints(First(rejected)[@"points76"],good[@"points76"],1e-12),@"a large finite median jump cannot poison accepted shape memory");
    NSDictionary *axisReverse=WithPoints(good,^(NSMutableArray *p){for(NSUInteger i=66;i<=68;i++)p[i]=@[p[i][0],@(2*CGRectGetMidY(box)-[p[i][1] doubleValue])];});
    Check(PGGeometryAxisFlip(axisReverse,good),@"weighted lower-contour to bbox-center axis detects a vertical sign reversal");
    NSMutableDictionary *eyeReverse=[good mutableCopy];eyeReverse[@"leftEye"]=good[@"rightEye"];eyeReverse[@"rightEye"]=good[@"leftEye"];
    Check(!PGGeometryAxisFlip(eyeReverse,good),@"an isolated eye-order change is not the recovered lower-contour axis test");
    NSDictionary *fewOutliers=WithPoints(good,^(NSMutableArray *p){for(NSUInteger i=0;i<6;i++)p[i]=@[@([p[i][0] doubleValue]+.55),p[i][1]];});
    NSDictionary *manyOutliers=WithPoints(good,^(NSMutableArray *p){for(NSUInteger i=0;i<12;i++)p[i]=@[@([p[i][0] doubleValue]+.55),p[i][1]];});
    Check(PGGeometryTransitionReason(fewOutliers,good).length==0,@"the temporal quantile gate does not treat a few outliers as a large median or P90 jump");
    Check(PGGeometryTransitionReason(manyOutliers,good).length>0,@"P90 rejects a substantial outlier group even when the median remains zero");
}

static void SequenceAndCache(void){
    PGBeautySettings s=PGBeautyDefaults();s.faceThin=1;CGRect box=CGRectMake(.15,.12,.70,.78);
    NSDictionary *good=PGTrackingTestGeometry(box,0),*changed=PGTrackingTestGeometry(box,.003);CIImage *image=[[CIImage imageWithColor:[CIColor colorWithRed:.5 green:.5 blue:.5]] imageByCroppingToRect:CGRectMake(0,0,256,256)];
    PGScriptedTracker *t=[PGScriptedTracker new];NSDictionary *first=[t resultForGeometry:@[good] settings:s time:kCMTimeZero extent:image.extent image:image];
    Check(t.seedCalls>0,@"first accepted face seeds the continuous object-box tracker");
    CGRect tracked=CGRectMake(.17,.13,.66,.74);t.proposedBox=tracked;
    NSDictionary *hold=[t resultForGeometry:@[Without76(good)] settings:s time:CMTimeMake(1,25) extent:image.extent image:image];
    Check(t.followCalls>0 && [hold[@"held"] boolValue],@"a partial detection asks the continuous sequence tracker for a box");
    Check(CGRectEqualToRect(PGArrayRect(First(hold)[@"box"]),tracked) && EqualPoints(First(hold)[@"points76"],MappedPoints(good,tracked),1e-12),@"held complete points follow the tracked box with exact affine remapping");
    NSUInteger calls=t.followCalls+t.seedCalls;
    NSDictionary *repeat=[t resultForGeometry:@[changed] settings:s time:CMTimeMake(2,50) extent:image.extent image:image];
    Check([repeat isEqual:hold] && t.followCalls+t.seedCalls==calls,@"same rational frame freezes its output and does not advance Vision again when raw changes");
    t.proposedBox=CGRectNull;NSDictionary *reacquired=[t resultForGeometry:@[changed] settings:s time:CMTimeMake(2,25) extent:image.extent image:image];
    Check(![reacquired[@"held"] boolValue] && EqualPoints(First(reacquired)[@"points76"],changed[@"points76"],0),@"a good reacquired detection replaces held shape exactly");
    NSDictionary *miss=Live(t,@[],s,120);Check([miss[@"held"] boolValue] && [First(miss)[@"points76"] count]==76,@"nearby complete detection loss preserves complete accepted geometry");
    PGRealtimeFaceTracker *cold=[PGRealtimeFaceTracker new];NSDictionary *empty=Live(cold,@[],s,40);Live(cold,@[good],s,0);
    Check([empty isEqual:Live(cold,@[changed],s,40)],@"same-frame freeze is stable when an earlier request arrives later");
    PGRealtimeFaceTracker *past=[PGRealtimeFaceTracker new];Live(past,@[good],s,1000);NSDictionary *rewind=Live(past,@[],s,960);
    Check([rewind[@"output"] count]==0,@"uncached reverse request cannot inherit a future accepted face");
    PGRealtimeFaceTracker *scope=[PGRealtimeFaceTracker new];Live(scope,@[good],s,0);
    Check([[scope resultForGeometry:@[] settings:s time:CMTimeMakeWithEpoch(40,1000,9) extent:image.extent][@"output"] count]==0,@"CMTime epoch changes isolate accepted geometry");
    Check([[scope resultForGeometry:@[] settings:s time:CMTimeMake(40,1000) extent:CGRectMake(10,0,256,256)][@"output"] count]==0,@"image origin changes isolate accepted geometry");
    PGBeautySettings multi=s;multi.fastMultiFace=1;NSDictionary *many=Live(scope,@[good,Without76(changed)],multi,40);
    Check([many[@"output"] count]==2,@"fast-multi retains its independent legacy raw-geometry contract");
    Check([Live(scope,@[],multi,80)[@"output"] count]==0,@"fast-multi cannot inherit the default primary-face hold");
    NSDictionary *defaultAgain=Live(scope,@[],s,80);Check([First(defaultAgain)[@"points76"] count]==76,@"fast-multi requests do not overwrite default accepted memory");
    [scope reset];Check([Live(scope,@[],s,120)[@"output"] count]==0,@"reset removes both output history and accepted shape state");
    Check(EqualPoints(First(first)[@"points76"],good[@"points76"],0),@"the first sequence frame preserves every authored point");
}

// Exercise the real VNSequenceRequestHandler/VNTrackObjectRequest on a textured
// synthetic rectangle. This verifies API wiring; it is not portrait accuracy or
// target parity. No face detector or media file is required.
static CIImage *ObjectFrame(NSUInteger frame){
    NSMutableData *d=[NSMutableData dataWithLength:256*256*4];uint8_t *p=d.mutableBytes;NSInteger dx=(NSInteger)frame*2;
    for(NSInteger y=0;y<256;y++)for(NSInteger x=0;x<256;x++){
        NSUInteger i=4*(y*256+x);NSInteger u=x-76-dx,v=y-51;BOOL inside=u>=0&&u<90&&v>=0&&v<128;
        uint8_t texture=inside?(uint8_t)(35+(u*37+v*53+((u/7+v/9)%2)*83)%210):8;
        p[i]=texture;p[i+1]=inside?(uint8_t)(50+(u*17+v*13)%180):12;p[i+2]=inside?(uint8_t)(40+(u*11+v*29)%200):16;p[i+3]=255;
    }
    return[CIImage imageWithBitmapData:d bytesPerRow:1024 size:CGSizeMake(256,256) format:kCIFormatRGBA8 colorSpace:NULL];
}
static double MaskPeak(CIContext *context,CIImage *image){
    CGRect extent=image.extent;NSUInteger width=extent.size.width,height=extent.size.height;
    NSMutableData *d=[NSMutableData dataWithLength:width*height*4*sizeof(float)];
    [context render:image toBitmap:d.mutableBytes rowBytes:width*4*sizeof(float) bounds:extent format:kCIFormatRGBAf colorSpace:NULL];
    const float *p=d.bytes;double peak=0;for(NSUInteger i=0;i<width*height;i++)peak=MAX(peak,p[4*i]);return peak;
}
static void DetectionCacheAndHeldMasks(void){
    CIImage *image=ObjectFrame(0);PGBeautySettings s=PGBeautyDefaults();PGCountingDetector *p=[PGCountingDetector new];
    VNFaceObservation *face=[VNFaceObservation faceObservationWithRequestRevision:VNDetectFaceLandmarksRequestRevision3 boundingBox:CGRectMake(.15,.12,.7,.78) roll:nil yaw:nil pitch:nil];
    p.suppliedFaces=@[face];NSArray *first=[p cachedObservationsInImage:image settings:s time:CMTimeMake(1,25) error:nil];p.suppliedFaces=@[];
    NSArray *again=[p cachedObservationsInImage:image settings:s time:CMTimeMake(2,50) error:nil];
    Check(first.count==1 && [again isEqual:first] && p.calls==1,@"equivalent same-frame requests reuse detection before running Vision again");
    s.faceThin=1;Check([[p cachedObservationsInImage:image settings:s time:CMTimeMake(1,25) error:nil] isEqual:first] && p.calls==1,@"shape parameter redraws do not invalidate same-frame face detection");
    NSArray *empty=[p cachedObservationsInImage:image settings:s time:CMTimeMake(2,25) error:nil];p.suppliedFaces=@[face];
    Check(empty.count==0 && [[p cachedObservationsInImage:image settings:s time:CMTimeMake(2,25) error:nil] count]==0 && p.calls==2,@"successful empty detection is frozen for redraws rather than toggling appearance");
    [p cachedObservationsInImage:image settings:s time:CMTimeMakeWithEpoch(2,25,8) error:nil];Check(p.calls==3,@"detection cache distinguishes CMTime epochs");
    CIImage *offset=[image imageByApplyingTransform:CGAffineTransformMakeTranslation(10,20)];[p cachedObservationsInImage:offset settings:s time:CMTimeMake(2,25) error:nil];
    Check(p.calls==4,@"detection cache distinguishes source extent origin");
    s.fastMultiFace=1;[p cachedObservationsInImage:image settings:s time:CMTimeMake(2,25) error:nil];Check(p.calls==5,@"different detection-resolution modes cannot share cached observations");
    [p resetTracking];[p cachedObservationsInImage:image settings:s time:CMTimeMake(2,25) error:nil];Check(p.calls==6,@"reset also clears observation cache entries");
    PGCountingDetector *retry=[PGCountingDetector new];retry.fail=YES;Check([retry cachedObservationsInImage:image settings:s time:kCMTimeZero error:nil]==nil,@"transient detector error remains an error rather than a successful empty result");
    retry.fail=NO;retry.suppliedFaces=@[face];Check([[retry cachedObservationsInImage:image settings:s time:kCMTimeZero error:nil] count]==1 && retry.calls==2,@"failed detections remain retryable at the exact same frame");
    PGCountingDetector *bounded=[PGCountingDetector new];for(NSUInteger i=0;i<160;i++)[bounded cachedObservationsInImage:image settings:s time:CMTimeMake(i,25) error:nil];
    NSUInteger before=bounded.calls;[bounded cachedObservationsInImage:image settings:s time:CMTimeMake(159,25) error:nil];
    Check(bounded.calls==before,@"recent detection remains cached after a long authored sequence");
    [bounded cachedObservationsInImage:image settings:s time:kCMTimeZero error:nil];Check(bounded.calls==before+1,@"observation history is bounded and old frames can be recomputed");
    // Inject only the tracker output to exercise processImage's real held-mask
    // integration. The detector reports no person; all geometry is authored.
    PGCountingDetector *maskProcessor=[PGCountingDetector new];PGScriptedOutputTracker *held=[PGScriptedOutputTracker new];
    NSDictionary *g=PGTrackingTestGeometry(CGRectMake(.15,.12,.7,.78),0);held.scriptedOutput=@{@"output":@[g],@"held":@YES,@"index":@(-1)};
    [maskProcessor setValue:held forKey:@"realtime"];s=PGBeautyDefaults();s.faceThin=1;
    PGFaceFrame *frame=[maskProcessor processImage:image settings:s time:kCMTimeZero error:nil];
    CIContext *context=[CIContext contextWithOptions:nil];float colorPixel[4]={0},skinPixel[4]={0};CGRect cheek=CGRectMake(88,130,1,1);
    [context render:frame.colorMask toBitmap:colorPixel rowBytes:sizeof(colorPixel) bounds:cheek format:kCIFormatRGBAf colorSpace:NULL];
    [context render:frame.skinMask toBitmap:skinPixel rowBytes:sizeof(skinPixel) bounds:cheek format:kCIFormatRGBAf colorSpace:NULL];
    Check(frame.deformationGeometry.count==1 && colorPixel[0]>.5 && skinPixel[0]>.25,@"default held geometry preserves skin and color support through complete detection loss");
    Check(MaskPeak(context,frame.teethMask)>.5 && MaskPeak(context,frame.eyeMask)>.5,@"held default geometry retains nonzero teeth and eye support after the shared warp");
    PGCountingDetector *errorProcessor=[PGCountingDetector new];PGScriptedTracker *objectTracker=[PGScriptedTracker new];
    [errorProcessor setValue:objectTracker forKey:@"realtime"];errorProcessor.suppliedFaces=(NSArray<VNFaceObservation *> *)@[AuthoredObservation(g)];
    PGFaceFrame *valid=[errorProcessor processImage:image settings:s time:kCMTimeZero error:nil];
    Check(valid.deformationGeometry.count==1 && [valid.deformationGeometry[0][@"points76"] count]==76,@"public-selector authored observations seed actual processImage accepted geometry");
    errorProcessor.fail=YES;objectTracker.proposedBox=PGArrayRect(g[@"box"]);NSError *stageError=nil;
    PGFaceFrame *failureHold=[errorProcessor processImage:image settings:s time:CMTimeMake(1,25) error:&stageError];
    Check(failureHold!=nil && failureHold.deformationGeometry.count==1 && [failureHold.deformationGeometry[0][@"points76"] count]==76,@"a realtime detector API error returns a frame with the last accepted complete shape");
    Check(failureHold!=nil && MaskPeak(context,failureHold.skinMask)>.5 && MaskPeak(context,failureHold.colorMask)>.5 && MaskPeak(context,failureHold.teethMask)>.5 && MaskPeak(context,failureHold.eyeMask)>.5,@"realtime detector errors keep all held beauty masks instead of flashing them off");
    NSDictionary *recovered=PGTrackingTestGeometry(PGArrayRect(g[@"box"]),.01);
    errorProcessor.fail=NO;errorProcessor.suppliedFaces=(NSArray<VNFaceObservation *> *)@[AuthoredObservation(recovered)];
    PGFaceFrame *sameTime=[errorProcessor processImage:image settings:s time:CMTimeMake(1,25) error:nil];
    Check(EqualPoints(sameTime.deformationGeometry.firstObject[@"points76"],recovered[@"points76"],1e-12),@"same-time recovery replaces a transient error hold instead of replaying its frozen geometry");
    PGCountingDetector *coldError=[PGCountingDetector new];coldError.fail=YES;
    [coldError processImage:image settings:s time:kCMTimeZero error:nil];coldError.fail=NO;
    coldError.suppliedFaces=(NSArray<VNFaceObservation *> *)@[AuthoredObservation(g)];
    PGFaceFrame *acquired=[coldError processImage:image settings:s time:kCMTimeZero error:nil];
    Check(acquired.deformationGeometry.count==1&&coldError.calls==2,@"a cold API failure cannot freeze the exact frame without geometry after a successful retry");
    errorProcessor.fail=YES;
    [[errorProcessor valueForKey:@"observationCache"] removeAllObjects];
    PGFaceFrame *cachedFailure=[errorProcessor processImage:image settings:s time:kCMTimeZero error:nil];
    Check(cachedFailure.deformationGeometry.count==1&&MaskPeak(context,cachedFailure.skinMask)>.5&&MaskPeak(context,cachedFailure.colorMask)>.5&&MaskPeak(context,cachedFailure.eyeMask)>.5&&MaskPeak(context,cachedFailure.teethMask)>.5,@"an API error after detection-cache eviction preserves masks even when geometry hits an older successful snapshot");
    PGBeautySettings offline=s;offline.trackingEnabled=1;stageError=nil;
    Check([errorProcessor processImage:image settings:offline time:CMTimeMake(2,25) error:&stageError]==nil && stageError!=nil,@"explicit offline tracking still reports detector errors rather than silently holding live geometry");
}
static void VisionSequence(void){
    PGRealtimeFaceTracker *t=[PGRealtimeFaceTracker new];CGRect seed=CGRectMake(76./256,51./256,90./256,128./256);
    CGRect start=[t trackedBoxForImage:ObjectFrame(0) time:kCMTimeZero seedBox:seed];Check(PGValidRect(start),@"real sequence tracker accepts an authored textured object seed");
    for(NSUInteger i=1;i<=5;i++){
        CGRect tracked=[t trackedBoxForImage:ObjectFrame(i) time:CMTimeMake(i,25) seedBox:CGRectNull];
        Check(PGValidRect(tracked) && fabs(CGRectGetMidX(tracked)-(CGRectGetMidX(seed)+2.*i/256))<.07 && fabs(CGRectGetMidY(tracked)-CGRectGetMidY(seed))<.07,@"real sequence tracker follows a known synthetic translation without losing the box");
        CGRect again=[t trackedBoxForImage:ObjectFrame(i) time:CMTimeMake(i,25) seedBox:CGRectNull];Check(CGRectEqualToRect(tracked,again),@"real sequence same-frame reuse does not advance tracking twice");
    }
    CGRect rewind=[t trackedBoxForImage:ObjectFrame(3) time:CMTimeMake(3,25) seedBox:CGRectNull];
    Check(!PGValidRect(rewind),@"a real sequence rewind cannot return a future tracked box without a fresh seed");
    CGRect reseed=CGRectOffset(seed,6./256,0);CGRect restarted=[t trackedBoxForImage:ObjectFrame(3) time:CMTimeMake(3,25) seedBox:reseed];
    Check(CGRectEqualToRect(reseed,restarted),@"a rewind with an explicit box restarts the real Vision sequence at that seed");
    PGRealtimeFaceTracker *gap=[PGRealtimeFaceTracker new];
    [gap trackedBoxForImage:ObjectFrame(0) time:kCMTimeZero seedBox:seed];
    Check(!PGValidRect([gap trackedBoxForImage:ObjectFrame(8) time:CMTimeMake(8,25) seedBox:CGRectNull]),@"a gap over .2 seconds invalidates an unseeded continuous object request");
    Check(CGRectEqualToRect([gap trackedBoxForImage:ObjectFrame(9) time:CMTimeMake(9,25) seedBox:CGRectNull],seed),@"after gap invalidation the next unseeded frame follows the recovered short lost-box hold path");
}
int main(void){@autoreleasepool{QualityAndAcceptance();SequenceAndCache();DetectionCacheAndHeldMasks();VisionSequence();printf("%s: %lu tracking sequence checks (%lu failures); synthetic data only\n",failures?"FAIL":"PASS",(unsigned long)checks,(unsigned long)failures);return failures?1:0;}}
