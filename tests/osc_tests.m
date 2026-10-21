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
@property CGRect bounds;
@property double x,y,backing;
@property NSUInteger writes,undoStarts,undoEnds;
@property double lastX,lastY,lastConvertX,lastConvertY;
@property NSUInteger objectBoundsReads;
@property CMTime lastTime;
@end
@implementation PGOSCAPI
- (instancetype)init {if((self=[super init])){_enabled=YES;_bounds=CGRectMake(-100,-50,200,100);_x=.25;_y=.75;_backing=1;}return self;}
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
    // Match the SDK contract: OBJECT inputs are normalized; CANVAS is pixels.
    _lastConvertX=x;_lastConvertY=y;*tx=x*320;*ty=y*240;
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
    Check(osc.drawingCoordinates==kFxDrawingCoordinates_OBJECT,@"Mouse callbacks use declared object coordinates");
    NSDictionary *info=argc>1 ? [NSDictionary dictionaryWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]] : nil;
    NSArray *entries=info[@"ProPlugPlugInList"];NSDictionary *control=nil;NSMutableArray *filters=[NSMutableArray new];NSMutableSet *ids=[NSMutableSet new];BOOL unique=YES;
    for(NSDictionary *entry in entries){if([ids containsObject:entry[@"uuid"]])unique=NO;[ids addObject:entry[@"uuid"]];if([entry[@"protocolNames"] containsObject:@"FxOnScreenControl"])control=entry;if([entry[@"protocolNames"] containsObject:@"FxFilter"])[filters addObject:entry];}
    Check(unique && control && filters.count==1,@"Registration has unique filter and dedicated OSC identities");
    Check([control[@"className"] isEqual:@"PGFaceSelectOSC"] && NSClassFromString(control[@"className"])==PGFaceSelectOSC.class,@"Registered OSC resolves to the compiled class");
    Check([control[@"supportedPlugins"] isEqual:@[filters.firstObject[@"uuid"]]],@"Dedicated OSC links to the released filter UUID");
    api.enabled=NO;[osc hitTestOSCAtMousePositionX:0 mousePositionY:0 activePart:&part atTime:time];Check(part==0,@"Disabled selection does not claim mouse events");
    [osc mouseDownAtPositionX:0 positionY:0 activePart:1 modifiers:0 forceUpdate:&update atTime:time];Check(!update && api.writes==0 && api.undoStarts==0,@"Disabled mouse-down writes nothing and opens no undo group");
    api.enabled=YES;[osc hitTestOSCAtMousePositionX:0 mousePositionY:0 activePart:&part atTime:time];Check(part==1,@"Enabled selection accepts a finite normalized object point");
    [osc hitTestOSCAtMousePositionX:1000 mousePositionY:0 activePart:&part atTime:time];Check(part==0,@"Outside-object hit test is empty");
    [osc hitTestOSCAtMousePositionX:NAN mousePositionY:0 activePart:&part atTime:time];Check(part==0,@"Nonfinite hit coordinates are rejected");
    [osc hitTestOSCAtMousePositionX:0 mousePositionY:0 activePart:NULL atTime:time];Check(YES,@"Null hit-test output is safe");
    [osc mouseDownAtPositionX:0 positionY:0 activePart:0 modifiers:0 forceUpdate:&update atTime:time];Check(!update && api.writes==0,@"Inactive part does not start selection");
    update=YES;[osc mouseUpAtPositionX:0 positionY:0 activePart:1 modifiers:0 forceUpdate:&update atTime:time];Check(!update && api.undoEnds==0,@"Mouse-up without mouse-down leaves undo balanced");
    [osc mouseDownAtPositionX:.25 positionY:.75 activePart:1 modifiers:0 forceUpdate:&update atTime:time];Check(update && fabs(api.lastX-.25)<1e-8 && fabs(api.lastY-.75)<1e-8,@"OBJECT mouse-down writes normalized point coordinates directly");
    Check(CMTimeCompare(api.lastTime,time)==0 && api.undoStarts==1,@"Selection writes use callback time and open one undo group");
    [osc mouseDraggedAtPositionX:500 positionY:-500 activePart:1 modifiers:0 forceUpdate:&update atTime:time];Check(update && api.lastX==1 && api.lastY==0,@"Dragging clamps normalized selection to the source");
    [osc mouseUpAtPositionX:0 positionY:0 activePart:1 modifiers:0 forceUpdate:&update atTime:time];Check(update && api.undoEnds==1,@"Gesture completes its matching undo group");
    NSUInteger writes=api.writes;[osc mouseDraggedAtPositionX:0 positionY:0 activePart:1 modifiers:0 forceUpdate:&update atTime:time];Check(!update && api.writes==writes,@"Stray drag after release writes nothing");
    api.bounds=CGRectMake(0,0,NAN,100);[osc hitTestOSCAtMousePositionX:.5 mousePositionY:.5 activePart:&part atTime:time];Check(part==1,@"Normalized hit testing does not depend on document pixel bounds");
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
    [osc mouseDownAtPositionX:.8 positionY:.3 activePart:1 modifiers:0 forceUpdate:&update atTime:time];
    [osc mouseUpAtPositionX:.8 positionY:.3 activePart:1 modifiers:0 forceUpdate:&update atTime:time];
    [osc drawOSCWithWidth:1921 height:1080 activePart:0 destinationImage:tile atTime:time];
    Check(fabs(api.x-.8)<1e-8 && fabs(api.y-.3)<1e-8 && AlphaAt(tile,256,72)>.9,@"Click writes normalized selection and redraws the handle at that point");
    PGOSCAPI *motion=[PGOSCAPI new];motion.pixelSetter=YES;motion.bounds=CGRectMake(-1920,-1080,3840,2160);
    PGFaceSelectOSC *motionOSC=[[PGFaceSelectOSC alloc] initWithAPIManager:motion];
    [motionOSC mouseDownAtPositionX:.8 positionY:.3 activePart:1 modifiers:0 forceUpdate:&update atTime:time];
    Check(update && fabs(motion.x-.8)<1e-5 && fabs(motion.y-.3)<1e-5,@"Motion pixel-setter bridge is detected by verified parameter readback");
    Check(motion.writes==2 && fabs(motion.lastX-1152)<1e-5 && fabs(motion.lastY+432)<1e-5,@"Detected bridge receives the centered pixel inverse transform");
    NSUInteger beforeCached=motion.writes;
    [motionOSC mouseDraggedAtPositionX:.7 positionY:.4 activePart:1 modifiers:0 forceUpdate:&update atTime:time];
    Check(update && motion.writes==beforeCached+1 && fabs(motion.x-.7)<1e-5 && fabs(motion.y-.4)<1e-5,@"Pixel-setter mode is cached only on the same OSC instance");
    [motionOSC mouseUpAtPositionX:.7 positionY:.4 activePart:1 modifiers:0 forceUpdate:&update atTime:time];
    [motionOSC drawOSCWithWidth:3840 height:2160 activePart:0 destinationImage:tile atTime:time];
    Check(AlphaAt(tile,224,96)>.9,@"Motion-compatible setter and normalized drawing round-trip to the same visible point");
    Check(motion.undoStarts==1 && motion.undoEnds==1,@"Calibration writes remain in one balanced undo gesture");
    PGOSCAPI *bad=[PGOSCAPI new];bad.corruptReadback=YES;
    PGFaceSelectOSC *badOSC=[[PGFaceSelectOSC alloc] initWithAPIManager:bad];
    [badOSC mouseDownAtPositionX:.8 positionY:.3 activePart:1 modifiers:0 forceUpdate:&update atTime:time];
    Check(!update && bad.undoStarts==bad.undoEnds,@"Unrecognized readback response is reported as failure with balanced undo");
    printf("OSC adapter: %lu checks, %lu failures\n",(unsigned long)Checks,(unsigned long)Failures);return Failures?1:0;
}}
