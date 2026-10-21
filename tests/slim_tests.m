#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
#import <Metal/Metal.h>
#import "PGFaceProcessor.h"
#include <math.h>

@interface PGFaceProcessor (SlimTest)
- (CIImage *)warpImage:(CIImage *)image geometry:(NSArray<NSDictionary *> *)geometry settings:(PGBeautySettings)s extent:(CGRect)extent;
@end
@interface PGRealtimeFaceTracker : NSObject
- (NSDictionary *)resultForGeometry:(NSArray *)raw settings:(PGBeautySettings)s time:(CMTime)time extent:(CGRect)extent;
@end
static NSUInteger checks=0;
static double maxOracleError=0;
static void Check(BOOL ok,NSString *message) {checks++;if(!ok){fprintf(stderr,"FAIL: %s\n",message.UTF8String);exit(1);}}
static double Clamp(double x,double a,double b) {return fmin(b,fmax(a,x));}
static CGPoint ReadPoint(NSArray *a) {return CGPointMake([a[0] doubleValue],[a[1] doubleValue]);}
static NSArray *WritePoint(CGPoint p) {return @[@(p.x),@(p.y)];}

// Authored 2D projections, with the documented 76-point layout. They are not
// extracted vendor assets or private face coordinates. Positive yaw projects
// the nose toward the right while the silhouette becomes narrower.
static NSDictionary *Geometry(double yaw,double roll) {
    NSMutableArray *p=[NSMutableArray new];
    for(NSUInteger i=0;i<76;i++)[p addObject:@[@.5,@.5]];
    p[6]=@[@.34,@.65];p[13]=@[@.66,@.65];
    p[47]=@[@.5,@.60];p[48]=@[@.5,@.52];p[49]=@[@.5,@.45];p[52]=@[@.5,@.42];
    for(NSUInteger i=0;i<17;i++) {
        double t=M_PI+M_PI*i/16;
        p[59+i]=@[@(.5+.29*cos(t)),@(.65+.43*sin(t))];
    }
    for(NSUInteger i=0;i<76;i++) {
        CGPoint a=ReadPoint(p[i]);
        double depth=(i==47 || i==48 || i==49 || i==52)?.18:.03;
        double x=(a.x-.5)*cos(yaw)+depth*sin(yaw),y=a.y-.5;
        p[i]=WritePoint(CGPointMake(.5+x*cos(roll)-y*sin(roll),.5+x*sin(roll)+y*cos(roll)));
    }
    NSMutableDictionary *g=[NSMutableDictionary dictionaryWithDictionary:@{@"box":@[@.15,@.15,@.7,@.6],@"points76":p}];
    for(NSString *key in @[@"leftEye",@"rightEye",@"leftBrow",@"rightBrow",@"nose",@"lips",@"mouth",@"contour"])g[key]=@[];
    return g;
}

// Independent scalar oracle from the recorded AIR specification. Its explicit
// y-down conversion checks the Core Image implementation's coordinate bridge.
static CGPoint Oracle(CGPoint pixel,NSDictionary *g,CGRect extent,double thin) {
    static const unsigned int origins[17]={75,59,74,60,73,61,72,62,71,63,70,64,69,65,68,66,67};
    static const unsigned int anchors[17]={6,13,47,47,47,47,48,48,48,48,49,49,49,49,52,52,47};
    NSArray *raw=g[@"points76"];CGPoint p[76];
    for(NSUInteger i=0;i<76;i++){p[i]=ReadPoint(raw[i]);p[i].y=1-p[i].y;}
    double width=hypot((p[75].x-p[59].x)*extent.size.width,(p[75].y-p[59].y)*extent.size.height);
    double height=hypot((p[67].x-(p[74].x+p[60].x)/2)*extent.size.width,(p[67].y-(p[74].y+p[60].y)/2)*extent.size.height);
    double gain=Clamp(280/fmax(1,fmax(width,2*height)),1,2.25)*.025*Clamp(thin,0,1);
    CGPoint q=CGPointMake((pixel.x-extent.origin.x)/extent.size.width,1-(pixel.y-extent.origin.y)/extent.size.height);
    for(NSUInteger i=0;i<17;i++) {
        CGPoint a=p[origins[i]],b=p[anchors[i]];
        double r=hypot(a.x-b.x,a.y-b.y);
        if(r<=.0001)continue;
        double w=Clamp(1-hypot(q.x-a.x,q.y-a.y)/r,0,1);
        q.x=Clamp(q.x-(b.x-a.x)*gain*w,0,1);q.y=Clamp(q.y-(b.y-a.y)*gain*w,0,1);
    }
    return CGPointMake(q.x,1-q.y);
}
static CIImage *CoordinateImage(CGRect extent) {
    NSUInteger w=extent.size.width,h=extent.size.height;
    NSMutableData *d=[NSMutableData dataWithLength:w*h*4*sizeof(float)];float *p=d.mutableBytes;
    for(NSUInteger y=0;y<h;y++)for(NSUInteger x=0;x<w;x++) {
        NSUInteger k=(y*w+x)*4;p[k]=(x+.5)/w;p[k+1]=(y+.5)/h;p[k+2]=.25;p[k+3]=1;
    }
    return [[CIImage imageWithBitmapData:d bytesPerRow:w*4*sizeof(float) size:extent.size format:kCIFormatRGBAf colorSpace:nil]
            imageByApplyingTransform:CGAffineTransformMakeTranslation(extent.origin.x,extent.origin.y)];
}
static NSData *Pixels(CIContext *c,CIImage *image) {
    CGRect e=image.extent;NSUInteger w=e.size.width,h=e.size.height;
    NSMutableData *d=[NSMutableData dataWithLength:w*h*4*sizeof(float)];
    [c render:image toBitmap:d.mutableBytes rowBytes:w*4*sizeof(float) bounds:e format:kCIFormatRGBAf colorSpace:nil];return d;
}
static NSData *Archive(NSDictionary *geometry) {
    return [NSPropertyListSerialization dataWithPropertyList:@{@"version":@1,@"frames":@{@"0/1/0":@{@"value":@0,@"scale":@1,@"epoch":@0,@"faces":@[geometry]}}} format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
}
static void NumericCase(CIContext *c,PGFaceProcessor *p,CGRect e,NSDictionary *g,double amount,NSString *name) {
    PGBeautySettings s=PGBeautyDefaults();s.faceThin=amount;
    CIImage *input=CoordinateImage(e),*output=[p warpImage:input geometry:@[g] settings:s extent:e];
    Check(output!=nil && CGRectEqualToRect(output.extent,e),[name stringByAppendingString:@" preserves extent"]);
    NSData *data=Pixels(c,output);const float *pixels=data.bytes;double worst=0,maxMove=0;
    NSUInteger worstX=0,worstY=0;CGPoint worstExpected=CGPointZero,worstActual=CGPointZero;
    NSUInteger w=e.size.width,h=e.size.height;
    for(NSUInteger y=3;y<h-3;y+=7)for(NSUInteger x=3;x<w-3;x+=7) {
        // Bitmap rows are top first, while destCoord / geometry are y up.
        CGPoint q=Oracle(CGPointMake(e.origin.x+x+.5,e.origin.y+h-y-.5),g,e,amount);
        double ex=Clamp(q.x,.5/w,1-.5/w),ey=Clamp(1-q.y,.5/h,1-.5/h);
        NSUInteger k=(y*w+x)*4;
        double difference=fmax(fabs(pixels[k]-ex),fabs(pixels[k+1]-ey));
        if(difference>worst){worst=difference;worstX=x;worstY=y;worstExpected=CGPointMake(ex,ey);worstActual=CGPointMake(pixels[k],pixels[k+1]);}
        maxMove=fmax(maxMove,hypot(ex-(x+.5)/w,ey-(y+.5)/h));
    }
    if(worst>0.00006)fprintf(stderr,"%s oracle max error=%g at %lu,%lu expected=(%g,%g) actual=(%g,%g)\n",name.UTF8String,worst,(unsigned long)worstX,(unsigned long)worstY,worstExpected.x,worstExpected.y,worstActual.x,worstActual.y);
    maxOracleError=fmax(maxOracleError,worst);
    Check(worst<0.00006,[name stringByAppendingString:@" GPU inverse field matches independent 17-pin oracle"]);
    Check(amount==0 || maxMove>.0001,[name stringByAppendingString:@" exercises a nonzero displacement"]);
    NSUInteger corner=4*((h-3)*w+(w-3));
    Check(fabs(pixels[corner]-(w-2.5)/w)<1e-6 && fabs(pixels[corner+1]-(h-2.5)/h)<1e-6,[name stringByAppendingString:@" preserves distant background"]);
}

int main(int argc,const char *argv[]) {@autoreleasepool {
    CIContext *c=[CIContext contextWithMTLDevice:MTLCreateSystemDefaultDevice() options:@{kCIContextWorkingColorSpace:NSNull.null,kCIContextOutputColorSpace:NSNull.null}];
    PGFaceProcessor *p=[PGFaceProcessor new];
    CGRect extents[]={CGRectMake(0,0,240,240),CGRectMake(0,0,320,180),CGRectMake(-17,29,180,320),CGRectMake(0,0,640,360)};
    double yaw[]={0,.65,1.40,-1.40},roll[]={0,.45,-.50};
    NumericCase(c,p,extents[1],Geometry(0,0),0,@"zero strength");
    for(NSUInteger e=0;e<4;e++)for(NSUInteger y=0;y<4;y++)for(NSUInteger r=0;r<3;r++) {
        NSString *name=[NSString stringWithFormat:@"size%lu yaw%lu roll%lu",(unsigned long)e,(unsigned long)y,(unsigned long)r];
        NumericCase(c,p,extents[e],Geometry(yaw[y],roll[r]),1,name);
    }
    NumericCase(c,p,extents[1],Geometry(.6,.2),.5,@"half strength");
    CIImage *image=CoordinateImage(extents[1]);NSData *source=Pixels(c,image);
    PGBeautySettings s=PGBeautyDefaults();s.faceThin=1;s.trackingEnabled=1;NSError *error=nil;
    NSDictionary *g=Geometry(.9,.15);[p setTrackingData:Archive(g) forTarget:0];
    PGFaceFrame *frame=[p processImage:image settings:s time:kCMTimeZero error:&error];
    Check(frame!=nil && [frame.deformationGeometry[0][@"points76"] count]==76,@"offline restoration retains all 76 indexed points");
    PGFaceProcessor *restored=[PGFaceProcessor new];[restored setTrackingData:[p trackingDataForTarget:0] forTarget:0];
    Check([Pixels(c,[restored processImage:image settings:s time:kCMTimeZero error:&error].image) isEqualToData:Pixels(c,frame.image)],@"76-point geometry survives archive round trip with identical pixels");
    NSData *imageWarp=Pixels(c,[p warpImage:frame.colorMask geometry:@[] settings:s extent:image.extent]);
    Check(imageWarp.length==source.length,@"warped support masks retain dimensions");
    // Apply the same coordinate field to an independent scalar mask ramp.
    CIImage *mask=[image imageByApplyingFilter:@"CIColorMatrix" withInputParameters:@{@"inputRVector":[CIVector vectorWithX:1 Y:0 Z:0 W:0],@"inputGVector":[CIVector vectorWithX:1 Y:0 Z:0 W:0],@"inputBVector":[CIVector vectorWithX:1 Y:0 Z:0 W:0]}];
    NSData *maskData=Pixels(c,[p warpImage:mask geometry:@[g] settings:s extent:image.extent]),*frameData=Pixels(c,frame.image);
    const float *m=maskData.bytes,*v=frameData.bytes;
    BOOL masksAgree=YES;for(NSUInteger i=0;i<source.length/sizeof(float);i+=4)if(fabs(m[i]-v[i])>1e-6){masksAgree=NO;break;}
    Check(masksAgree,@"scalar support masks and RGB use the same source coordinates");
    for(NSUInteger mode=0;mode<4;mode++) {
        NSMutableDictionary *bad=[g mutableCopy];
        if(mode==0)[bad removeObjectForKey:@"points76"];
        if(mode==1)bad[@"points76"]=[g[@"points76"] subarrayWithRange:NSMakeRange(0,75)];
        if(mode==2){NSMutableArray *a=[g[@"points76"] mutableCopy];a[65]=@[@(NAN),@.5];bad[@"points76"]=a;}
        if(mode==3){NSMutableArray *a=[g[@"points76"] mutableCopy];a[65]=@[@9,@.5];bad[@"points76"]=a;}
        [p setTrackingData:Archive(bad) forTarget:0];frame=[p processImage:image settings:s time:kCMTimeZero error:&error];
        Check(frame!=nil && frame.deformationGeometry.count==1,@"legacy/malformed indexed points retain the valid face record");
        Check([Pixels(c,frame.image) isEqualToData:source],@"legacy/malformed indexed points never trigger a guessed symmetric thin warp");
        PGBeautySettings other=s;other.faceNarrow=.5;
        Check(![Pixels(c,[p processImage:image settings:other time:kCMTimeZero error:&error].image) isEqualToData:source],@"other controls remain available in legacy archives");
    }
    PGRealtimeFaceTracker *tracker=[PGRealtimeFaceTracker new];PGBeautySettings live=PGBeautyDefaults();
    NSDictionary *a=[tracker resultForGeometry:@[Geometry(0,0)] settings:live time:kCMTimeZero extent:image.extent];
    NSDictionary *b=[tracker resultForGeometry:@[Geometry(.2,0)] settings:live time:CMTimeMake(1,25) extent:image.extent];
    Check([a[@"output"][0][@"points76"] count]==76 && [b[@"output"][0][@"points76"] count]==76,@"realtime stabilization retains the complete indexed point layout");
    Check([b isEqual:[tracker resultForGeometry:@[Geometry(.2,0)] settings:live time:CMTimeMake(1,25) extent:image.extent]],@"repeated rendering does not smooth the 76-point layout again");
    NSDictionary *held=[tracker resultForGeometry:@[] settings:live time:CMTimeMake(2,25) extent:image.extent];
    Check([held[@"output"][0][@"points76"] isEqual:b[@"output"][0][@"points76"]],@"missing detection holds the complete point layout");
    NSDictionary *turned=Geometry(1.4,0);
    NSDictionary *back=[tracker resultForGeometry:@[turned] settings:live time:CMTimeMake(3,25) extent:image.extent];
    Check([back[@"output"][0][@"points76"] isEqual:turned[@"points76"]],@"reacquired side-face points do not blend with a held frontal pose");
    for(int index=1;index<argc;index++) {@autoreleasepool {
        CIImage *portrait=[CIImage imageWithContentsOfURL:[NSURL fileURLWithPath:@(argv[index])] options:@{kCIImageColorSpace:NSNull.null}];
        PGFaceProcessor *real=[PGFaceProcessor new];PGBeautySettings rs=PGBeautyDefaults();rs.faceThin=1;
        PGFaceFrame *f=[real processImage:portrait settings:rs time:kCMTimeZero error:&error];
        Check(f!=nil && f.faces.count>0 && [f.deformationGeometry[0][@"points76"] count]==76,@"real Vision detection supplies exactly 76 points to thin deformation");
        Check(![Pixels(c,f.image) isEqualToData:Pixels(c,portrait)],@"maximum thin changes a real detected portrait");
        Check([real analyzeImage:portrait settings:rs time:kCMTimeZero error:&error],@"real pose analysis saves the complete geometry");
        PGFaceProcessor *copy=[PGFaceProcessor new];[copy setTrackingData:[real trackingDataForTarget:0] forTarget:0];rs.trackingEnabled=1;
        Check([Pixels(c,[copy processImage:portrait settings:rs time:kCMTimeZero error:&error].image) isEqualToData:Pixels(c,f.image)],@"real pose replays from persisted 76 points with identical pixels");
    }}
    printf("PASS: %lu slim alignment checks; maximum UV oracle error %.9g\n",(unsigned long)checks,maxOracleError);return 0;
}}
