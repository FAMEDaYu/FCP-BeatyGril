#import <Foundation/Foundation.h>
#import <FxPlug/FxPlugSDK.h>
#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>
#import "PGParameterIDs.h"
#include <math.h>

@interface PGFaceSelectOSC : NSObject <FxOnScreenControl_v4>
- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)api;
@end

@interface PGOSCAPI : NSObject <PROAPIAccessing>
@property BOOL enabled, rejectRead, rejectPoint, rejectWrite, rejectUndo;
@property BOOL disableOSC, disableParams, disableSetting, disableUndo,pixelSetter;
@property BOOL corruptReadback;
@property BOOL rejectConversion,nonfiniteConversion,partialConversion;
@property CGRect bounds;
@property CGAffineTransform objectToCanvas;
@property double x,y,backing;
@property NSUInteger writes,undoStarts,undoEnds;
@property double lastX,lastY,lastConvertX,lastConvertY;
@property NSUInteger objectBoundsReads,canvasToObjectCalls,objectToCanvasCalls;
@property FxDrawingCoordinates lastConvertFrom,lastConvertTo;
@property CMTime lastTime;
@end
@implementation PGOSCAPI
- (instancetype)init {if((self=[super init])){_enabled=YES;_bounds=CGRectMake(-100,-50,200,100);_x=.25;_y=.75;_backing=1;_objectToCanvas=CGAffineTransformMakeScale(320,240);}return self;}
- (id)apiForProtocol:(Protocol *)protocol {
    NSString *name=NSStringFromProtocol(protocol);
    if([name isEqual:@"FxOnScreenControlAPI_v4"])return _disableOSC?nil:self;
    if([name isEqual:@"FxParameterRetrievalAPI_v6"])return _disableParams?nil:self;
    if([name isEqual:@"FxParameterSettingAPI_v5"])return _disableSetting?nil:self;
    if([name isEqual:@"FxUndoAPI"])return _disableUndo?nil:self;
    return nil;
}
- (BOOL)getBoolValue:(BOOL *)value fromParameter:(UInt32)identifier atTime:(CMTime)time {
    if(identifier!=PGSingleFace||_rejectRead)return NO;*value=_enabled;return YES;
}
- (BOOL)getXValue:(double *)x YValue:(double *)y fromParameter:(UInt32)identifier atTime:(CMTime)time {
    if(identifier!=PGSelection||_rejectPoint)return NO;*x=_x;*y=_y;return YES;
}
- (BOOL)setXValue:(double)x YValue:(double)y toParameter:(UInt32)identifier atTime:(CMTime)time {
    if(identifier!=PGSelection||_rejectWrite)return NO;
    _writes++;_lastX=x;_lastY=y;
    _x=_pixelSetter ? .5+x/_bounds.size.width : x;
    _y=_pixelSetter ? .5+y/_bounds.size.height : y;
    if(_corruptReadback){_x=.12345;_y=.87654;}
    _lastTime=time;return YES;
}
- (CGRect)objectBounds {_objectBoundsReads++;return _bounds;}
- (double)backingScaleFactor {return _backing;}
- (void)convertPointFromSpace:(FxDrawingCoordinates)from fromX:(double)x fromY:(double)y toSpace:(FxDrawingCoordinates)to toX:(double *)tx toY:(double *)ty {
    _lastConvertFrom=from;_lastConvertTo=to;_lastConvertX=x;_lastConvertY=y;
    CGPoint point=CGPointMake(NAN,NAN);
    if(from==kFxDrawingCoordinates_OBJECT && to==kFxDrawingCoordinates_CANVAS) {
        _objectToCanvasCalls++;point=CGPointApplyAffineTransform(CGPointMake(x,y),_objectToCanvas);
    } else if(from==kFxDrawingCoordinates_CANVAS && to==kFxDrawingCoordinates_OBJECT) {
        _canvasToObjectCalls++;point=CGPointApplyAffineTransform(CGPointMake(x,y),CGAffineTransformInvert(_objectToCanvas));
    }
    if(_rejectConversion)return; // A void host API can leave outputs untouched.
    if(_nonfiniteConversion)point=CGPointMake(INFINITY,NAN);
    *tx=point.x;if(!_partialConversion)*ty=point.y;
}
- (BOOL)startUndoGroup:(NSString *)name {_undoStarts++;return !_rejectUndo;}
- (BOOL)endUndoGroup {_undoEnds++;return YES;}
@end

@interface PGOSCTile : FxImageTile
@property (strong) IOSurface *surface;
@property FxImageOrigin origin;
@end
@implementation PGOSCTile
- (IOSurface *)ioSurface {return _surface;}
- (FxImageOrigin)imageOrigin {return _origin;}
- (CGColorSpaceRef)colorSpace {return nil;}
@end
static NSUInteger Checks=0,Failures=0;
static void Check(BOOL value,NSString *message) {Checks++;if(!value){Failures++;fprintf(stderr,"FAIL: %s\n",message.UTF8String);}}
static PGOSCTile *Tile(void) {
    IOSurfaceRef surface=IOSurfaceCreate((__bridge CFDictionaryRef)@{(id)kIOSurfaceWidth:@320,(id)kIOSurfaceHeight:@240,(id)kIOSurfaceBytesPerElement:@4,(id)kIOSurfaceBytesPerRow:@1280,(id)kIOSurfacePixelFormat:@(kCVPixelFormatType_32BGRA),(id)kIOSurfaceAllocSize:@(320*240*4)});
    PGOSCTile *tile=[PGOSCTile new];tile.surface=CFBridgingRelease(surface);return tile;
}
static float AlphaAt(PGOSCTile *tile,int x,int y) {
    CIImage *image=[CIImage imageWithIOSurface:(__bridge IOSurfaceRef)tile.surface options:@{kCIImageColorSpace:NSNull.null}];
    CIContext *context=[CIContext contextWithOptions:@{kCIContextWorkingColorSpace:NSNull.null,kCIContextOutputColorSpace:NSNull.null}];
    float p[4]={0};[context render:image toBitmap:p rowBytes:sizeof(p) bounds:CGRectMake(x,y,1,1) format:kCIFormatRGBAf colorSpace:nil];return p[3];
}
int main(int argc,const char **argv) {@autoreleasepool {
    PGOSCAPI *api=[PGOSCAPI new];PGFaceSelectOSC *osc=[[PGFaceSelectOSC alloc] initWithAPIManager:api];
    CMTime time=CMTimeMake(121,24);NSInteger part=-1;BOOL update=YES,handled=YES;
    Check([osc conformsToProtocol:@protocol(FxOnScreenControl_v4)],@"OSC class conforms to the real FxPlug v4 protocol");
    NSArray *required=@[@"drawingCoordinates",@"drawOSCWithWidth:height:activePart:destinationImage:atTime:",@"hitTestOSCAtMousePositionX:mousePositionY:activePart:atTime:",@"mouseDownAtPositionX:positionY:activePart:modifiers:forceUpdate:atTime:",@"mouseDraggedAtPositionX:positionY:activePart:modifiers:forceUpdate:atTime:",@"mouseUpAtPositionX:positionY:activePart:modifiers:forceUpdate:atTime:",@"keyDownAtPositionX:positionY:keyPressed:modifiers:forceUpdate:didHandle:atTime:",@"keyUpAtPositionX:positionY:keyPressed:modifiers:forceUpdate:didHandle:atTime:"];
    for(NSString *selector in required)Check([osc respondsToSelector:NSSelectorFromString(selector)],[NSString stringWithFormat:@"Required callback exists: %@",selector]);
    Check(osc.drawingCoordinates==kFxDrawingCoordinates_CANVAS,@"Mouse callbacks explicitly request CANVAS coordinates");
    NSDictionary *info=argc>1 ? [NSDictionary dictionaryWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]] : nil;
    NSArray *entries=info[@"ProPlugPlugInList"];NSDictionary *control=nil;NSMutableArray *filters=[NSMutableArray new];NSMutableSet *ids=[NSMutableSet new];BOOL unique=YES;
    for(NSDictionary *entry in entries){if([ids containsObject:entry[@"uuid"]])unique=NO;[ids addObject:entry[@"uuid"]];if([entry[@"protocolNames"] containsObject:@"FxOnScreenControl"])control=entry;if([entry[@"protocolNames"] containsObject:@"FxFilter"])[filters addObject:entry];}
    Check(unique && control && filters.count==1,@"Registration has unique filter and dedicated OSC identities");
    Check([control[@"className"] isEqual:@"PGFaceSelectOSC"] && NSClassFromString(control[@"className"])==PGFaceSelectOSC.class,@"Registered OSC resolves to the compiled class");
    Check([control[@"supportedPlugins"] isEqual:@[filters.firstObject[@"uuid"]]],@"Dedicated OSC links to the released filter UUID");
    api.enabled=NO;[osc hitTestOSCAtMousePositionX:0 mousePositionY:0 activePart:&part atTime:time];Check(part==0,@"Disabled selection does not claim mouse events");
    [osc mouseDownAtPositionX:0 positionY:0 activePart:1 modifiers:0 forceUpdate:&update atTime:time];Check(!update && api.writes==0 && api.undoStarts==0,@"Disabled mouse-down writes nothing and opens no undo group");
    api.enabled=YES;[osc hitTestOSCAtMousePositionX:80 mousePositionY:180 activePart:&part atTime:time];Check(part==1,@"Enabled selection accepts a canvas point inside the converted source");
    [osc hitTestOSCAtMousePositionX:1000 mousePositionY:0 activePart:&part atTime:time];Check(part==0,@"Outside-object hit test is empty");
    [osc hitTestOSCAtMousePositionX:NAN mousePositionY:0 activePart:&part atTime:time];Check(part==0,@"Nonfinite hit coordinates are rejected");
    [osc hitTestOSCAtMousePositionX:0 mousePositionY:0 activePart:NULL atTime:time];Check(YES,@"Null hit-test output is safe");
    [osc mouseDownAtPositionX:0 positionY:0 activePart:0 modifiers:0 forceUpdate:&update atTime:time];Check(!update && api.writes==0,@"Inactive part does not start selection");
    update=YES;[osc mouseUpAtPositionX:0 positionY:0 activePart:1 modifiers:0 forceUpdate:&update atTime:time];Check(!update && api.undoEnds==0,@"Mouse-up without mouse-down leaves undo balanced");
    [osc mouseDownAtPositionX:80 positionY:180 activePart:1 modifiers:0 forceUpdate:&update atTime:time];Check(update && fabs(api.lastX-.25)<1e-8 && fabs(api.lastY-.75)<1e-8,@"CANVAS mouse-down converts to normalized point parameter coordinates");
    Check(CMTimeCompare(api.lastTime,time)==0 && api.undoStarts==1,@"Selection writes use callback time and open one undo group");
    [osc mouseDraggedAtPositionX:500 positionY:-500 activePart:1 modifiers:0 forceUpdate:&update atTime:time];Check(update && api.lastX==1 && api.lastY==0,@"Dragging clamps the converted normalized point to the source");
    [osc mouseUpAtPositionX:0 positionY:0 activePart:1 modifiers:0 forceUpdate:&update atTime:time];Check(update && api.undoEnds==1,@"Gesture completes its matching undo group");
    NSUInteger writes=api.writes;[osc mouseDraggedAtPositionX:0 positionY:0 activePart:1 modifiers:0 forceUpdate:&update atTime:time];Check(!update && api.writes==writes,@"Stray drag after release writes nothing");
    api.bounds=CGRectMake(0,0,NAN,100);[osc hitTestOSCAtMousePositionX:160 mousePositionY:120 activePart:&part atTime:time];Check(part==1,@"Converted hit testing does not depend on document pixel bounds");
    update=YES;[osc mouseDownAtPositionX:NAN positionY:0 activePart:1 modifiers:0 forceUpdate:&update atTime:time];Check(!update && api.writes==writes,@"Nonfinite event initializes forceUpdate and avoids parameter writes");api.bounds=CGRectMake(-100,-50,200,100);
    api.rejectWrite=YES;[osc mouseDownAtPositionX:0 positionY:0 activePart:1 modifiers:0 forceUpdate:&update atTime:time];Check(!update && api.undoStarts==api.undoEnds,@"Rejected parameter write closes the opened undo group");api.rejectWrite=NO;
    api.rejectUndo=YES;NSUInteger ends=api.undoEnds;[osc mouseDownAtPositionX:0 positionY:0 activePart:1 modifiers:0 forceUpdate:&update atTime:time];[osc mouseUpAtPositionX:0 positionY:0 activePart:1 modifiers:0 forceUpdate:&update atTime:time];Check(api.undoEnds==ends,@"Failed undo start is never paired with an invalid end");api.rejectUndo=NO;
    for(int disabled=0;disabled<3;disabled++){
        api.disableOSC=disabled==0;api.disableParams=disabled==1;api.disableSetting=disabled==2;
        writes=api.writes;update=YES;[osc mouseDownAtPositionX:0 positionY:0 activePart:1 modifiers:0 forceUpdate:&update atTime:time];Check(!update && api.writes==writes,[NSString stringWithFormat:@"Missing host API %d is handled safely",disabled]);
    }
    api.disableOSC=api.disableParams=api.disableSetting=NO;
    [osc keyDownAtPositionX:0 positionY:0 keyPressed:0 modifiers:0 forceUpdate:&update didHandle:&handled atTime:time];Check(!update && !handled,@"Unrecognized key-down clears outputs");update=handled=YES;
    [osc keyUpAtPositionX:0 positionY:0 keyPressed:0 modifiers:0 forceUpdate:&update didHandle:&handled atTime:time];Check(!update && !handled,@"Unrecognized key-up clears outputs");
    PGOSCTile *tile=Tile();api.x=.25;api.y=.75;
    [osc drawOSCWithWidth:1920 height:1080 activePart:0 destinationImage:tile atTime:time];
    Check(AlphaAt(tile,80,180)>.9,@"Normalized selection converts to correct CANVAS pixels despite effect/surface size mismatch");
    Check(fabs(api.lastConvertX-.25)<1e-8 && fabs(api.lastConvertY-.75)<1e-8,@"Host receives normalized OBJECT coordinates rather than document pixel coordinates");
    Check(AlphaAt(tile,25,28)<.01,@"OSC surface is not incorrectly rescaled by effect image dimensions");
    api.enabled=NO;[osc drawOSCWithWidth:1920 height:1080 activePart:0 destinationImage:tile atTime:time];Check(AlphaAt(tile,80,180)<.01,@"Disabled drawing clears the prior handle");
    api.enabled=YES;api.backing=NAN;[osc drawOSCWithWidth:1920 height:1080 activePart:0 destinationImage:tile atTime:time];Check(AlphaAt(tile,80,180)>.9,@"Nonfinite backing scale uses a finite fallback");
    api.x=.5;api.y=.5;api.backing=1;
    [osc drawOSCWithWidth:1921 height:1080 activePart:0 destinationImage:tile atTime:time];
    Check(AlphaAt(tile,160,120)>.9 && AlphaAt(tile,0,0)<.01,@"Default .5/.5 selection draws in the center instead of a corner");
    Check(api.objectBoundsReads==1,@"Drawing reads object bounds once for diagnostics and never uses them to scale the normalized point");
    api.x=NAN;[osc drawOSCWithWidth:1920 height:1080 activePart:0 destinationImage:tile atTime:time];Check(AlphaAt(tile,80,180)<.01,@"Nonfinite stored selection does not create invalid drawing filters");
    api.x=.5;api.y=.5;
    [osc mouseDownAtPositionX:256 positionY:72 activePart:1 modifiers:0 forceUpdate:&update atTime:time];
    [osc mouseUpAtPositionX:256 positionY:72 activePart:1 modifiers:0 forceUpdate:&update atTime:time];
    [osc drawOSCWithWidth:1921 height:1080 activePart:0 destinationImage:tile atTime:time];
    Check(fabs(api.x-.8)<1e-8 && fabs(api.y-.3)<1e-8 && AlphaAt(tile,256,72)>.9,@"Click writes normalized selection and redraws the handle at that point");
    PGOSCAPI *motion=[PGOSCAPI new];motion.pixelSetter=YES;motion.bounds=CGRectMake(-1920,-1080,3840,2160);
    motion.objectToCanvas=CGAffineTransformMake(160,0,0,120,40,30);
    PGFaceSelectOSC *motionOSC=[[PGFaceSelectOSC alloc] initWithAPIManager:motion];
    [motionOSC mouseDownAtPositionX:168 positionY:66 activePart:1 modifiers:0 forceUpdate:&update atTime:time];
    Check(update && fabs(motion.x-.8)<1e-5 && fabs(motion.y-.3)<1e-5,@"Motion pixel-setter bridge is detected by verified parameter readback");
    Check(motion.writes==2 && fabs(motion.lastX-1152)<1e-5 && fabs(motion.lastY+432)<1e-5,@"Detected bridge receives the centered pixel inverse transform");
    NSUInteger beforeCached=motion.writes;
    [motionOSC mouseDraggedAtPositionX:152 positionY:78 activePart:1 modifiers:0 forceUpdate:&update atTime:time];
    Check(update && motion.writes==beforeCached+1 && fabs(motion.x-.7)<1e-5 && fabs(motion.y-.4)<1e-5,@"Pixel-setter mode is cached only on the same OSC instance");
    [motionOSC mouseUpAtPositionX:152 positionY:78 activePart:1 modifiers:0 forceUpdate:&update atTime:time];
    [motionOSC drawOSCWithWidth:3840 height:2160 activePart:0 destinationImage:tile atTime:time];
    Check(AlphaAt(tile,152,78)>.9,@"Motion-compatible setter and drawing round-trip through zoom and nonzero canvas translation");
    Check(motion.undoStarts==1 && motion.undoEnds==1,@"Calibration writes remain in one balanced undo gesture");
    PGOSCAPI *bad=[PGOSCAPI new];bad.corruptReadback=YES;
    PGFaceSelectOSC *badOSC=[[PGFaceSelectOSC alloc] initWithAPIManager:bad];
    [badOSC mouseDownAtPositionX:256 positionY:72 activePart:1 modifiers:0 forceUpdate:&update atTime:time];
    Check(!update && bad.undoStarts==bad.undoEnds,@"Unrecognized readback response is reported as failure with balanced undo");

    // Each fixture describes a host projection independent of effect dimensions:
    // reduced view with padding, magnified/panned view, and a shifted canvas.
    const CGAffineTransform transforms[]={
        CGAffineTransformMake(160,0,0,120,40,30),
        CGAffineTransformMake(640,0,0,480,-160,-120),
        CGAffineTransformMake(192,0,0,144,96,72)};
    const CGPoint normalizedPoints[]={CGPointMake(.75,.25),CGPointMake(.625,.375),CGPointMake(.25,.75)};
    const CGPoint canvasPoints[]={CGPointMake(160,60),CGPointMake(240,60),CGPointMake(144,180)};
    for(NSUInteger i=0;i<3;i++) {
        PGOSCAPI *projected=[PGOSCAPI new];projected.objectToCanvas=transforms[i];
        PGFaceSelectOSC *projectedOSC=[[PGFaceSelectOSC alloc] initWithAPIManager:projected];
        CGPoint n=normalizedPoints[i],c=canvasPoints[i];
        [projectedOSC hitTestOSCAtMousePositionX:c.x mousePositionY:c.y activePart:&part atTime:time];
        Check(part==1,[NSString stringWithFormat:@"Projection %lu claims a visible source point",(unsigned long)i]);
        Check(projected.lastConvertFrom==kFxDrawingCoordinates_CANVAS && projected.lastConvertTo==kFxDrawingCoordinates_OBJECT,@"Hit test explicitly requests the inverse host conversion");
        [projectedOSC mouseDownAtPositionX:c.x positionY:c.y activePart:part modifiers:0 forceUpdate:&update atTime:time];
        Check(update && fabs(projected.x-n.x)<1e-8 && fabs(projected.y-n.y)<1e-8,@"Projected click writes the expected normalized parameter");
        [projectedOSC mouseUpAtPositionX:c.x positionY:c.y activePart:part modifiers:0 forceUpdate:&update atTime:time];
        Check(update && projected.undoStarts==1 && projected.undoEnds==1,@"Projected mouse-up converts and closes one undo gesture");
        [projectedOSC drawOSCWithWidth:3840 height:2160 activePart:0 destinationImage:tile atTime:time];
        Check(AlphaAt(tile,(int)c.x,(int)c.y)>.9,@"Projected click, parameter and rendered handle share the same canvas position");
        Check(projected.lastConvertFrom==kFxDrawingCoordinates_OBJECT && projected.lastConvertTo==kFxDrawingCoordinates_CANVAS,@"Draw explicitly requests the forward host conversion");
        Check(projected.canvasToObjectCalls==3 && projected.objectToCanvasCalls==1,@"Hit, down, up and draw each use the live host conversion");
    }
    PGOSCAPI *panned=[PGOSCAPI new];panned.objectToCanvas=transforms[0];
    PGFaceSelectOSC *pannedOSC=[[PGFaceSelectOSC alloc] initWithAPIManager:panned];
    [pannedOSC hitTestOSCAtMousePositionX:20 mousePositionY:90 activePart:&part atTime:time];
    Check(part==0,@"Canvas pixels inside the surface but outside a shifted source do not hit");
    [pannedOSC mouseDownAtPositionX:20 positionY:90 activePart:1 modifiers:0 forceUpdate:&update atTime:time];
    Check(!update && panned.writes==0 && panned.undoStarts==0,@"Outside-source mouse-down is rejected even with a stale active part");
    [pannedOSC mouseDownAtPositionX:120 positionY:90 activePart:1 modifiers:0 forceUpdate:&update atTime:time];
    Check(update && fabs(panned.x-.5)<1e-8 && fabs(panned.y-.5)<1e-8,@"Gesture starts at the shifted source center");
    panned.objectToCanvas=CGAffineTransformMake(80,0,0,60,100,80);
    [pannedOSC mouseDraggedAtPositionX:160 positionY:95 activePart:1 modifiers:0 forceUpdate:&update atTime:time];
    Check(update && fabs(panned.x-.75)<1e-8 && fabs(panned.y-.25)<1e-8,@"Drag follows host zoom and pan changes during the gesture");
    [pannedOSC mouseDraggedAtPositionX:240 positionY:20 activePart:1 modifiers:0 forceUpdate:&update atTime:time];
    Check(update && panned.x==1 && panned.y==0,@"Drag outside shifted source clamps after inverse conversion");
    [pannedOSC mouseUpAtPositionX:80 positionY:200 activePart:1 modifiers:0 forceUpdate:&update atTime:time];
    Check(update && panned.x==0 && panned.y==1 && panned.undoStarts==panned.undoEnds,@"Release outside shifted source clamps and balances undo");
    [pannedOSC drawOSCWithWidth:1920 height:1080 activePart:0 destinationImage:tile atTime:time];
    Check(AlphaAt(tile,100,140)>.9,@"Clamped release draws at the corresponding transformed source corner");

    for(NSUInteger failure=0;failure<3;failure++) {
        PGOSCAPI *failed=[PGOSCAPI new];
        failed.rejectConversion=failure==0;failed.nonfiniteConversion=failure==1;failed.partialConversion=failure==2;
        PGFaceSelectOSC *failedOSC=[[PGFaceSelectOSC alloc] initWithAPIManager:failed];
        [failedOSC hitTestOSCAtMousePositionX:160 mousePositionY:120 activePart:&part atTime:time];
        Check(part==0,@"Untouched, nonfinite or partial conversion cannot claim a hit");
        [failedOSC mouseDownAtPositionX:160 positionY:120 activePart:1 modifiers:0 forceUpdate:&update atTime:time];
        Check(!update && failed.writes==0 && failed.undoStarts==0,@"Failed conversion cannot write a point or open undo");
        [failedOSC drawOSCWithWidth:1920 height:1080 activePart:0 destinationImage:tile atTime:time];
        Check(AlphaAt(tile,80,180)<.01,@"Failed forward conversion clears the prior OSC handle");
        failed.rejectConversion=failed.nonfiniteConversion=failed.partialConversion=NO;
        [failedOSC mouseDownAtPositionX:160 positionY:120 activePart:1 modifiers:0 forceUpdate:&update atTime:time];
        NSUInteger written=failed.writes;
        failed.rejectConversion=failure==0;failed.nonfiniteConversion=failure==1;failed.partialConversion=failure==2;
        [failedOSC mouseDraggedAtPositionX:200 positionY:100 activePart:1 modifiers:0 forceUpdate:&update atTime:time];
        Check(!update && failed.writes==written,@"Conversion failure during drag preserves the previous selection");
        [failedOSC mouseUpAtPositionX:200 positionY:100 activePart:1 modifiers:0 forceUpdate:&update atTime:time];
        Check(!update && failed.writes==written && failed.undoStarts==failed.undoEnds,@"Conversion failure on release still closes undo without a write");
        failed.rejectConversion=failed.nonfiniteConversion=failed.partialConversion=NO;
        [failedOSC mouseDraggedAtPositionX:200 positionY:100 activePart:1 modifiers:0 forceUpdate:&update atTime:time];
        Check(!update && failed.writes==written,@"Failed release ends dragging so later stray drag cannot write");
    }
    PGOSCAPI *invalidEvent=[PGOSCAPI new];
    PGFaceSelectOSC *invalidEventOSC=[[PGFaceSelectOSC alloc] initWithAPIManager:invalidEvent];
    [invalidEventOSC mouseDownAtPositionX:160 positionY:120 activePart:1 modifiers:0 forceUpdate:&update atTime:time];
    writes=invalidEvent.writes;NSUInteger conversions=invalidEvent.canvasToObjectCalls;
    [invalidEventOSC mouseDraggedAtPositionX:INFINITY positionY:120 activePart:1 modifiers:0 forceUpdate:&update atTime:time];
    Check(!update && invalidEvent.writes==writes && invalidEvent.canvasToObjectCalls==conversions,@"Nonfinite canvas drag is rejected before calling the host conversion");
    [invalidEventOSC mouseUpAtPositionX:160 positionY:NAN activePart:1 modifiers:0 forceUpdate:&update atTime:time];
    Check(!update && invalidEvent.writes==writes && invalidEvent.undoStarts==invalidEvent.undoEnds,@"Nonfinite canvas release balances undo without changing selection");
    printf("OSC adapter: %lu checks, %lu failures\n",(unsigned long)Checks,(unsigned long)Failures);return Failures?1:0;
}}
