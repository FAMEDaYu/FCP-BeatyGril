#import <FxPlug/FxPlugSDK.h>
#import <CoreImage/CoreImage.h>
#import <IOSurface/IOSurface.h>
#import "PGParameterIDs.h"

@interface PGFaceSelectOSC : NSObject <FxOnScreenControl_v4>
@property (assign) id<PROAPIAccessing> apiManager;
@end
@implementation PGFaceSelectOSC
- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)api {
    if((self=[super init])) _apiManager=api; return self;
}
- (FxDrawingCoordinates)drawingCoordinates {return kFxDrawingCoordinates_OBJECT;}
- (id<FxOnScreenControlAPI_v4>)oscAPI {return [_apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];}
- (BOOL)selectionEnabledAtTime:(CMTime)time {
    BOOL selected=NO;id<FxParameterRetrievalAPI_v6> api=[_apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    [api getBoolValue:&selected fromParameter:PGSingleFace atTime:time];return selected;
}
- (void)drawOSCWithWidth:(NSInteger)width height:(NSInteger)height activePart:(NSInteger)part destinationImage:(FxImageTile *)tile atTime:(CMTime)time {
    if(!tile.ioSurface||width<=0||height<=0) return;
    CIImage *output=[[CIImage imageWithColor:CIColor.clearColor] imageByCroppingToRect:CGRectMake(0,0,width,height)];
    if([self selectionEnabledAtTime:time]) {
        double x=.5,y=.5;
        id<FxParameterRetrievalAPI_v6> params=[_apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
        [params getXValue:&x YValue:&y fromParameter:PGSelection atTime:time];
        CGRect bounds=[[self oscAPI] objectBounds];double canvasX=width*.5,canvasY=height*.5;
        [[self oscAPI] convertPointFromSpace:kFxDrawingCoordinates_OBJECT fromX:bounds.origin.x+x*bounds.size.width fromY:bounds.origin.y+y*bounds.size.height toSpace:kFxDrawingCoordinates_CANVAS toX:&canvasX toY:&canvasY];
        CGFloat scale=MAX(1,[[self oscAPI] backingScaleFactor]);
        size_t surfaceW=IOSurfaceGetWidth((__bridge IOSurfaceRef)tile.ioSurface),surfaceH=IOSurfaceGetHeight((__bridge IOSurfaceRef)tile.ioSurface);
        CGFloat sx=(CGFloat)surfaceW/width,sy=(CGFloat)surfaceH/height;
        canvasX*=sx;canvasY*=sy;CGFloat radius=10*scale;
        CIColor *color=part?[CIColor colorWithRed:1 green:.8 blue:.2]:[CIColor colorWithRed:.1 green:.9 blue:.8];
        CIImage *ring=[CIFilter filterWithName:@"CIRadialGradient" withInputParameters:@{@"inputCenter":[CIVector vectorWithX:canvasX Y:canvasY],@"inputRadius0":@(radius-2),@"inputRadius1":@(radius),@"inputColor0":color,@"inputColor1":CIColor.clearColor}].outputImage;
        CIImage *hole=[CIFilter filterWithName:@"CIRadialGradient" withInputParameters:@{@"inputCenter":[CIVector vectorWithX:canvasX Y:canvasY],@"inputRadius0":@(radius-3),@"inputRadius1":@(radius-2),@"inputColor0":CIColor.blackColor,@"inputColor1":CIColor.whiteColor}].outputImage;
        ring=[ring imageByApplyingFilter:@"CIBlendWithMask" withInputParameters:@{kCIInputBackgroundImageKey:output,kCIInputMaskImageKey:hole}];
        CIImage *v=[[CIImage imageWithColor:color] imageByCroppingToRect:CGRectMake(canvasX-scale,canvasY-16*scale,2*scale,32*scale)];
        CIImage *h=[[CIImage imageWithColor:color] imageByCroppingToRect:CGRectMake(canvasX-16*scale,canvasY-scale,32*scale,2*scale)];
        output=[[h imageByCompositingOverImage:v] imageByCompositingOverImage:ring];
    }
    CIContext *context=[CIContext contextWithOptions:@{kCIContextCacheIntermediates:@NO}];
    size_t w=IOSurfaceGetWidth((__bridge IOSurfaceRef)tile.ioSurface),h=IOSurfaceGetHeight((__bridge IOSurfaceRef)tile.ioSurface);
    if(tile.imageOrigin==kFxImageOrigin_TOP_LEFT) output=[output imageByApplyingTransform:CGAffineTransformMake(1,0,0,-1,0,h)];
    [context render:output toIOSurface:(__bridge IOSurfaceRef)tile.ioSurface bounds:CGRectMake(0,0,w,h) colorSpace:tile.colorSpace];
}
- (void)hitTestOSCAtMousePositionX:(double)x mousePositionY:(double)y activePart:(NSInteger *)part atTime:(CMTime)time {
    if(part) *part=([self selectionEnabledAtTime:time]&&CGRectContainsPoint([[self oscAPI] objectBounds],CGPointMake(x,y)))?1:0;
}
- (void)setSelectionX:(double)x y:(double)y time:(CMTime)time update:(BOOL *)update {
    CGRect bounds=[[self oscAPI] objectBounds];if(bounds.size.width<=0||bounds.size.height<=0) return;
    id<FxParameterSettingAPI_v5> api=[_apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    BOOL ok=[api setXValue:MIN(1,MAX(0,(x-bounds.origin.x)/bounds.size.width)) YValue:MIN(1,MAX(0,(y-bounds.origin.y)/bounds.size.height)) toParameter:PGSelection atTime:time];
    if(update) *update=ok;
}
- (void)mouseDownAtPositionX:(double)x positionY:(double)y activePart:(NSInteger)part modifiers:(FxModifierKeys)keys forceUpdate:(BOOL *)update atTime:(CMTime)time {
    id<FxUndoAPI> undo=[_apiManager apiForProtocol:@protocol(FxUndoAPI)];[undo startUndoGroup:@"选择人脸"];
    [self setSelectionX:x y:y time:time update:update];
}
- (void)mouseDraggedAtPositionX:(double)x positionY:(double)y activePart:(NSInteger)part modifiers:(FxModifierKeys)keys forceUpdate:(BOOL *)update atTime:(CMTime)time {[self setSelectionX:x y:y time:time update:update];}
- (void)mouseUpAtPositionX:(double)x positionY:(double)y activePart:(NSInteger)part modifiers:(FxModifierKeys)keys forceUpdate:(BOOL *)update atTime:(CMTime)time {
    [self setSelectionX:x y:y time:time update:update];id<FxUndoAPI> undo=[_apiManager apiForProtocol:@protocol(FxUndoAPI)];[undo endUndoGroup];
}
- (void)keyDownAtPositionX:(double)x positionY:(double)y keyPressed:(unsigned short)key modifiers:(FxModifierKeys)modifiers forceUpdate:(BOOL *)update didHandle:(BOOL *)handled atTime:(CMTime)time {if(handled)*handled=NO;if(update)*update=NO;}
- (void)keyUpAtPositionX:(double)x positionY:(double)y keyPressed:(unsigned short)key modifiers:(FxModifierKeys)modifiers forceUpdate:(BOOL *)update didHandle:(BOOL *)handled atTime:(CMTime)time {if(handled)*handled=NO;if(update)*update=NO;}
@end
