#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
#import <Metal/Metal.h>
#include <simd/simd.h>
#include <math.h>
#import "PGFaceProcessor.h"
#import "tracking_fixture.h"

@interface PGFaceProcessor (EyeTest)
- (CIImage *)warpImage:(CIImage *)image geometry:(NSArray<NSDictionary *> *)geometry settings:(PGBeautySettings)s extent:(CGRect)extent;
@end
static NSUInteger checks;
static double maximumCIError,maximumTargetError;
static NSMutableArray *caseReports;
static void Check(BOOL value,NSString *message) {
    checks++;if(!value){fprintf(stderr,"FAIL: %s\n",message.UTF8String);exit(1);}
}
static double Clamp(double x,double a,double b){return fmin(fmax(x,a),b);}
static CGPoint ReadEyePoint(NSArray *a){return CGPointMake([a[0] doubleValue],[a[1] doubleValue]);}
static NSArray *Pair(CGPoint p){return @[@(p.x),@(p.y)];}
static NSDictionary *Geometry(double roll,double scale) {
    NSMutableDictionary *g=[PGTrackingTestGeometry(CGRectMake(.12,.10,.76,.78),0) mutableCopy];
    NSMutableArray *points=[g[@"points76"] mutableCopy];
    for(NSUInteger i=0;i<76;i++) {
        CGPoint p=ReadEyePoint(points[i]);double x=(p.x-.5)*scale,y=(p.y-.5)*scale;
        points[i]=Pair(CGPointMake(.5+x*cos(roll)-y*sin(roll),.5+x*sin(roll)+y*cos(roll)));
    }
    g[@"points76"]=points;return g;
}

// Independent double-precision scalar specification from the recorded 2.4.0
// AIR. It does not call the production kernel or production parameter tables.
// Thin uses normalized Y-down distances, while eyes use circular pixel support.
static CGPoint Oracle(CGPoint destination,NSDictionary *g,CGRect e,double thin,double eye,BOOL reverseEyes) {
    static const int origin[17]={75,59,74,60,73,61,72,62,71,63,70,64,69,65,68,66,67};
    static const int anchor[17]={6,13,47,47,47,47,48,48,48,48,49,49,49,49,52,52,47};
    CGPoint points[76];for(NSUInteger i=0;i<76;i++){points[i]=ReadEyePoint(g[@"points76"][i]);points[i].y=1-points[i].y;}
    CGPoint q=CGPointMake((destination.x-e.origin.x)/e.size.width,1-(destination.y-e.origin.y)/e.size.height);
    double thinAmount=Clamp(thin,0,1)*.025;
    if(fabs(thinAmount)>1e-6)for(NSUInteger i=0;i<17;i++) {
        CGPoint a=points[origin[i]],b=points[anchor[i]];double r=hypot(a.x-b.x,a.y-b.y);
        if(r<=1e-4)continue;
        double weight=Clamp(1-hypot(q.x-a.x,q.y-a.y)/r,0,1);
        q.x=Clamp(q.x-(b.x-a.x)*thinAmount*weight,0,1);q.y=Clamp(q.y-(b.y-a.y)*thinAmount*weight,0,1);
    }
    double amount=Clamp(eye,0,1)*.15;
    const int center[2]={6,13},radiusA[2]={0,7},radiusB[2]={1,8};
    if(amount>1e-6)for(int j=0;j<2;j++) {
        int i=reverseEyes?1-j:j;CGPoint c=points[center[i]],a=points[radiusA[i]],b=points[radiusB[i]];
        double radius=hypot((a.x-b.x)*e.size.width,(a.y-b.y)*e.size.height);
        if(radius<=1e-4)continue;
        double dx=q.x-c.x,dy=q.y-c.y,distance=hypot(dx*e.size.width,dy*e.size.height);
        if(distance>radius)continue;
        double ratio=distance/radius,factor=1-amount*(1-pow(ratio,2));
        q.x=c.x+dx*factor;q.y=c.y+dy*factor;
    }
    return q;
}
static NSData *CoordinateData(CGSize size) {
    NSUInteger width=size.width,height=size.height;
    NSMutableData *data=[NSMutableData dataWithLength:width*height*4*sizeof(float)];float *p=data.mutableBytes;
    for(NSUInteger y=0;y<height;y++)for(NSUInteger x=0;x<width;x++) {
        NSUInteger i=(y*width+x)*4;p[i]=(x+.5)/width;p[i+1]=(y+.5)/height;p[i+2]=.25;p[i+3]=1;
    }
    return data;
}
static CIImage *CoordinateImage(CGRect e) {
    return [[CIImage imageWithBitmapData:CoordinateData(e.size) bytesPerRow:(NSUInteger)e.size.width*4*sizeof(float) size:e.size format:kCIFormatRGBAf colorSpace:nil]
        imageByApplyingTransform:CGAffineTransformMakeTranslation(e.origin.x,e.origin.y)];
}
static NSData *Pixels(CIContext *context,CIImage *image) {
    CGRect e=image.extent;NSUInteger width=e.size.width,height=e.size.height;
    NSMutableData *data=[NSMutableData dataWithLength:width*height*4*sizeof(float)];
    [context render:image toBitmap:data.mutableBytes rowBytes:width*4*sizeof(float) bounds:e format:kCIFormatRGBAf colorSpace:nil];return data;
}

// Optional local oracle. Only a path provided explicitly by the developer is
// loaded; no vendor binary is included in, copied to, or required by this repo.
// AIR metadata: faceThinMode buffer4, sampleFlipY buffer8, warpFlipY buffer9.
@interface TargetOracle : NSObject
@property(nonatomic,strong)id<MTLDevice> device;
@property(nonatomic,strong)id<MTLRenderPipelineState> pipeline;
@property(nonatomic,strong)id<MTLCommandQueue> queue;
- (instancetype)initWithLibrary:(NSString *)path;
- (NSData *)pixelsForGeometry:(NSDictionary *)geometry extent:(CGRect)e thin:(double)thin eye:(double)eye;
@end
@implementation TargetOracle
- (instancetype)initWithLibrary:(NSString *)path {
    self=[super init];if(!self)return nil;
    _device=MTLCreateSystemDefaultDevice();NSError *error=nil;
    id<MTLLibrary> library=[_device newLibraryWithURL:[NSURL fileURLWithPath:path] error:&error];
    Check(library!=nil,[NSString stringWithFormat:@"optional target library loads: %@",error?:@""]);
    MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new];
    pd.vertexFunction=[library newFunctionWithName:@"vertexShader"];
    pd.fragmentFunction=[library newFunctionWithName:@"faceThinFragmentShader"];
    pd.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA32Float;
    _pipeline=[_device newRenderPipelineStateWithDescriptor:pd error:&error];
    Check(_pipeline!=nil,[NSString stringWithFormat:@"optional target coordinate pipeline loads: %@",error?:@""]);
    _queue=[_device newCommandQueue];return self;
}
- (NSData *)pixelsForGeometry:(NSDictionary *)g extent:(CGRect)e thin:(double)thin eye:(double)eye {
    NSUInteger width=e.size.width,height=e.size.height;
    MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:width height:height mipmapped:NO];
    td.storageMode=MTLStorageModeShared;td.usage=MTLTextureUsageShaderRead;
    id<MTLTexture> input=[_device newTextureWithDescriptor:td];NSData *gradient=CoordinateData(e.size);
    [input replaceRegion:MTLRegionMake2D(0,0,width,height) mipmapLevel:0 withBytes:gradient.bytes bytesPerRow:width*16];
    td.usage=MTLTextureUsageRenderTarget;id<MTLTexture> output=[_device newTextureWithDescriptor:td];
    typedef struct {vector_float2 position,textureCoordinate;} Vertex;
    float w=(float)width,h=(float)height;
    Vertex vertices[]={{{-w*.5f,h*.5f},{0,0}},{{-w*.5f,-h*.5f},{0,1}},{{w*.5f,h*.5f},{1,0}},{{w*.5f,-h*.5f},{1,1}}};
    vector_uint2 viewport={(uint32_t)width,(uint32_t)height};vector_float2 points[77];
    for(NSUInteger i=0;i<76;i++){CGPoint p=ReadEyePoint(g[@"points76"][i]);points[i]=(vector_float2){p.x,1-p.y};}
    NSArray *box=g[@"box"];points[76]=(vector_float2){[box[0] doubleValue]+[box[2] doubleValue]*.5,1-([box[1] doubleValue]+[box[3] doubleValue]*.5)};
    int count=1,zero=0;float strength=Clamp(thin,0,1);
    float shape[10]={Clamp(thin,0,1)*.025,0,0,0,0,0,0,0,0,Clamp(eye,0,1)*.15};
    id<MTLCommandBuffer> command=[_queue commandBuffer];MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture=output;pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;
    id<MTLRenderCommandEncoder> encoder=[command renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:_pipeline];
    [encoder setVertexBytes:vertices length:sizeof(vertices) atIndex:0];[encoder setVertexBytes:&viewport length:sizeof(viewport) atIndex:1];
    [encoder setFragmentTexture:input atIndex:0];[encoder setFragmentBytes:points length:sizeof(points) atIndex:0];
    [encoder setFragmentBytes:&count length:sizeof(count) atIndex:1];[encoder setFragmentBytes:&strength length:sizeof(strength) atIndex:2];
    [encoder setFragmentBytes:&zero length:sizeof(zero) atIndex:4];[encoder setFragmentBytes:shape length:sizeof(shape) atIndex:7];
    [encoder setFragmentBytes:&zero length:sizeof(zero) atIndex:8];[encoder setFragmentBytes:&zero length:sizeof(zero) atIndex:9];
    vector_float2 sampleRect[2]={{0,0},{1,1}};[encoder setFragmentBytes:sampleRect length:sizeof(sampleRect) atIndex:10];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];[encoder endEncoding];[command commit];[command waitUntilCompleted];
    Check(command.status==MTLCommandBufferStatusCompleted,[NSString stringWithFormat:@"optional target executes: %@",command.error?:@""]);
    NSMutableData *data=[NSMutableData dataWithLength:width*height*4*sizeof(float)];
    [output getBytes:data.mutableBytes bytesPerRow:width*16 fromRegion:MTLRegionMake2D(0,0,width,height) mipmapLevel:0];return data;
}
@end

static NSData *NumericalCase(CIContext *context,PGFaceProcessor *processor,TargetOracle *target,
                            CGRect e,NSDictionary *geometry,double thin,double eye,NSString *name) {
    PGBeautySettings settings=PGBeautyDefaults();settings.faceThin=thin;settings.faceBigEye=eye;
    CIImage *output=[processor warpImage:CoordinateImage(e) geometry:@[geometry] settings:settings extent:e];
    Check(output!=nil&&CGRectEqualToRect(output.extent,e),[name stringByAppendingString:@" preserves extent"]);
    NSData *data=Pixels(context,output);const float *field=data.bytes;
    NSUInteger width=e.size.width,height=e.size.height;double worst=0,move=0,worstTarget=0,sum=0;
    for(NSUInteger y=2;y<height-2;y+=3)for(NSUInteger x=2;x<width-2;x+=3) {
        CGPoint q=Oracle(CGPointMake(e.origin.x+x+.5,e.origin.y+height-y-.5),geometry,e,thin,eye,NO);
        double expectedX=Clamp(q.x,.5/width,1-.5/width),expectedY=Clamp(q.y,.5/height,1-.5/height);
        NSUInteger k=(y*width+x)*4;double error=hypot((field[k]-expectedX)*width,(field[k+1]-expectedY)*height);
        worst=fmax(worst,error);move=fmax(move,hypot((expectedX-(x+.5)/width)*width,(expectedY-(y+.5)/height)*height));
    }
    maximumCIError=fmax(maximumCIError,worst);
    if(worst>=.035)fprintf(stderr,"%s independent error=%.9g pixels\n",name.UTF8String,worst);
    Check(worst<.035,[name stringByAppendingString:@" matches independent thin/eye pixel coordinates"]);
    Check((thin<=0&&eye<=0)||move>.005,[name stringByAppendingString:@" exercises active deformation"]);
    if(target) {
        NSData *reference=[target pixelsForGeometry:geometry extent:e thin:thin eye:eye];const float *ref=reference.bytes;
        for(NSUInteger y=2;y<height-2;y++)for(NSUInteger x=2;x<width-2;x++) {
            NSUInteger k=(y*width+x)*4;double error=hypot((field[k]-ref[k])*width,(field[k+1]-ref[k+1])*height);
            worstTarget=fmax(worstTarget,error);sum+=error*error;
        }
        maximumTargetError=fmax(maximumTargetError,worstTarget);
        if(worstTarget>=.035)fprintf(stderr,"%s target error=%.9g pixels\n",name.UTF8String,worstTarget);
        Check(worstTarget<.035,[name stringByAppendingString:@" matches the local original 2.4.0 Metal field"]);
    }
    [caseReports addObject:@{@"name":name,@"width":@(width),@"height":@(height),@"thin":@(thin),@"eye":@(eye),
        @"maximum_independent_error_pixels":@(worst),@"maximum_displacement_pixels":@(move),
        @"maximum_target_error_pixels":target?@(worstTarget):NSNull.null,
        @"target_rms_error_pixels":target?@(sqrt(sum/((width-4)*(height-4)))):NSNull.null}];
    return data;
}
int main(int argc,const char **argv){@autoreleasepool {
    NSString *targetPath=nil,*reportPath=nil;
    for(int i=1;i<argc;i++) {
        if(strcmp(argv[i],"--target-metallib")==0&&i+1<argc)targetPath=@(argv[++i]);
        else if(strcmp(argv[i],"--report")==0&&i+1<argc)reportPath=@(argv[++i]);
        else {fprintf(stderr,"Usage: eyes-tests [--target-metallib /absolute/default.metallib] [--report output.json]\n");return 2;}
    }
    caseReports=[NSMutableArray new];
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();Check(device!=nil,@"Metal is available for the production Core Image field");
    CIContext *context=[CIContext contextWithMTLDevice:device options:@{kCIContextWorkingColorSpace:NSNull.null,kCIContextOutputColorSpace:NSNull.null}];
    PGFaceProcessor *processor=[PGFaceProcessor new];TargetOracle *target=targetPath?[[TargetOracle alloc]initWithLibrary:targetPath]:nil;
    CGRect extents[]={CGRectMake(0,0,256,256),CGRectMake(0,0,384,216),CGRectMake(-61,35,192,320)};
    double rolls[]={0,.31,-.46};double strengths[]={.25,.9035486629353234,1};
    for(NSUInteger pose=0;pose<3;pose++)for(NSUInteger size=0;size<3;size++) {
        NSDictionary *g=Geometry(rolls[pose],.7+.12*pose);CGRect e=extents[size];
        NumericalCase(context,processor,target,e,g,0,0,[NSString stringWithFormat:@"pose%lu size%lu passthrough",pose,size]);
        NumericalCase(context,processor,target,e,g,0,strengths[pose],[NSString stringWithFormat:@"pose%lu size%lu eye-only",pose,size]);
        NumericalCase(context,processor,target,e,g,1,0,[NSString stringWithFormat:@"pose%lu size%lu thin-only",pose,size]);
        NumericalCase(context,processor,target,e,g,1,strengths[pose],[NSString stringWithFormat:@"pose%lu size%lu thin+eye",pose,size]);
    }
    CGRect e=extents[1];NSDictionary *g=Geometry(.2,.9);
    NSData *base=NumericalCase(context,processor,target,e,g,0,1,@"indexed eye centers");
    NSMutableDictionary *changed=[g mutableCopy];changed[@"box"]=@[@.02,@.03,@.93,@.91];changed[@"leftEye"]=@[@[@.8,@.1],@[@.9,@.2]];changed[@"rightEye"]=@[@[@.1,@.1],@[@.2,@.2]];
    PGBeautySettings onlyEye=PGBeautyDefaults();onlyEye.faceBigEye=1;
    Check([base isEqualToData:Pixels(context,[processor warpImage:CoordinateImage(e) geometry:@[changed] settings:onlyEye extent:e])],@"eye field is independent of bbox and eye-region bounds when indexed points exist");
    NumericalCase(context,processor,target,e,g,0,-.5,@"negative eye strength clamps to zero");
    NSData *clamped=NumericalCase(context,processor,target,e,g,0,2,@"high eye strength clamps to one");
    Check([base isEqualToData:clamped],@"unit and excessive eye settings produce identical pixels");
    // Every sampled pixel outside both circles remains exactly on the input
    // coordinate field. This rejects the previous face-box-sized eye support.
    const float *basePixels=base.bytes;NSUInteger unaffected=0;double backgroundError=0;
    CGPoint left=ReadEyePoint(g[@"points76"][6]),right=ReadEyePoint(g[@"points76"][13]);
    CGPoint la=ReadEyePoint(g[@"points76"][0]),lb=ReadEyePoint(g[@"points76"][1]);
    CGPoint ra=ReadEyePoint(g[@"points76"][7]),rb=ReadEyePoint(g[@"points76"][8]);
    double lr=hypot((la.x-lb.x)*e.size.width,(la.y-lb.y)*e.size.height);
    double rr=hypot((ra.x-rb.x)*e.size.width,(ra.y-rb.y)*e.size.height);
    for(NSUInteger y=2;y<(NSUInteger)e.size.height-2;y+=3)for(NSUInteger x=2;x<(NSUInteger)e.size.width-2;x+=3) {
        double py=e.size.height-y-.5,px=x+.5;
        if(hypot(px-left.x*e.size.width,py-left.y*e.size.height)<=lr+1||hypot(px-right.x*e.size.width,py-right.y*e.size.height)<=rr+1)continue;
        NSUInteger k=4*(y*(NSUInteger)e.size.width+x);unaffected++;
        backgroundError=fmax(backgroundError,hypot((basePixels[k]-(x+.5)/e.size.width)*e.size.width,(basePixels[k+1]-(y+.5)/e.size.height)*e.size.height));
    }
    Check(unaffected>1000&&backgroundError<.005,@"eye-only deformation preserves the field outside the two pixel circles");
    NSMutableArray *points=[g[@"points76"] mutableCopy];points[0]=points[1];points[7]=points[8];changed=[g mutableCopy];changed[@"points76"]=points;
    Check([Pixels(context,CoordinateImage(e)) isEqualToData:Pixels(context,[processor warpImage:CoordinateImage(e) geometry:@[changed] settings:onlyEye extent:e])],@"zero pixel radii leave both eyes unchanged");
    if(target) {
        NSData *degenerate=[target pixelsForGeometry:changed extent:e thin:0 eye:1];const float *p=degenerate.bytes,*source=CoordinateData(e.size).bytes;
        double error=0;for(NSUInteger i=0;i<degenerate.length/sizeof(float);i+=4)error=fmax(error,fabs(p[i]-source[i])+fabs(p[i+1]-source[i+1]));
        Check(error<.00004,@"local target also treats zero eye radii as identity");
    }
    // Force overlap so a reversed eye order cannot accidentally pass the test.
    points=[g[@"points76"] mutableCopy];points[6]=@[@.47,@.64];points[13]=@[@.53,@.64];
    points[0]=@[@.40,@.64];points[1]=@[@.56,@.64];points[7]=@[@.44,@.64];points[8]=@[@.60,@.64];
    changed=[g mutableCopy];changed[@"points76"]=points;
    NumericalCase(context,processor,target,e,changed,.7,.9,@"overlapping sequential eyes");
    double orderDifference=0;
    for(NSUInteger y=2;y<(NSUInteger)e.size.height-2;y+=3)for(NSUInteger x=2;x<(NSUInteger)e.size.width-2;x+=3) {
        CGPoint position=CGPointMake(e.origin.x+x+.5,e.origin.y+e.size.height-y-.5);
        CGPoint forward=Oracle(position,changed,e,.7,.9,NO),reverse=Oracle(position,changed,e,.7,.9,YES);
        orderDifference=fmax(orderDifference,hypot((forward.x-reverse.x)*e.size.width,(forward.y-reverse.y)*e.size.height));
    }
    Check(orderDifference>.02,@"overlap fixture distinguishes left-to-right sequential sampling");
    if(reportPath) {
        NSDictionary *report=@{@"scope":@"Authored synthetic Vision76 geometry; thin and big-eye controls only; no user media or target binaries embedded",
            @"target_oracle_executed":@(target!=nil),@"mode_buffer4":@0,@"sample_flip_y_buffer8":@0,@"warp_flip_y_buffer9":@0,
            @"device":device.name,@"checks":@(checks+1),@"maximum_independent_error_pixels":@(maximumCIError),
            @"maximum_target_error_pixels":target?@(maximumTargetError):NSNull.null,@"cases":caseReports};
        NSError *error=nil;NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:&error];
        Check([json writeToFile:reportPath options:NSDataWritingAtomic error:&error],[NSString stringWithFormat:@"write report: %@",error?:@""]);
    }
    printf("PASS: %lu eye alignment checks; independent max %.8g px; target %s max %.8g px\n",(unsigned long)checks,maximumCIError,target?"executed":"not requested",maximumTargetError);return 0;
}}
