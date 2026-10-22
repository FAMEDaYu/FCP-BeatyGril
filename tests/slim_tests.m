#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
#import <Metal/Metal.h>
#import <ImageIO/ImageIO.h>
#import "PGFaceProcessor.h"
#include <math.h>
#import "tracking_fixture.h"

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
    p[46]=@[@.5,@.68];p[47]=@[@.5,@.60];p[48]=@[@.5,@.52];p[49]=@[@.5,@.45];p[52]=@[@.5,@.42];
    p[29]=@[@.5,@.39];
    p[36]=@[@.54,@.36];p[37]=@[@.5,@.35];p[38]=@[@.46,@.36];
    p[26]=@[@.42,@.40];p[34]=@[@.58,@.40];p[35]=@[@.57,@.36];p[39]=@[@.43,@.36];
    for(NSUInteger i=0;i<17;i++) {
        double t=M_PI+M_PI*i/16;
        p[59+i]=@[@(.5+.29*cos(t)),@(.65+.43*sin(t))];
    }
    for(NSUInteger i=0;i<76;i++) {
        CGPoint a=ReadPoint(p[i]);
        double depth=(i==46 || i==47 || i==48 || i==49 || i==52)?.18:.03;
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
    double gain=.025*Clamp(thin,0,1); // 2.4.0 pin coefficient has no legacy size amplification.
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
static CGPoint ChinOracle(CGPoint pixel,NSDictionary *g,CGRect e,double thin,double chin) {
    CGPoint q=Oracle(pixel,g,e,thin);q.y=1-q.y;
    NSArray *raw=g[@"points76"];CGPoint points[76];
    for(NSUInteger i=0;i<76;i++){points[i]=ReadPoint(raw[i]);points[i].y=1-points[i].y;}
    double width=hypot((points[75].x-points[59].x)*e.size.width,(points[75].y-points[59].y)*e.size.height);
    double height=2*hypot((points[67].x-(points[74].x+points[60].x)/2)*e.size.width,(points[67].y-(points[74].y+points[60].y)/2)*e.size.height);
    double ratio=Clamp(chin,-1,1)*(chin>0?.04:.02)*Clamp(280/fmax(1,fmax(width,height)),1,2.25);
    for(NSUInteger i=0;i<3;i++) {
        CGPoint a=points[68-i],b=points[38-i];double r=hypot(a.x-b.x,a.y-b.y);
        if(r<=.0001)continue;
        double w=Clamp(1-hypot(q.x-a.x,q.y-a.y)/r,0,1);
        q.x=Clamp(q.x-(b.x-a.x)*ratio*w,0,1);q.y=Clamp(q.y-(b.y-a.y)*ratio*w,0,1);
    }
    return CGPointMake(q.x,1-q.y);
}

// Independent double-precision reconstruction of AIR's V, jaw and short-face
// branches. This does not call or inspect the production kernel/parameter table.
// Jaw's support uses the adjacent contour edge, not the much longer lip vector.
// Short-face uses a filled lower-contour polygon and its distance envelope.
static double ReferenceSizeGain(CGPoint p[76],CGRect e) {
    double span=hypot((p[75].x-p[59].x)*e.size.width,(p[75].y-p[59].y)*e.size.height);
    double vertical=2*hypot((p[67].x-(p[74].x+p[60].x)/2)*e.size.width,(p[67].y-(p[74].y+p[60].y)/2)*e.size.height);
    return Clamp(280/fmax(1,fmax(span,vertical)),1,2.25);
}
static CGPoint ReferencePoint(CGPoint p[76],NSUInteger index) {return CGPointMake(p[index].x,1-p[index].y);}
static double ReferencePolygonWeight(CGPoint q,CGPoint p[76]) {
    double radius=hypot(p[46].x-p[48].x,p[46].y-p[48].y);
    if(radius<=.0001)return 0;
    BOOL inside=NO;double minimum=10;
    for(NSUInteger i=0;i<11;i++){
        CGPoint a=ReferencePoint(p,62+i),b=ReferencePoint(p,62+(i+1)%11);
        if((a.y>q.y)!=(b.y>q.y)){
            double divisor=b.y-a.y;if(fabs(divisor)<=1e-6)divisor=divisor<0?-1e-6:1e-6;
            if(q.x<a.x+(q.y-a.y)*(b.x-a.x)/divisor)inside=!inside;
        }
        double dx=b.x-a.x,dy=b.y-a.y,squared=dx*dx+dy*dy;
        double t=squared>1e-6?Clamp(((q.x-a.x)*dx+(q.y-a.y)*dy)/squared,0,1):0;
        minimum=fmin(minimum,hypot(q.x-a.x-t*dx,q.y-a.y-t*dy));
    }
    return inside?1:Clamp(1-minimum/radius,0,1);
}
static CGPoint JawShortOracle(CGPoint pixel,NSDictionary *g,CGRect e,PGBeautySettings s) {
    CGPoint p[76];for(NSUInteger i=0;i<76;i++)p[i]=ReadPoint(g[@"points76"][i]);
    double gain=ReferenceSizeGain(p,e);CGPoint q=Oracle(pixel,g,e,s.faceThin);q.y=1-q.y;
    // 2.4.0 consumes the CPU's .065 V ratio directly, without the old size gain.
    const unsigned int vOrigins[]={69,65,70,64},vAnchors[]={39,35,26,34};
    double vRatio=Clamp(s.faceV,0,1)*.065;
    if(vRatio>1e-6)for(NSUInteger i=0;i<4;i++){
        CGPoint a=ReferencePoint(p,vOrigins[i]),b=ReferencePoint(p,vAnchors[i]);
        double radius=hypot(b.x-a.x,b.y-a.y);if(radius<=.0001)continue;
        double influence=Clamp(1-hypot(q.x-a.x,q.y-a.y)/radius,0,1);
        q.x=Clamp(q.x-(b.x-a.x)*vRatio*influence,0,1);q.y=Clamp(q.y-(b.y-a.y)*vRatio*influence,0,1);
    }
    const unsigned int origin[]={72,62,71,63,70,64},neighbour[]={71,63,70,64,71,63};
    double jaw=Clamp(s.faceJaw,0,1)*.05*gain;
    if(fabs(jaw)>1e-6)for(NSUInteger i=0;i<6;i++){
        CGPoint a=ReferencePoint(p,origin[i]),b=ReferencePoint(p,neighbour[i]),target=ReferencePoint(p,29);
        double radius=hypot(b.x-a.x,b.y-a.y);if(radius<=.0001)continue;
        double influence=Clamp(1-hypot(q.x-a.x,q.y-a.y)/radius,0,1);
        q.x=Clamp(q.x-(target.x-a.x)*jaw*influence,0,1);q.y=Clamp(q.y-(target.y-a.y)*jaw*influence,0,1);
    }
    double chin=Clamp(s.faceChin,-1,1)*(s.faceChin>0?.04:.02)*gain;
    if(fabs(chin)>1e-6)for(NSUInteger i=0;i<3;i++){
        CGPoint a=ReferencePoint(p,68-i),target=ReferencePoint(p,38-i);double radius=hypot(target.x-a.x,target.y-a.y);
        if(radius<=.0001)continue;double influence=Clamp(1-hypot(q.x-a.x,q.y-a.y)/radius,0,1);
        q.x=Clamp(q.x-(target.x-a.x)*chin*influence,0,1);q.y=Clamp(q.y-(target.y-a.y)*chin*influence,0,1);
    }
    double shortRatio=Clamp(s.faceShort,-1,1)*.25*gain;
    if(fabs(shortRatio)>1e-6){
        double influence=ReferencePolygonWeight(q,p);
        q.x=Clamp(q.x-(p[46].x-p[48].x)*shortRatio*influence,0,1);
        q.y=Clamp(q.y-(p[48].y-p[46].y)*shortRatio*influence,0,1);
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
static void NumericSettingsCase(CIContext *c,PGFaceProcessor *p,CGRect e,NSDictionary *g,double amount,double chin,NSString *name) {
    PGBeautySettings s=PGBeautyDefaults();s.faceThin=amount;s.faceChin=chin;
    CIImage *input=CoordinateImage(e),*output=[p warpImage:input geometry:@[g] settings:s extent:e];
    Check(output!=nil && CGRectEqualToRect(output.extent,e),[name stringByAppendingString:@" preserves extent"]);
    NSData *data=Pixels(c,output);const float *pixels=data.bytes;double worst=0,maxMove=0;
    NSUInteger worstX=0,worstY=0;CGPoint worstExpected=CGPointZero,worstActual=CGPointZero;
    NSUInteger w=e.size.width,h=e.size.height;
    for(NSUInteger y=3;y<h-3;y+=7)for(NSUInteger x=3;x<w-3;x+=7) {
        // Bitmap rows are top first, while destCoord / geometry are y up.
        CGPoint q=ChinOracle(CGPointMake(e.origin.x+x+.5,e.origin.y+h-y-.5),g,e,amount,chin);
        double ex=Clamp(q.x,.5/w,1-.5/w),ey=Clamp(1-q.y,.5/h,1-.5/h);
        NSUInteger k=(y*w+x)*4;
        double difference=fmax(fabs(pixels[k]-ex),fabs(pixels[k+1]-ey));
        if(difference>worst){worst=difference;worstX=x;worstY=y;worstExpected=CGPointMake(ex,ey);worstActual=CGPointMake(pixels[k],pixels[k+1]);}
        maxMove=fmax(maxMove,hypot(ex-(x+.5)/w,ey-(y+.5)/h));
    }
    if(worst>0.00006)fprintf(stderr,"%s oracle max error=%g at %lu,%lu expected=(%g,%g) actual=(%g,%g)\n",name.UTF8String,worst,(unsigned long)worstX,(unsigned long)worstY,worstExpected.x,worstExpected.y,worstActual.x,worstActual.y);
    maxOracleError=fmax(maxOracleError,worst);
    Check(worst<0.00006,[name stringByAppendingString:@" GPU field matches the independent thin/chin oracle"]);
    Check((amount==0 && chin==0) || maxMove>.0001,[name stringByAppendingString:@" exercises a nonzero displacement"]);
    NSUInteger corner=4*((h-3)*w+(w-3));
    Check(fabs(pixels[corner]-(w-2.5)/w)<1e-6 && fabs(pixels[corner+1]-(h-2.5)/h)<1e-6,[name stringByAppendingString:@" preserves distant background"]);
}
static void NumericCase(CIContext *c,PGFaceProcessor *p,CGRect e,NSDictionary *g,double amount,NSString *name) {
    NumericSettingsCase(c,p,e,g,amount,0,name);
}
static void NumericLocalCase(CIContext *c,PGFaceProcessor *processor,CGRect extent,NSDictionary *geometry,PGBeautySettings settings,NSString *name) {
    CIImage *input=CoordinateImage(extent),*output=[processor warpImage:input geometry:@[geometry] settings:settings extent:extent];
    Check(output!=nil && CGRectEqualToRect(output.extent,extent),[name stringByAppendingString:@" extent"]);
    NSData *data=Pixels(c,output);const float *field=data.bytes;NSUInteger width=extent.size.width,height=extent.size.height;
    double maximum=0,movement=0;
    for(NSUInteger row=3;row<height-3;row+=5)for(NSUInteger column=3;column<width-3;column+=5){
        CGPoint source=JawShortOracle(CGPointMake(extent.origin.x+column+.5,extent.origin.y+height-row-.5),geometry,extent,settings);
        double x=Clamp(source.x,.5/width,1-.5/width),y=Clamp(1-source.y,.5/height,1-.5/height);NSUInteger k=4*(row*width+column);
        maximum=fmax(maximum,fmax(fabs(field[k]-x),fabs(field[k+1]-y)));
        movement=fmax(movement,hypot(x-(column+.5)/width,y-(row+.5)/height));
    }
    maxOracleError=fmax(maxOracleError,maximum);
    if(maximum>=.00006)fprintf(stderr,"%s jaw/short oracle error %.9g\n",name.UTF8String,maximum);
    Check(maximum<.00006,[name stringByAppendingString:@" actual GPU field vs independently decoded AIR double oracle"]);
    Check(movement>.0001,[name stringByAppendingString:@" has nonzero covered samples"]);
}
static CGPoint Displacement(CIContext *c,CIImage *ramp,CIImage *warped,CGPoint uv) {
    CGRect e=ramp.extent;CGRect point=CGRectMake(floor(e.origin.x+uv.x*e.size.width),floor(e.origin.y+uv.y*e.size.height),1,1);
    float a[4],b[4];
    [c render:ramp toBitmap:a rowBytes:sizeof(a) bounds:point format:kCIFormatRGBAf colorSpace:nil];
    [c render:warped toBitmap:b rowBytes:sizeof(b) bounds:point format:kCIFormatRGBAf colorSpace:nil];
    return CGPointMake((b[0]-a[0])*e.size.width,-(b[1]-a[1])*e.size.height);
}
static void AnatomicalChecks(CIContext *c,PGFaceProcessor *p,NSDictionary *g,CGRect e) {
    CIImage *ramp=CoordinateImage(e);NSArray *points=g[@"points76"];
    CGPoint chin=ReadPoint(points[67]),lip=ReadPoint(points[37]);
    double ax=(lip.x-chin.x)*e.size.width,ay=(lip.y-chin.y)*e.size.height;
    for(int sign=-1;sign<=1;sign+=2) {
        PGBeautySettings s=PGBeautyDefaults();s.faceChin=sign;
        CIImage *out=[p warpImage:ramp geometry:@[g] settings:s extent:e];
        CGPoint d=Displacement(c,ramp,out,chin);
        Check(hypot(d.x,d.y)>.05,@"chin control moves the detected physical chin landmark");
        Check(sign*(d.x*ax+d.y*ay)<0,@"signed chin direction follows chin-to-lip anchor instead of a fixed image Y axis");
        BOOL outside=YES,eyesUnchanged=YES;
        for(NSNumber *index in @[@6,@13]) {
            CGPoint eye=ReadPoint(points[index.unsignedIntegerValue]);
            for(NSUInteger i=0;i<3;i++) {
                CGPoint a=ReadPoint(points[68-i]),b=ReadPoint(points[38-i]);
                if(hypot(eye.x-a.x,eye.y-a.y)<=hypot(a.x-b.x,a.y-b.y)+.003)outside=NO;
            }
            CGPoint shift=Displacement(c,ramp,out,eye);eyesUnchanged &= hypot(shift.x,shift.y)<.002;
        }
        Check(outside && eyesUnchanged,@"both physical pupils outside chin supports remain unchanged");
    }
}
static void JawShortAnatomicalChecks(CIContext *context,PGFaceProcessor *processor,NSDictionary *geometry,CGRect extent) {
    CGPoint points[76];for(NSUInteger i=0;i<76;i++)points[i]=ReadPoint(geometry[@"points76"][i]);
    CIImage *ramp=CoordinateImage(extent);PGBeautySettings settings=PGBeautyDefaults();settings.faceJaw=1;
    CIImage *jaw=[processor warpImage:ramp geometry:@[geometry] settings:settings extent:extent];
    double jawMove=0;NSUInteger origin[]={72,62,71,63,70,64},neighbour[]={71,63,70,64,71,63};
    for(NSUInteger i=0;i<6;i++){
        CGPoint movement=Displacement(context,ramp,jaw,points[origin[i]]);jawMove=fmax(jawMove,hypot(movement.x,movement.y));
        double x=(points[29].x-points[origin[i]].x)*extent.size.width,y=(points[29].y-points[origin[i]].y)*extent.size.height;
        Check(movement.x*x+movement.y*y<.001,@"jaw inverse sampling moves opposite the physical contour-to-lip direction");
    }
    Check(jawMove>.1,@"jaw control acts on a detected lower-jaw contour, not a guessed temple band");
    // These are anatomical regions reported by public Vision, not positions
    // picked by the production support formula: pupils and upper contour ends.
    for(NSNumber *index in @[@6,@13,@59,@75]){
        CGPoint point=points[index.unsignedIntegerValue];BOOL clear=YES;
        for(NSUInteger i=0;i<6;i++)if(hypot(point.x-points[origin[i]].x,point.y-points[origin[i]].y)<hypot(points[origin[i]].x-points[neighbour[i]].x,points[origin[i]].y-points[neighbour[i]].y)+.004)clear=NO;
        CGPoint movement=Displacement(context,ramp,jaw,point);
        Check(clear&&hypot(movement.x,movement.y)<.002,@"physical pupils/upper-contour temple positions outside jaw supports stay unchanged");
    }
    CGPoint lower=CGPointZero;for(NSUInteger i=62;i<=72;i++){lower.x+=points[i].x/11;lower.y+=points[i].y/11;}
    Check(ReferencePolygonWeight(CGPointMake(lower.x,1-lower.y),points)>.99,@"public lower-contour centroid lies inside the short-face region");
    double axisX=(points[46].x-points[48].x)*extent.size.width,axisY=(points[46].y-points[48].y)*extent.size.height;
    for(int sign=-1;sign<=1;sign+=2){
        settings=PGBeautyDefaults();settings.faceShort=sign;CIImage *shortFace=[processor warpImage:ramp geometry:@[geometry] settings:settings extent:extent];
        CGPoint displacement=Displacement(context,ramp,shortFace,lower);
        Check(hypot(displacement.x,displacement.y)>.1,@"short-face changes the physical lower face");
        Check(sign*(displacement.x*axisX+displacement.y*axisY)<0,@"short-face signed source sampling follows the nose-crest axis; positive visible motion shortens upward");
        for(NSNumber *index in @[@6,@13,@59,@75]){
            CGPoint point=points[index.unsignedIntegerValue],motion=Displacement(context,ramp,shortFace,point);
            Check(ReferencePolygonWeight(CGPointMake(point.x,1-point.y),points)==0 && hypot(motion.x,motion.y)<.002,@"physical pupil/temple beyond short-face distance envelope is unaffected");
        }
    }
}
static void VFaceAnatomicalChecks(CIContext *context,PGFaceProcessor *processor,NSDictionary *geometry,CGRect extent) {
    CIImage *ramp=CoordinateImage(extent);PGBeautySettings settings=PGBeautyDefaults();settings.faceV=1;
    CIImage *output=[processor warpImage:ramp geometry:@[geometry] settings:settings extent:extent];
    NSArray *points=geometry[@"points76"];double lowerMove=0;
    for(NSNumber *index in @[@69,@65,@70,@64]) {
        CGPoint motion=Displacement(context,ramp,output,ReadPoint(points[index.unsignedIntegerValue]));
        lowerMove=fmax(lowerMove,hypot(motion.x,motion.y));
    }
    Check(lowerMove>.1,@"V-face moves the actual lower-jaw contour");
    for(NSNumber *index in @[@6,@13]) {
        CGPoint motion=Displacement(context,ramp,output,ReadPoint(points[index.unsignedIntegerValue]));
        if(hypot(motion.x,motion.y)>=.002)fprintf(stderr,"V-face pupil %u moved %.6f pixels\n",index.unsignedIntValue,hypot(motion.x,motion.y));
        Check(hypot(motion.x,motion.y)<.002,@"isolated V-face leaves the physical pupils unchanged");
    }
}
static void JawShortSupportChecks(CIContext *context,PGFaceProcessor *processor) {
    NSDictionary *g=Geometry(0,0);CGPoint points[76];for(NSUInteger i=0;i<76;i++)points[i]=ReadPoint(g[@"points76"][i]);
    CGPoint probe=CGPointMake((points[72].x+points[29].x)/2,(points[72].y+points[29].y)/2);
    const unsigned int origins[]={72,62,71,63,70,64},neighbours[]={71,63,70,64,71,63};BOOL outside=YES;
    for(NSUInteger i=0;i<6;i++)if(hypot(probe.x-points[origins[i]].x,probe.y-points[origins[i]].y)<=hypot(points[origins[i]].x-points[neighbours[i]].x,points[origins[i]].y-points[neighbours[i]].y)+.005)outside=NO;
    Check(outside,@"radius discriminator lies beyond all adjacent-contour jaw radii");
    Check(hypot(probe.x-points[72].x,probe.y-points[72].y)<.8*hypot(points[29].x-points[72].x,points[29].y-points[72].y),@"same point would be inside the incorrect lip-distance jaw radius");
    CGRect e=CGRectMake(-19,23,640,360);CIImage *ramp=CoordinateImage(e);PGBeautySettings settings=PGBeautyDefaults();settings.faceJaw=1;
    CIImage *out=[processor warpImage:ramp geometry:@[g] settings:settings extent:e];CGPoint d=Displacement(context,ramp,out,probe);
    Check(hypot(d.x,d.y)<.002,@"jaw uses neighbouring-contour support rather than the lip-anchor distance");
    NSMutableDictionary *small=[g mutableCopy];NSMutableArray *scaled=[NSMutableArray new];
    for(NSArray *point in g[@"points76"])[scaled addObject:@[@(.5+([point[0]doubleValue]-.5)*.18),@(.5+([point[1]doubleValue]-.5)*.18)]];small[@"points76"]=scaled;
    for(NSUInteger i=0;i<76;i++)points[i]=ReadPoint(scaled[i]);
    Check(ReferenceSizeGain(points,e)==2.25,@"small-face numerical case reaches the recovered gain cap");
    NumericLocalCase(context,processor,e,small,settings,@"small face jaw max gain");settings.faceJaw=0;settings.faceShort=1;
    NumericLocalCase(context,processor,e,small,settings,@"small face short max gain");
    settings.faceShort=0;settings.faceV=1;
    NumericLocalCase(context,processor,e,small,settings,@"small face V excludes legacy size gain");
    for(NSUInteger i=0;i<76;i++)points[i]=ReadPoint(g[@"points76"][i]);Check(ReferenceSizeGain(points,CGRectMake(0,0,1600,1600))==1,@"large-face numerical case reaches gain floor");
    // Four full process masks must use exactly the same new warp as the image.
    [processor setTrackingData:Archive(g) forTarget:0];settings=PGBeautyDefaults();settings.trackingEnabled=1;
    PGFaceFrame *neutral=[processor processImage:ramp settings:settings time:kCMTimeZero error:nil];
    for(NSUInteger mode=0;mode<4;mode++){
        PGBeautySettings shape=settings;shape.faceJaw=(mode==0||mode==2)?1:0;shape.faceShort=(mode==1||mode==2)?-.65:0;shape.faceV=mode==3?1:0;
        PGFaceFrame *frame=[processor processImage:ramp settings:shape time:kCMTimeZero error:nil];
        Check([Pixels(context,frame.image)isEqualToData:Pixels(context,[processor warpImage:ramp geometry:@[g] settings:shape extent:e])],@"process image uses the common V/jaw/short field");
        NSArray *before=@[neutral.skinMask,neutral.colorMask,neutral.teethMask,neutral.eyeMask],*after=@[frame.skinMask,frame.colorMask,frame.teethMask,frame.eyeMask];
        for(NSUInteger i=0;i<4;i++)Check([Pixels(context,after[i])isEqualToData:Pixels(context,[processor warpImage:before[i] geometry:@[g] settings:shape extent:e])],@"every image support mask shares the V/jaw/short coordinate field");
    }
}
static void IndependentImageLandmarkCheck(NSString *path,NSDictionary *geometry) {
    CGImageSourceRef source=CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path],NULL);
    CGImageRef image=source?CGImageSourceCreateImageAtIndex(source,0,NULL):NULL;if(source)CFRelease(source);
    VNDetectFaceLandmarksRequest *request=[VNDetectFaceLandmarksRequest new];request.revision=VNDetectFaceLandmarksRequestRevision3;request.constellation=VNRequestFaceLandmarksConstellation76Points;
    NSError *error=nil;VNImageRequestHandler *handler=image?[[VNImageRequestHandler alloc]initWithCGImage:image options:@{}]:nil;
    BOOL ok=[handler performRequests:@[request] error:&error];if(image)CGImageRelease(image);
    VNFaceObservation *face=request.results.firstObject;VNFaceLandmarkRegion2D *all=face.landmarks.allPoints;
    Check(ok && !error && all.pointCount==76,@"independent public CGImage detection provides76 for physical PNG orientation check");
    for(NSNumber *index in @[@6,@13,@29,@46,@48,@59,@62,@67,@72,@75]){
        CGPoint local=all.normalizedPoints[index.unsignedIntegerValue];
        CGPoint full=CGPointMake(face.boundingBox.origin.x+local.x*face.boundingBox.size.width,face.boundingBox.origin.y+local.y*face.boundingBox.size.height);
        CGPoint product=ReadPoint(geometry[@"points76"][index.unsignedIntegerValue]);
        // Separate CGImage and CIImage Vision requests have small conversion
        // differences. A Y flip, reordered topology or bbox-local point cannot
        // satisfy this tolerance. Physical PNG top-row is (1-y)*height.
        Check(hypot(full.x-product.x,full.y-product.y)<.025,@"independent CGImage anatomy agrees on pupils, lips, crest and lower contour in the PNG coordinate system");
    }
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
    for(NSUInteger e=0;e<3;e++)for(NSUInteger y=0;y<3;y++)for(NSUInteger r=0;r<2;r++)for(int sign=-1;sign<=1;sign+=2) {
        double angle=y==0?0:(y==1?1.4:-1.4);
        NumericSettingsCase(c,p,extents[e],Geometry(angle,r?.45:0),0,sign,
            [NSString stringWithFormat:@"chin size%lu yaw%lu roll%lu sign%d",(unsigned long)e,(unsigned long)y,(unsigned long)r,sign]);
    }
    NumericSettingsCase(c,p,extents[1],Geometry(.4,.2),.8,1,@"thin plus positive chin");
    NumericSettingsCase(c,p,extents[2],Geometry(-.6,-.2),1,-1,@"thin plus negative chin");
    NumericSettingsCase(c,p,extents[0],Geometry(0,0),0,.5,@"half positive chin");
    NumericSettingsCase(c,p,extents[0],Geometry(0,0),0,-.5,@"half negative chin");
    for(NSUInteger e=0;e<4;e++)for(NSUInteger y=0;y<3;y++)for(NSUInteger r=0;r<3;r++)for(NSUInteger mode=0;mode<4;mode++){
        PGBeautySettings local=PGBeautyDefaults();if(mode==0)local.faceJaw=1;else if(mode==3)local.faceV=1;else local.faceShort=mode==1?1:-1;
        double angle=y==0?0:(y==1?1.4:-1.4);
        NumericLocalCase(c,p,extents[e],Geometry(angle,roll[r]),local,
            [NSString stringWithFormat:@"local size%lu yaw%lu roll%lu mode%lu",(unsigned long)e,(unsigned long)y,(unsigned long)r,(unsigned long)mode]);
        if(mode==3)VFaceAnatomicalChecks(c,p,Geometry(angle,roll[r]),extents[e]);
    }
    PGBeautySettings combined=PGBeautyDefaults();combined.faceThin=.7;combined.faceJaw=.8;combined.faceChin=-.6;combined.faceShort=.75;
    NumericLocalCase(c,p,extents[2],Geometry(.8,.45),combined,@"ordered thin jaw chin short positive");
    combined.faceShort=-.75;combined.faceChin=.7;
    NumericLocalCase(c,p,extents[1],Geometry(-.8,-.45),combined,@"ordered thin jaw chin short negative");
    combined.faceV=.85;
    NumericLocalCase(c,p,extents[3],Geometry(.6,.2),combined,@"thin V jaw chin short combined sequential order");
    PGBeautySettings vHalf=PGBeautyDefaults();vHalf.faceV=.5;
    NumericLocalCase(c,p,extents[2],Geometry(-.6,-.4),vHalf,@"half V strength tilted portrait");
    combined=PGBeautyDefaults();combined.faceJaw=.5;combined.faceShort=-.5;
    NumericLocalCase(c,p,extents[1],Geometry(0,0),combined,@"half signed short plus jaw");
    JawShortSupportChecks(c,p);
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
        PGBeautySettings chinOnly=s;chinOnly.faceThin=0;chinOnly.faceChin=1;
        Check([Pixels(c,[p processImage:image settings:chinOnly time:kCMTimeZero error:&error].image) isEqualToData:source],@"legacy/malformed indexed points never trigger guessed bbox chin deformation");
        PGBeautySettings shortOnly=s;shortOnly.faceThin=0;shortOnly.faceShort=-1;
        Check([Pixels(c,[p processImage:image settings:shortOnly time:kCMTimeZero error:&error].image) isEqualToData:source],@"legacy/malformed indexed points skip recovered short-face field exactly");
        PGBeautySettings jawOnly=s;jawOnly.faceThin=0;jawOnly.faceJaw=1;
        Check([Pixels(c,[p processImage:image settings:jawOnly time:kCMTimeZero error:&error].image) isEqualToData:source],@"legacy/malformed indexed points skip recovered jaw field exactly");
        PGBeautySettings vOnly=s;vOnly.faceThin=0;vOnly.faceV=1;
        Check([Pixels(c,[p processImage:image settings:vOnly time:kCMTimeZero error:&error].image) isEqualToData:source],@"legacy/malformed indexed points skip recovered V-face without a guessed face-box band");
        PGBeautySettings other=s;other.faceNarrow=.5;
        Check(![Pixels(c,[p processImage:image settings:other time:kCMTimeZero error:&error].image) isEqualToData:source],@"other controls remain available in legacy archives");
    }
    PGRealtimeFaceTracker *tracker=[PGRealtimeFaceTracker new];PGBeautySettings live=PGBeautyDefaults();
    NSDictionary *liveFront=PGTrackingTestGeometry(CGRectMake(.15,.15,.7,.6),0),*liveMoved=PGTrackingTestGeometry(CGRectMake(.16,.15,.7,.6),.003);
    NSDictionary *a=[tracker resultForGeometry:@[liveFront] settings:live time:kCMTimeZero extent:image.extent];
    NSDictionary *b=[tracker resultForGeometry:@[liveMoved] settings:live time:CMTimeMake(1,25) extent:image.extent];
    Check([a[@"output"][0][@"points76"] count]==76 && [b[@"output"][0][@"points76"] count]==76,@"realtime stabilization retains the complete indexed point layout");
    Check([b[@"output"][0][@"points76"] isEqual:liveMoved[@"points76"]],@"qualified realtime points are copied exactly by the pin-style branch");
    Check([b isEqual:[tracker resultForGeometry:@[liveMoved] settings:live time:CMTimeMake(1,25) extent:image.extent]],@"repeated rendering does not advance the 76-point sequence again");
    NSDictionary *held=[tracker resultForGeometry:@[] settings:live time:CMTimeMake(2,25) extent:image.extent];
    NSArray *heldPoints=held[@"output"][0][@"points76"],*acceptedPoints=b[@"output"][0][@"points76"];BOOL sameHeld=heldPoints.count==76&&acceptedPoints.count==76;
    for(NSUInteger i=0;i<MIN(heldPoints.count,acceptedPoints.count);i++) {CGPoint h=ReadPoint(heldPoints[i]),a=ReadPoint(acceptedPoints[i]);sameHeld=sameHeld&&hypot(h.x-a.x,h.y-a.y)<1e-12;}
    Check(sameHeld,@"missing detection holds the complete point layout through affine roundoff");
    NSDictionary *turned=PGTrackingTestGeometry(CGRectMake(.16,.15,.7,.6),.02);
    NSDictionary *back=[tracker resultForGeometry:@[turned] settings:live time:CMTimeMake(3,25) extent:image.extent];
    Check([back[@"output"][0][@"points76"] isEqual:turned[@"points76"]],@"qualified reacquired points do not blend with the held pose");
    for(int index=1;index<argc;index++) {@autoreleasepool {
        CIImage *portrait=[CIImage imageWithContentsOfURL:[NSURL fileURLWithPath:@(argv[index])] options:@{kCIImageColorSpace:NSNull.null}];
        PGFaceProcessor *real=[PGFaceProcessor new];PGBeautySettings rs=PGBeautyDefaults();rs.faceThin=1;
        PGFaceFrame *f=[real processImage:portrait settings:rs time:kCMTimeZero error:&error];
        Check(f!=nil && f.faces.count>0 && [f.deformationGeometry[0][@"points76"] count]==76,@"real Vision detection supplies exactly 76 points to thin deformation");
        Check(![Pixels(c,f.image) isEqualToData:Pixels(c,portrait)],@"maximum thin changes a real detected portrait");
        Check([real analyzeImage:portrait settings:rs time:kCMTimeZero error:&error],@"real pose analysis saves the complete geometry");
        PGFaceProcessor *copy=[PGFaceProcessor new];[copy setTrackingData:[real trackingDataForTarget:0] forTarget:0];rs.trackingEnabled=1;
        Check([Pixels(c,[copy processImage:portrait settings:rs time:kCMTimeZero error:&error].image) isEqualToData:Pixels(c,f.image)],@"real pose replays from persisted 76 points with identical pixels");
        AnatomicalChecks(c,real,f.deformationGeometry.firstObject,portrait.extent);
        JawShortAnatomicalChecks(c,real,f.deformationGeometry.firstObject,portrait.extent);
        VFaceAnatomicalChecks(c,real,f.deformationGeometry.firstObject,portrait.extent);
        IndependentImageLandmarkCheck(@(argv[index]),f.deformationGeometry.firstObject);
    }}
    printf("PASS: %lu slim alignment checks; maximum UV oracle error %.9g\n",(unsigned long)checks,maxOracleError);return 0;
}}
