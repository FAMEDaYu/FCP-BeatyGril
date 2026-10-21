#import <FxPlug/FxPlugSDK.h>
#import <CoreImage/CoreImage.h>
#import <IOSurface/IOSurface.h>
#import "PGParameterIDs.h"
#include <math.h>

@interface PGFaceSelectOSC : NSObject <FxOnScreenControl_v4>
@property (assign) id<PROAPIAccessing> apiManager;
@property BOOL dragging;
@property BOOL undoOpen;
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
- (BOOL)validObjectBounds:(CGRect *)bounds {
    id<FxOnScreenControlAPI_v4> api=[self oscAPI];
    if(!api || !bounds) return NO;
    CGRect b=[api objectBounds];
    if(!isfinite(b.origin.x)||!isfinite(b.origin.y)||!isfinite(b.size.width)||!isfinite(b.size.height)||b.size.width<=0||b.size.height<=0) return NO;
    *bounds=b;return YES;
}
- (void)drawOSCWithWidth:(NSInteger)width height:(NSInteger)height activePart:(NSInteger)part destinationImage:(FxImageTile *)tile atTime:(CMTime)time {
    if(!tile.ioSurface||width<=0||height<=0) return;
    size_t surfaceW=IOSurfaceGetWidth((__bridge IOSurfaceRef)tile.ioSurface),surfaceH=IOSurfaceGetHeight((__bridge IOSurfaceRef)tile.ioSurface);
    if(!surfaceW||!surfaceH) return;
    CIImage *output=[[CIImage imageWithColor:CIColor.clearColor] imageByCroppingToRect:CGRectMake(0,0,surfaceW,surfaceH)];
    CGRect bounds=CGRectZero;
    if([self selectionEnabledAtTime:time] && [self validObjectBounds:&bounds]) {
        double x=.5,y=.5;
        id<FxParameterRetrievalAPI_v6> params=[_apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
        BOOL valid=[params getXValue:&x YValue:&y fromParameter:PGSelection atTime:time] && isfinite(x) && isfinite(y);
        double canvasX=NAN,canvasY=NAN;
        if(valid) [[self oscAPI] convertPointFromSpace:kFxDrawingCoordinates_OBJECT fromX:bounds.origin.x+x*bounds.size.width fromY:bounds.origin.y+y*bounds.size.height toSpace:kFxDrawingCoordinates_CANVAS toX:&canvasX toY:&canvasY];
        // CANVAS coordinates already address the OSC surface. Callback width and
        // height may describe the effect image and must not rescale this point.
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
    if(!part) return;*part=0;CGRect bounds=CGRectZero;
    if(isfinite(x)&&isfinite(y)&&[self selectionEnabledAtTime:time]&&[self validObjectBounds:&bounds]&&CGRectContainsPoint(bounds,CGPointMake(x,y))) *part=1;
}
- (void)setSelectionX:(double)x y:(double)y time:(CMTime)time update:(BOOL *)update {
    if(update) *update=NO;
    CGRect bounds=CGRectZero;
    if(!isfinite(x)||!isfinite(y)||![self validObjectBounds:&bounds]) return;
    id<FxParameterSettingAPI_v5> api=[_apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    BOOL ok=[api setXValue:MIN(1,MAX(0,(x-bounds.origin.x)/bounds.size.width)) YValue:MIN(1,MAX(0,(y-bounds.origin.y)/bounds.size.height)) toParameter:PGSelection atTime:time];
    if(update) *update=ok;
}
- (void)mouseDownAtPositionX:(double)x positionY:(double)y activePart:(NSInteger)part modifiers:(FxModifierKeys)keys forceUpdate:(BOOL *)update atTime:(CMTime)time {
    if(update) *update=NO;
    if(part!=1 || !isfinite(x) || !isfinite(y) || ![self selectionEnabledAtTime:time]) return;
    CGRect bounds=CGRectZero;if(![self validObjectBounds:&bounds]) return;
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
