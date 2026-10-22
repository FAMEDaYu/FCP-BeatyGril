#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
#import "PGFaceProcessor.h"
#include <math.h>

@interface PGRealtimeFaceTracker : NSObject
- (NSDictionary *)resultForGeometry:(NSArray *)raw settings:(PGBeautySettings)s time:(CMTime)time extent:(CGRect)extent;
@end
@interface PGFaceProcessor (ProbeWarp)
- (CIImage *)warpImage:(CIImage *)image geometry:(NSArray *)geometry settings:(PGBeautySettings)s extent:(CGRect)extent;
- (NSArray<VNFaceObservation *> *)observationsInImage:(CIImage *)image settings:(PGBeautySettings)s error:(NSError **)error;
@end
@interface ProbeFaceProcessor : PGFaceProcessor
@property (nonatomic,copy) NSArray<VNFaceObservation *> *authoredDetections;
@end
@implementation ProbeFaceProcessor
- (NSArray<VNFaceObservation *> *)observationsInImage:(CIImage *)image settings:(PGBeautySettings)s error:(NSError **)error {return self.authoredDetections?:@[];}
@end

#import "../tests/tracking_fixture.h"
static NSDictionary *Geometry(CGRect box,double jitter,BOOL has76) {
    NSMutableDictionary *g=[PGTrackingTestGeometry(box,jitter) mutableCopy];
    if(!has76)[g removeObjectForKey:@"points76"];
    return g;
}
static NSDictionary *Live(PGRealtimeFaceTracker *t,NSArray *g,PGBeautySettings s,int64_t tick){return[t resultForGeometry:g settings:s time:CMTimeMake(tick,1000) extent:CGRectMake(0,0,256,256)];}
static double PointX(NSDictionary *r){return[r[@"output"][0][@"points76"][69][0] doubleValue];}
static NSData *Pixels(CIContext *context,CIImage *image){
    CGRect e=image.extent;NSUInteger w=e.size.width,h=e.size.height;NSMutableData *d=[NSMutableData dataWithLength:w*h*4*sizeof(float)];
    [context render:image toBitmap:d.mutableBytes rowBytes:w*4*sizeof(float) bounds:e format:kCIFormatRGBAf colorSpace:NULL];return d;
}
static NSDictionary *Difference(NSData *a,NSData *b){
    const float *x=a.bytes,*y=b.bytes;NSUInteger n=a.length/sizeof(float),changed=0;double maximum=0,sum=0;
    for(NSUInteger i=0;i<n;i++){double v=fabs(x[i]-y[i]);sum+=v;maximum=fmax(maximum,v);if(v>1e-6)changed++;}
    return@{@"maxChannelDifference":@(maximum),@"meanChannelDifference":@(sum/n),@"changedChannelsAbove1e_6":@(changed)};
}
static double MeanRed(CIContext *context,CIImage *image){NSData *d=Pixels(context,image);const float *p=d.bytes;NSUInteger n=d.length/(4*sizeof(float));double sum=0;for(NSUInteger i=0;i<n;i++)sum+=p[4*i];return sum/n;}
static CIImage *SyntheticPattern(void){
    NSMutableData *d=[NSMutableData dataWithLength:256*256*4*sizeof(float)];float *p=d.mutableBytes;
    for(NSUInteger y=0;y<256;y++)for(NSUInteger x=0;x<256;x++){NSUInteger i=4*(y*256+x);p[i]=x/255.;p[i+1]=y/255.;p[i+2]=((x/5+y/5)%2)*.9+.05;p[i+3]=1;}
    return[CIImage imageWithBitmapData:d bytesPerRow:256*4*sizeof(float) size:CGSizeMake(256,256) format:kCIFormatRGBAf colorSpace:NULL];
}
int main(void){@autoreleasepool{
    PGBeautySettings s=PGBeautyDefaults();s.faceThin=1;
    CGRect b=CGRectMake(.15,.15,.7,.65);NSDictionary *good=Geometry(b,0,YES),*missing=Geometry(b,0,NO);
    PGRealtimeFaceTracker *topology=[PGRealtimeFaceTracker new];NSMutableArray *counts=[NSMutableArray new],*held=[NSMutableArray new],*diffs=[NSMutableArray new];
    PGFaceProcessor *processor=[PGFaceProcessor new];CIContext *context=[CIContext contextWithOptions:nil];CIImage *image=SyntheticPattern();NSData *original=Pixels(context,image);
    NSArray *inputs=@[@[good],@[missing],@[good]];
    for(NSUInteger i=0;i<inputs.count;i++){
        NSDictionary *r=Live(topology,inputs[i],s,i*40);NSArray *output=r[@"output"];
        [counts addObject:@([output[0][@"points76"] count])];[held addObject:r[@"held"]];
        CIImage *warped=[processor warpImage:image geometry:output settings:s extent:image.extent];
        [diffs addObject:Difference(original,Pixels(context,warped))];
    }
    NSMutableArray *rawX=[NSMutableArray new],*outX=[NSMutableArray new];PGRealtimeFaceTracker *jitter=[PGRealtimeFaceTracker new];
    for(NSUInteger i=0;i<20;i++){
        double dx=(i%2?.004:-.004);CGRect moved=b;moved.origin.x+=dx;NSDictionary *g=Geometry(moved,0,YES),*r=Live(jitter,@[g],s,i*40);
        [rawX addObject:g[@"points76"][69][0]];[outX addObject:@(PointX(r))];
    }
    double rawAmplitude=0,outAmplitude=0,maxError=0;for(NSUInteger i=1;i<rawX.count;i++){rawAmplitude=fmax(rawAmplitude,fabs([rawX[i] doubleValue]-[rawX[i-1] doubleValue]));outAmplitude=fmax(outAmplitude,fabs([outX[i] doubleValue]-[outX[i-1] doubleValue]));maxError=fmax(maxError,fabs([rawX[i] doubleValue]-[outX[i] doubleValue]));}
    PGRealtimeFaceTracker *late=[PGRealtimeFaceTracker new];NSDictionary *lateFirst=Live(late,@[],s,40);Live(late,@[good],s,0);NSDictionary *lateReplay=Live(late,@[],s,40);
    PGRealtimeFaceTracker *ordered=[PGRealtimeFaceTracker new];Live(ordered,@[good],s,0);NSDictionary *ordered40=Live(ordered,@[],s,40);
    PGRealtimeFaceTracker *reacquired=[PGRealtimeFaceTracker new];Live(reacquired,@[good],s,0);Live(reacquired,@[],s,40);NSDictionary *shift=Geometry(b,.04,YES),*r80=Live(reacquired,@[shift],s,80);
    PGRealtimeFaceTracker *continuous=[PGRealtimeFaceTracker new];Live(continuous,@[good],s,0);NSDictionary *continuous80=Live(continuous,@[shift],s,80);
    NSMutableArray *weights=[NSMutableArray new];for(NSNumber *fps in @[@25,@30,@60,@120]){
        PGRealtimeFaceTracker *t=[PGRealtimeFaceTracker new];Live(t,@[good],s,0);
        NSDictionary *r=[t resultForGeometry:@[shift] settings:s time:CMTimeMake(1,fps.intValue) extent:CGRectMake(0,0,256,256)];
        double before=[good[@"points76"][69][0] doubleValue],after=[shift[@"points76"][69][0] doubleValue];
        [weights addObject:@{@"fps":fps,@"currentLandmarkWeight":@((PointX(r)-before)/(after-before))}];
    }
    ProbeFaceProcessor *drop=[ProbeFaceProcessor new];PGBeautySettings defaultSettings=PGBeautyDefaults();
    drop.authoredDetections=@[[VNFaceObservation faceObservationWithRequestRevision:VNDetectFaceLandmarksRequestRevision3 boundingBox:b roll:nil yaw:nil pitch:nil]];
    PGFaceFrame *detected=[drop processImage:image settings:defaultSettings time:kCMTimeZero error:nil];
    drop.authoredDetections=@[];PGFaceFrame *lost=[drop processImage:image settings:defaultSettings time:CMTimeMake(1,25) error:nil];
    PGRealtimeFaceTracker *crossing=[PGRealtimeFaceTracker new];NSDictionary *initialA=Geometry(CGRectMake(.2,.25,.25,.5),0,YES);
    Live(crossing,@[initialA],s,0);NSDictionary *movingA=Geometry(CGRectMake(.30,.25,.25,.5),.04,YES),*strangerB=Geometry(CGRectMake(.21,.25,.25,.5),-.04,YES);
    NSDictionary *crossed=Live(crossing,@[movingA,strangerB],s,40);
    NSDictionary *report=@{@"scope":@"Authored synthetic geometry and image only; actual current PGFaceProcessor implementation linked; no target binary or user media.",
        @"topologyValidMissingValid":@{@"points76Counts":counts,@"held":held,@"pixelDifferencesFromUnwarpedInput":diffs},
        @"pureBBoxTranslationJitter":@{@"frames":@20,@"fps":@25,@"rawStepNormalized":@(rawAmplitude),@"outputStepNormalized":@(outAmplitude),@"outputOverRawAmplitude":@(outAmplitude/rawAmplitude),@"maximumOutputVsRawPointError":@(maxError)},
        @"outOfOrderCachedMissingFrame":@{@"initial40OutputFaces":@([lateFirst[@"output"] count]),@"replay40AfterAdding0OutputFaces":@([lateReplay[@"output"] count]),@"ordered0Then40OutputFaces":@([ordered40[@"output"] count])},
        @"reacquisition":@{@"reacquiredPoint69x":@(PointX(r80)),@"rawPoint69x":shift[@"points76"][69][0],@"continuousPoint69x":@(PointX(continuous80))},
        @"defaultAppearanceOnDetectionLoss":@{@"geometryFacesBefore":@(detected.deformationGeometry.count),@"geometryFacesAfter":@(lost.deformationGeometry.count),@"meanColorMaskBefore":@(MeanRed(context,detected.colorMask)),@"meanColorMaskAfter":@(MeanRed(context,lost.colorMask)),@"meanSkinMaskBefore":@(MeanRed(context,detected.skinMask)),@"meanSkinMaskAfter":@(MeanRed(context,lost.skinMask))},
        @"authoredTwoFaceCrossing":@{@"rawIndex0":@"same authored identity A moved by .10",@"rawIndex1":@"different authored identity B moved within .01 of old center",@"selectedRawIndex":crossed[@"index"]},
        @"landmarkWeightsByFrameRate":weights};
    NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:nil];fwrite(json.bytes,1,json.length,stdout);fputc('\n',stdout);
}return 0;}
