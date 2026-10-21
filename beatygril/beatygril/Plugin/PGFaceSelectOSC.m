#import <FxPlug/FxPlugSDK.h>
#import <CoreImage/CoreImage.h>
#import <IOSurface/IOSurface.h>
#import "PGParameterIDs.h"
#include <math.h>

@interface PGFaceSelectOSC : NSObject <FxOnScreenControl_v4>
@property (assign) id<PROAPIAccessing> apiManager;
@property BOOL dragging;
@property BOOL undoOpen;
@property BOOL pointSetterUsesPixels;
@property BOOL loggedCoordinates;
@property BOOL loggedPointSetter;
@end
@implementation PGFaceSelectOSC
- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)api {
    if((self=[super init])) _apiManager=api; return self;
}
- (FxDrawingCoordinates)drawingCoordinates {return kFxDrawingCoordinates_OBJECT;}
- (id<FxOnScreenControlAPI_v4>)oscAPI {return [_apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];}
- (BOOL)selectionEnabledAtTime:(CMTime)time {
    BOOL selected=NO;id<FxParameterRetrievalAPI_v6> api=[_apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    return api && [api getBoolValue:&selected fromParameter:PGSingleFace atTime:time] && selected;
}
- (void)drawOSCWithWidth:(NSInteger)width height:(NSInteger)height activePart:(NSInteger)part destinationImage:(FxImageTile *)tile atTime:(CMTime)time {
    if(!tile.ioSurface||width<=0||height<=0) return;
    size_t surfaceW=IOSurfaceGetWidth((__bridge IOSurfaceRef)tile.ioSurface),surfaceH=IOSurfaceGetHeight((__bridge IOSurfaceRef)tile.ioSurface);
    if(!surfaceW||!surfaceH) return;
    CIImage *output=[[CIImage imageWithColor:CIColor.clearColor] imageByCroppingToRect:CGRectMake(0,0,surfaceW,surfaceH)];
    if([self selectionEnabledAtTime:time] && [self oscAPI]) {
        double x=.5,y=.5;
        id<FxParameterRetrievalAPI_v6> params=[_apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
        BOOL valid=[params getXValue:&x YValue:&y fromParameter:PGSelection atTime:time] && isfinite(x) && isfinite(y);
        double canvasX=NAN,canvasY=NAN;
        // FxPlug OBJECT space is normalized 0..1, exactly like point parameters.
        // objectBounds is a pixel/document rectangle and must not be applied here.
        if(valid) [[self oscAPI] convertPointFromSpace:kFxDrawingCoordinates_OBJECT fromX:x fromY:y toSpace:kFxDrawingCoordinates_CANVAS toX:&canvasX toY:&canvasY];
        if(!_loggedCoordinates) {
            _loggedCoordinates=YES;
            CGRect objectBounds=[[self oscAPI] objectBounds];
            NSLog(@"PGFaceOSC coordinates selection=(%.9g,%.9g) objectBounds=(%.9g,%.9g,%.9g,%.9g) canvas=(%.9g,%.9g) surface=%zux%zu origin=%lu",
                  x,y,objectBounds.origin.x,objectBounds.origin.y,objectBounds.size.width,objectBounds.size.height,
                  canvasX,canvasY,surfaceW,surfaceH,(unsigned long)tile.imageOrigin);
        }
        // CANVAS coordinates address the OSC surface. Callback width/height can
        // describe the effect image and must not rescale the converted point.
        double backing=[[self oscAPI] backingScaleFactor];
        CGFloat scale=isfinite(backing)?MAX(1,backing):1;
        CGFloat radius=10*scale;
        if(valid && isfinite(canvasX) && isfinite(canvasY)) {
        CIColor *color=part?[CIColor colorWithRed:1 green:.8 blue:.2]:[CIColor colorWithRed:.1 green:.9 blue:.8];
        CIImage *ring=[CIFilter filterWithName:@"CIRadialGradient" withInputParameters:@{@"inputCenter":[CIVector vectorWithX:canvasX Y:canvasY],@"inputRadius0":@(radius-2),@"inputRadius1":@(radius),@"inputColor0":color,@"inputColor1":CIColor.clearColor}].outputImage;
        CIImage *hole=[CIFilter filterWithName:@"CIRadialGradient" withInputParameters:@{@"inputCenter":[CIVector vectorWithX:canvasX Y:canvasY],@"inputRadius0":@(radius-3),@"inputRadius1":@(radius-2),@"inputColor0":CIColor.blackColor,@"inputColor1":CIColor.whiteColor}].outputImage;
        ring=[ring imageByApplyingFilter:@"CIBlendWithMask" withInputParameters:@{kCIInputBackgroundImageKey:output,kCIInputMaskImageKey:hole}];
        CIImage *v=[[CIImage imageWithColor:color] imageByCroppingToRect:CGRectMake(canvasX-scale,canvasY-16*scale,2*scale,32*scale)];
        CIImage *h=[[CIImage imageWithColor:color] imageByCroppingToRect:CGRectMake(canvasX-16*scale,canvasY-scale,32*scale,2*scale)];
        output=[[h imageByCompositingOverImage:v] imageByCompositingOverImage:ring];
        }
    }
    CIContext *context=[CIContext contextWithOptions:@{kCIContextCacheIntermediates:@NO}];
    size_t w=IOSurfaceGetWidth((__bridge IOSurfaceRef)tile.ioSurface),h=IOSurfaceGetHeight((__bridge IOSurfaceRef)tile.ioSurface);
    if(tile.imageOrigin==kFxImageOrigin_TOP_LEFT) output=[output imageByApplyingTransform:CGAffineTransformMake(1,0,0,-1,0,h)];
    [context render:output toIOSurface:(__bridge IOSurfaceRef)tile.ioSurface bounds:CGRectMake(0,0,w,h) colorSpace:tile.colorSpace];
}
- (void)hitTestOSCAtMousePositionX:(double)x mousePositionY:(double)y activePart:(NSInteger *)part atTime:(CMTime)time {
    if(!part) return;*part=0;
    if(isfinite(x)&&isfinite(y)&&x>=0&&x<=1&&y>=0&&y<=1&&[self selectionEnabledAtTime:time]&&[self oscAPI]) *part=1;
}
- (BOOL)pointWrite:(id<FxParameterSettingAPI_v5>)setter x:(double)x y:(double)y time:(CMTime)time {
    return setter && isfinite(x) && isfinite(y) && [setter setXValue:x YValue:y toParameter:PGSelection atTime:time];
}
- (BOOL)readPoint:(id<FxParameterRetrievalAPI_v6>)reader x:(double *)x y:(double *)y time:(CMTime)time {
    return reader && [reader getXValue:x YValue:y fromParameter:PGSelection atTime:time] && isfinite(*x) && isfinite(*y);
}
- (BOOL)pointPixelSize:(CGSize *)size {
    id<FxOnScreenControlAPI_v4> api=[self oscAPI];if(!api || !size)return NO;
    CGRect bounds=[api objectBounds];
    if(!isfinite(bounds.size.width)||!isfinite(bounds.size.height)||bounds.size.width<=4||bounds.size.height<=4)return NO;
    *size=bounds.size;return YES;
}
- (void)setSelectionX:(double)x y:(double)y time:(CMTime)time update:(BOOL *)update {
    if(update) *update=NO;
    if(!isfinite(x)||!isfinite(y)) return;
    double nx=fmin(1,fmax(0,x)),ny=fmin(1,fmax(0,y));
    id<FxParameterSettingAPI_v5> setter=[_apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    id<FxParameterRetrievalAPI_v6> reader=[_apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    double previousX=NAN,previousY=NAN;
    if(!setter || ![self readPoint:reader x:&previousX y:&previousY time:time])return;
    CGSize pixels=CGSizeZero;
    if(_pointSetterUsesPixels && ![self pointPixelSize:&pixels])return;
    double rawX=_pointSetterUsesPixels ? (nx-.5)*pixels.width : nx;
    double rawY=_pointSetterUsesPixels ? (ny-.5)*pixels.height : ny;
    BOOL accepted=[self pointWrite:setter x:rawX y:rawY time:time];
    BOOL changed=accepted,pixelUnits=_pointSetterUsesPixels;
    double actualX=NAN,actualY=NAN;
    BOOL readBack=accepted && [self readPoint:reader x:&actualX y:&actualY time:time];
    const double tolerance=0.00001;
    BOOL verified=readBack && fabs(actualX-nx)<=tolerance && fabs(actualY-ny)<=tolerance;
    // Motion's FxPlug 4 bridge can normalize point reads while its setter still
    // writes centered pixel values directly to OZChannel2D. Detect that exact
    // response instead of choosing units from the app version or coordinate size.
    if(readBack && !verified && !_pointSetterUsesPixels && [self pointPixelSize:&pixels] &&
       fabs(actualX-(.5+nx/pixels.width))<=tolerance &&
       fabs(actualY-(.5+ny/pixels.height))<=tolerance) {
        pixelUnits=YES;
        rawX=(nx-.5)*pixels.width;rawY=(ny-.5)*pixels.height;
        accepted=[self pointWrite:setter x:rawX y:rawY time:time];changed=changed||accepted;
        actualX=actualY=NAN;
        readBack=accepted && [self readPoint:reader x:&actualX y:&actualY time:time];
        verified=readBack && fabs(actualX-nx)<=tolerance && fabs(actualY-ny)<=tolerance;
        if(verified)_pointSetterUsesPixels=YES;
    }
    if(!verified && changed) {
        // Restore the previous point when verification fails. A failure must not
        // look like a successful drag or silently retain the calibration point.
        double restoreX=pixelUnits ? (previousX-.5)*pixels.width : previousX;
        double restoreY=pixelUnits ? (previousY-.5)*pixels.height : previousY;
        [self pointWrite:setter x:restoreX y:restoreY time:time];
    }
    if(!_loggedPointSetter) {
        _loggedPointSetter=YES;
        NSLog(@"PGFaceOSC point-write desired=(%.9g,%.9g) setter=(%.9g,%.9g) readback=(%.9g,%.9g) mode=%@ verified=%d",
              nx,ny,rawX,rawY,actualX,actualY,_pointSetterUsesPixels?@"centered-pixels":@"normalized",verified);
    }
    if(update)*update=verified;
}
- (void)mouseDownAtPositionX:(double)x positionY:(double)y activePart:(NSInteger)part modifiers:(FxModifierKeys)keys forceUpdate:(BOOL *)update atTime:(CMTime)time {
    if(update) *update=NO;
    if(part!=1 || !isfinite(x) || !isfinite(y) || ![self selectionEnabledAtTime:time]) return;
    if(![self oscAPI]) return;
    id<FxUndoAPI> undo=[_apiManager apiForProtocol:@protocol(FxUndoAPI)];
    if(_undoOpen) [undo endUndoGroup];
    _undoOpen=[undo startUndoGroup:@"选择人脸"];
    BOOL changed=NO;[self setSelectionX:x y:y time:time update:&changed];
    _dragging=changed;
    if(!changed && _undoOpen) {[undo endUndoGroup];_undoOpen=NO;}
    if(update) *update=changed;
}
- (void)mouseDraggedAtPositionX:(double)x positionY:(double)y activePart:(NSInteger)part modifiers:(FxModifierKeys)keys forceUpdate:(BOOL *)update atTime:(CMTime)time {
    if(update) *update=NO;
    if(_dragging && part==1 && [self selectionEnabledAtTime:time]) [self setSelectionX:x y:y time:time update:update];
}
- (void)mouseUpAtPositionX:(double)x positionY:(double)y activePart:(NSInteger)part modifiers:(FxModifierKeys)keys forceUpdate:(BOOL *)update atTime:(CMTime)time {
    if(update) *update=NO;
    if(_dragging && part==1 && [self selectionEnabledAtTime:time]) [self setSelectionX:x y:y time:time update:update];
    _dragging=NO;
    if(_undoOpen) {id<FxUndoAPI> undo=[_apiManager apiForProtocol:@protocol(FxUndoAPI)];[undo endUndoGroup];_undoOpen=NO;}
}
- (void)keyDownAtPositionX:(double)x positionY:(double)y keyPressed:(unsigned short)key modifiers:(FxModifierKeys)modifiers forceUpdate:(BOOL *)update didHandle:(BOOL *)handled atTime:(CMTime)time {if(handled)*handled=NO;if(update)*update=NO;}
- (void)keyUpAtPositionX:(double)x positionY:(double)y keyPressed:(unsigned short)key modifiers:(FxModifierKeys)modifiers forceUpdate:(BOOL *)update didHandle:(BOOL *)handled atTime:(CMTime)time {if(handled)*handled=NO;if(update)*update=NO;}
@end
