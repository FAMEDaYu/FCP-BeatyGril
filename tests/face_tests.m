#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
#import <Vision/Vision.h>
#import <ImageIO/ImageIO.h>
#import "PGFaceProcessor.h"
#import <dispatch/dispatch.h>
#include <math.h>
#import "tracking_fixture.h"

// Exercise the independent selector with authored landmark geometry, without
// requiring Vision to manufacture a particular jitter or invalid topology.
@interface PGRealtimeFaceTracker : NSObject
- (NSDictionary *)resultForGeometry:(NSArray<NSDictionary *> *)raw settings:(PGBeautySettings)settings time:(CMTime)time extent:(CGRect)extent;
- (NSDictionary *)cacheStatistics;
- (void)reset;
@end

// Injectable detections let geometry, selection and saved-frame behavior be
// tested independently of the separate public-domain NASA portrait fixture.
@interface PGFaceProcessor (TestDetection)
- (NSArray<VNFaceObservation *> *)observationsInImage:(CIImage *)image settings:(PGBeautySettings)settings error:(NSError **)error;
- (NSArray<VNFaceObservation *> *)cachedObservationsInImage:(CIImage *)image settings:(PGBeautySettings)settings time:(CMTime)time error:(NSError **)error;
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
// These tests change an injected detector result while reusing one tiny image.
// Keep that fixture boundary explicit; tracking_tests exercises the real frame
// detection cache separately, including same-time changed detector responses.
- (NSArray<VNFaceObservation *> *)cachedObservationsInImage:(CIImage *)image settings:(PGBeautySettings)settings time:(CMTime)time error:(NSError **)error {
    return [self observationsInImage:image settings:settings error:error];
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

static NSDictionary *Geometry(CGRect box,double jitter) {
    return PGTrackingTestGeometry(box,jitter);
}
static CGRect GeometryBox(NSDictionary *g) {
    NSArray *b=g[@"box"];return b.count==4?CGRectMake([b[0] doubleValue],[b[1] doubleValue],[b[2] doubleValue],[b[3] doubleValue]):CGRectZero;
}
static double EyeX(NSDictionary *g) {return [g[@"leftEye"][0][0] doubleValue];}
static BOOL SameCompleteShape(NSDictionary *a,NSDictionary *b) {
    NSArray *x=a[@"points76"],*y=b[@"points76"];if(x.count!=76||y.count!=76)return NO;
    for(NSUInteger i=0;i<76;i++)for(NSUInteger j=0;j<2;j++)if(fabs([x[i][j] doubleValue]-[y[i][j] doubleValue])>1e-12)return NO;
    return YES;
}
static NSDictionary *Live(PGRealtimeFaceTracker *tracker,NSArray *g,PGBeautySettings s,int64_t tick) {
    return [tracker resultForGeometry:g settings:s time:CMTimeMake(tick,1000) extent:CGRectMake(0,0,128,128)];
}
static void RealtimeChecks(CIContext *context,CIImage *image) {
    NSError *error=nil;PGBeautySettings s=PGBeautyDefaults();
    VNFaceObservation *left=Face(CGRectMake(.10,.25,.30,.50));
    VNFaceObservation *right=Face(CGRectMake(.66,.30,.20,.40));
    PGFaceFixture *p=[PGFaceFixture new];p.detections=@[left,right];
    s.faceSmallHead=.8;
    PGFaceFrame *automatic=[p processImage:image settings:s time:kCMTimeZero error:&error];
    Check(automatic.deformationGeometry.count==0,@"bbox-only fixture cannot seed default deformation without complete valid landmarks");
    Check(automatic.faces.count==2 && automatic.faces[0]==left && automatic.faces[1]==right,@"default appearance retains both original Vision observations");
    Check(Channel(context,automatic.teethMask,97,51,0)>20 && Channel(context,automatic.eyeMask,92,69,0)>20,@"default teeth and eye support covers the non-primary face");
    CGRect rightCrop=CGRectMake(84,38,30,52);
    Check([Pixels(context,[automatic.image imageByCroppingToRect:rightCrop]) isEqualToData:Pixels(context,[image imageByCroppingToRect:rightCrop])],@"default deformation leaves the distant secondary face unchanged");
    PGBeautySettings multi=s;multi.fastMultiFace=1;multi.singleFace=1;
    PGFaceFrame *many=[p processImage:image settings:multi time:kCMTimeZero error:&error];
    Check(many.deformationGeometry.count==2 && many.faces.count==2,@"fast-multi takes precedence over a stale single-face flag");
    Check(![Pixels(context,[many.image imageByCroppingToRect:rightCrop]) isEqualToData:Pixels(context,[image imageByCroppingToRect:rightCrop])],@"fast-multi visibly deforms the secondary face");
    Check([p trackingDataForTarget:0]==nil && [p trackingDataForTarget:1]==nil && [p trackingDataForTarget:2]==nil,@"realtime processing never creates persisted analysis records");
    p.detections=@[Face(CGRectMake(.15,.25,.30,.50)),Face(CGRectMake(.43,.005,.56,.99))];
    PGFaceFrame *moving=[p processImage:image settings:s time:CMTimeMake(1,25) error:&error];
    Check(moving.deformationGeometry.count==0 && moving.faces.count==2,@"successive bbox-only observations retain appearance coverage without inventing a shape");
    PGFaceFixture *cold=[PGFaceFixture new];cold.detections=p.detections;
    PGFaceFrame *coldFrame=[cold processImage:image settings:s time:CMTimeMake(1,25) error:&error];
    Check(coldFrame.deformationGeometry.count==0,@"cold initialization also rejects otherwise valid boxes with missing topology");

    PGRealtimeFaceTracker *t=[PGRealtimeFaceTracker new];
    NSDictionary *a=Geometry(CGRectMake(.1,.25,.3,.5),0),*b=Geometry(CGRectMake(.66,.3,.2,.4),0);
    NSDictionary *r=Live(t,@[a,b],s,0);
    Check([r[@"output"] count]==1 && [r[@"index"] integerValue]==0,@"standalone default selector chooses the scored primary");
    PGBeautySettings ignoredSeed=s;ignoredSeed.selectionX=.9;ignoredSeed.selectionY=.1;
    Check([r isEqual:Live(t,@[a,b],ignoredSeed,0)],@"seed changes are irrelevant while explicit single-face selection is disabled");
    NSDictionary *aMoved=Geometry(CGRectMake(.15,.25,.3,.5),0),*large=Geometry(CGRectMake(.43,.005,.56,.99),0);
    r=Live(t,@[aMoved,large],s,40);
    Check([r[@"index"] integerValue]==0 && [r[@"referenceKey"] isEqual:@"0/1/0"],@"live association uses the previous frame rather than recomputing the primary score");
    NSDictionary *outside=Geometry(CGRectMake(.60,.30,.10,.10),0);
    r=Live(t,@[outside],s,80);
    Check([r[@"held"] boolValue] && SameCompleteShape(r[@"output"][0],aMoved),@"no guard candidate retains the previous accepted geometry at full strength");
    r=Live(t,@[],s,120);
    Check([r[@"held"] boolValue] && [r[@"referenceKey"] isEqual:@"2/25/0"],@"empty detections hold geometry while advancing output time");
    for(int64_t tick=160;tick<=2160;tick+=40)r=Live(t,@[],s,tick);
    Check([r[@"held"] boolValue] && [r[@"output"] count]==1,@"continuous close held frames can retain geometry beyond .35 seconds");
    r=Live(t,@[],s,3000);
    Check([r[@"held"] boolValue] && [r[@"acceptedKey"] isEqual:@"1/25/0"],@"forward holds retain the last accepted detection time separately from output time");
    [t reset];r=Live(t,@[],s,3000);
    Check([r[@"output"] count]==0 && [r[@"referenceKey"] length]==0,@"an explicit reset clears held geometry even at a previously rendered time");
    r=Live(t,@[b],s,4000);
    Check(![r[@"held"] boolValue] && [r[@"index"] integerValue]==0,@"a far seek with a current face cold-acquires that face");

    // Rectangular guard includes a diagonal candidate that a small circular
    // center threshold would reject, and excludes a point just over an edge.
    PGRealtimeFaceTracker *guard=[PGRealtimeFaceTracker new];
    PGBeautySettings guardSettings=s;guardSettings.faceJumpGuardRange=1.8;
    NSDictionary *square=Geometry(CGRectMake(.4,.4,.2,.2),0);
    Live(guard,@[square],guardSettings,0);
    NSDictionary *diagonal=Geometry(CGRectMake(.625,.625,.1,.1),0);
    r=Live(guard,@[diagonal],guardSettings,40);
    Check(![r[@"held"] boolValue] && [r[@"index"] integerValue]==0,@"expanded rectangular guard accepts a candidate near both positive corners");
    [guard reset];Live(guard,@[square],guardSettings,0);
    r=Live(guard,@[Geometry(CGRectMake(.631,.45,.1,.1),0)],guardSettings,40);
    Check([r[@"held"] boolValue],@"candidate just beyond a rectangular guard edge cannot replace the identity");

    PGRealtimeFaceTracker *smooth=[PGRealtimeFaceTracker new];
    CGRect box=CGRectMake(.2,.2,.4,.6);
    NSDictionary *g0=Geometry(box,0),*jitter=Geometry(box,.06);
    Live(smooth,@[g0],s,0);
    NSDictionary *smoothed=Live(smooth,@[jitter],s,10);
    Check(fabs(EyeX(smoothed[@"output"][0])-EyeX(jitter))<1e-9,@"pin-style accepts a qualified current shape without arbitrary temporal blending");
    Check([smoothed[@"output"][0][@"points76"] isEqual:jitter[@"points76"]],@"all accepted indexed points remain exactly current rather than partially blended");
    Check([smoothed isEqual:Live(smooth,@[jitter],s,10)] && [[smooth cacheStatistics][@"frames"] unsignedIntegerValue]==2,@"same exact frame returns an identical frozen result without another tracking step");
    NSDictionary *equivalent=[smooth resultForGeometry:@[jitter] settings:s time:CMTimeMake(1,100) extent:CGRectMake(0,0,128,128)];
    Check([equivalent isEqual:smoothed],@"equivalent rational CMTime representations share one realtime result");
    NSDictionary *changed=Geometry(box,.08);
    NSDictionary *refreshed=Live(smooth,@[changed],s,10);
    Check([refreshed isEqual:smoothed],@"same-frame changed raw observations reuse the previously committed output");
    NSMutableDictionary *partial=[changed mutableCopy];[partial removeObjectForKey:@"points76"];
    NSDictionary *heldShape=Live(smooth,@[partial],s,20);
    Check([heldShape[@"held"] boolValue] && SameCompleteShape(heldShape[@"output"][0],smoothed[@"output"][0]),@"partial topology preserves the last accepted complete shape");
    NSDictionary *translated=Geometry(CGRectOffset(box,.1,0),.08);
    NSDictionary *translatedResult=Live(smooth,@[translated],s,60);
    Check(fabs(GeometryBox(translatedResult[@"output"][0]).origin.x-.3)<1e-9,@"normal translation uses the current detection box without accumulated box lag");
    Check([translatedResult[@"output"][0][@"points76"] isEqual:translated[@"points76"]],@"qualified translating reacquisition adopts the current complete shape exactly");
    Check([smoothed[@"output"] isEqual:Live(smooth,@[jitter],s,10)[@"output"]],@"repeated rewind to a cached time reproduces its original stable geometry");

    PGRealtimeFaceTracker *seeds=[PGRealtimeFaceTracker new];
    PGBeautySettings selected=s;selected.singleFace=1;selected.selectionX=.25;selected.selectionY=.5;
    Live(seeds,@[a,b],selected,0);
    selected.selectionX=.255;r=Live(seeds,@[],selected,40);
    Check([r[@"held"] boolValue],@"sub-.01 seed movement retains the existing identity");
    selected.selectionX=.27;r=Live(seeds,@[],selected,80);
    Check([r[@"output"] count]==0 && ![r[@"held"] boolValue],@"seed change over .01 starts a new identity and does not inherit an old held target");
    selected.selectionX=.78;r=Live(seeds,@[a,b],selected,80);
    Check([r[@"index"] integerValue]==1,@"large manual reselection immediately chooses the new seed target");
    NSDictionary *bMoved=Geometry(CGRectMake(.50,.30,.2,.4),0);
    r=Live(seeds,@[a,bMoved],selected,120);
    Check([r[@"index"] integerValue]==1,@"manually seeded target follows a near moving face");
    NSDictionary *bContinued=Geometry(CGRectMake(.45,.3,.2,.4),0),*seedStranger=Geometry(CGRectMake(.8,.3,.15,.4),0);
    r=Live(seeds,@[a,bContinued,seedStranger],selected,160);
    Check([r[@"index"] integerValue]==1,@"following does not repeatedly select the person nearest the fixed original click");

    PGRealtimeFaceTracker *reseedRewind=[PGRealtimeFaceTracker new];
    PGBeautySettings seedA=s;seedA.singleFace=1;seedA.selectionX=.2;seedA.selectionY=.5;
    for(int64_t i=0;i<=20;i++) {
        NSDictionary *movingFace=Geometry(CGRectMake(.15+.02*i,.3,.1,.4),0);
        Live(reseedRewind,@[movingFace],seedA,i*40);
    }
    NSArray *rewindFaces=@[Geometry(CGRectMake(.15,.3,.1,.4),0),Geometry(CGRectMake(.55,.3,.1,.4),0),Geometry(CGRectMake(.75,.3,.1,.4),0)];
    NSDictionary *beforeReselect=Live(reseedRewind,rewindFaces,seedA,840);
    PGBeautySettings seedB=seedA;seedB.selectionX=.8;Live(reseedRewind,rewindFaces,seedB,900);
    Live(reseedRewind,rewindFaces,seedA,1000);
    Check([beforeReselect isEqual:Live(reseedRewind,rewindFaces,seedA,840)],@"A-to-B-to-A reselection does not let the future A scope replace an earlier A exact result");

    PGRealtimeFaceTracker *order=[PGRealtimeFaceTracker new];
    NSDictionary *future=Live(order,@[b],s,1000);
    NSDictionary *past=Live(order,@[a],s,0);
    Check([past[@"referenceKey"] length]==0 && [past[@"output"][0] isEqual:a],@"uncached rewind never borrows geometry from a future frame");
    r=Live(order,@[Geometry(CGRectMake(.64,.3,.2,.4),0)],s,1040);
    Check([r[@"referenceKey"] isEqual:past[@"key"]],@"an uncached rewind starts a new forward reference instead of borrowing a cached future head");
    NSDictionary *nearRewind=Live(order,@[a],s,980);
    Check([nearRewind[@"referenceKey"] length]==0,@"uncached small rewind also refuses a closer future reference");
    NSDictionary *epoch=[order resultForGeometry:@[] settings:s time:CMTimeMakeWithEpoch(1080,1000,9) extent:CGRectMake(0,0,128,128)];
    Check([epoch[@"output"] count]==0,@"CMTime epochs isolate realtime identity caches");
    NSDictionary *extent=[order resultForGeometry:@[] settings:s time:CMTimeMake(1080,1000) extent:CGRectMake(20,30,256,128)];
    Check([extent[@"output"] count]==0,@"source extent size and origin changes isolate realtime geometry");
    PGBeautySettings target=s;target.targetIndex=1;r=Live(order,@[],target,1080);
    Check([r[@"output"] count]==0,@"target changes cannot reuse another target's realtime geometry");
    PGBeautySettings fast=s;fast.fastMultiFace=1;r=Live(order,@[a,b],fast,1080);
    Check([r[@"output"] count]==2 && [r[@"referenceKey"] length]==0,@"fast-multi mode has a separate geometry context");
    r=Live(order,@[],fast,1120);Check([r[@"output"] count]==0,@"fast-multi does not inherit primary hold behavior");
    Check([future isEqual:Live(order,@[b],s,1000)],@"same-time historical exact result remains stable after other contexts and seeks");

    // Parallel calls may have cold/warm identity differences, but each must be
    // data safe, reject future references, and freeze exact repeated requests.
    PGRealtimeFaceTracker *parallel=[PGRealtimeFaceTracker new];
    dispatch_apply(40,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^(size_t i) {
        @autoreleasepool {Live(parallel,@[a],s,(int64_t)i*40);}
    });
    BOOL pastOnly=YES,exact=YES;
    for(int64_t i=0;i<40;i++) {
        NSDictionary *first=Live(parallel,@[a],s,i*40),*again=Live(parallel,@[a],s,i*40);
        exact=exact&&[first isEqual:again];
        NSString *reference=first[@"referenceKey"];
        if(reference.length) {NSArray *parts=[reference componentsSeparatedByString:@"/"];pastOnly=pastOnly&&[parts[0] doubleValue]/[parts[1] doubleValue] <= i*.04;}
    }
    Check(pastOnly && exact,@"parallel result cache is safe and repeated requests retain past-only references");
    PGRealtimeFaceTracker *bounded=[PGRealtimeFaceTracker new];
    for(int64_t i=0;i<1210;i++) {@autoreleasepool {Live(bounded,@[],s,i*40);}}
    NSDictionary *stats=[bounded cacheStatistics];
    Check([stats[@"frames"] unsignedIntegerValue]==1200 && [stats[@"estimatedBytes"] unsignedIntegerValue]<=16*1024*1024,@"realtime geometry cache enforces frame and serialized-size bounds");
    [bounded reset];Check([[bounded cacheStatistics][@"frames"] unsignedIntegerValue]==0,@"realtime reset releases cached geometry");
    NSData *before=[p trackingDataForTarget:0];
    PGBeautySettings offline=s;offline.singleFace=1;offline.trackingEnabled=1;offline.selectionX=.25;offline.selectionY=.5;
    p.detections=@[left];Check([p analyzeImage:image settings:offline time:kCMTimeZero error:&error],@"offline analysis remains available beside live history");
    NSData *archive=[p trackingDataForTarget:0];
    p.detections=@[];[p processImage:image settings:s time:CMTimeMake(3,25) error:&error];
    Check(before==nil && [archive isEqual:[p trackingDataForTarget:0]],@"subsequent realtime hold does not mutate persisted offline geometry");
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
        Check([Pixels(context,frame.colorMask) isEqualToData:Pixels(context,withoutProtection.colorMask)], @"color support remains continuous when detail protection is toggled");
        Check(Channel(context,frame.colorMask,23,71,0)>Channel(context,frame.skinMask,23,71,0), @"color support retains coverage inside eye protection cutouts");

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
            BOOL changedPixels=![Pixels(context, warped.image) isEqualToData:base];
            Check(warped != nil && !changedPixels && warped.deformationGeometry.count==0,[NSString stringWithFormat:@"default pin-style rejects bbox-only topology for %@",names[i]]);
            changed.fastMultiFace=1;
            PGFaceFrame *legacyWarp=[processor processImage:image settings:changed time:kCMTimeZero error:&error];
            BOOL legacyChangedPixels=![Pixels(context,legacyWarp.image) isEqualToData:base];
            BOOL requiresPoints=(i==0 || i==2 || i==4 || i==5 || i==6);
            Check(legacyWarp != nil && (requiresPoints ? !legacyChangedPixels : legacyChangedPixels), requiresPoints ? @"fast-multi recovered thin/V/chin/short/jaw skip a face with no indexed landmarks" : [@"fast-multi preserves legacy bbox geometry control: " stringByAppendingString:names[i]]);
            Check(CGRectEqualToRect(warped.image.extent, image.extent), @"warp preserves image extent");
        }
        settings.faceShort = 0.8;
        NSData *positive = Pixels(context, [processor processImage:image settings:settings time:kCMTimeZero error:&error].image);
        settings.faceShort = -0.8;
        Check([positive isEqualToData:base] && [positive isEqualToData:Pixels(context, [processor processImage:image settings:settings time:kCMTimeZero error:&error].image)], @"both signed short-face values safely skip missing76; direction is tested with full geometry");
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
        RealtimeChecks(context,image);
        printf("Face processing: %lu checks passed\n", (unsigned long)PGChecks);
    }
    return 0;
}
