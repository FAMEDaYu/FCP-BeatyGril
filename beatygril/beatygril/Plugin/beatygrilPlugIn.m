#import "beatygrilPlugIn.h"
#import "PGParameterIDs.h"
#import "PGBeautyRenderer.h"
#import "PGFaceProcessor.h"
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
#import <stddef.h>
#import <math.h>

typedef struct { UInt32 identifier; const char *name; size_t offset; float min, max, step; BOOL percent; } PGSlider;
#define PGS(ID, NAME, FIELD, MIN, MAX, STEP, PERCENT) {ID, NAME, offsetof(PGBeautySettings, FIELD), MIN, MAX, STEP, PERCENT}
static const PGSlider PGSliders[] = {
    PGS(PGAmount,"磨皮强度",amount,0,1,.01,YES),
    PGS(PGMidtone,"中频磨皮",midtoneDetail,0,1,.01,YES),
    PGS(PGRadius,"磨皮半径",radius,1,30,.5,NO),
    PGS(PGBrightness,"肤色提亮",skinBrightness,0,1,.01,YES),
    PGS(PGHue,"肤色色相",skinHue,-30,30,1,NO),
    PGS(PGSaturation,"肤色饱和度",skinSaturation,-100,100,1,NO),
    PGS(PGEvenTone,"均匀肤色",skinEvenTone,0,1,.01,YES),
    PGS(PGTeeth,"牙齿美白",teethWhitening,0,1,.01,YES),
    PGS(PGEyeBright,"眼睛提亮",eyeBrightening,0,1,.01,YES),
    PGS(PGHighPass,"高频细节平滑",highPassDetail,0,1,.01,YES),
    PGS(PGSharpness,"锐化",sharpness,0,1,.01,YES),
    PGS(PGThin,"瘦脸",faceThin,0,1,.01,YES),
    PGS(PGBigEye,"大眼",faceBigEye,0,1,.01,YES),
    PGS(PGShort,"短脸",faceShort,-1,1,.01,NO),
    PGS(PGNarrow,"窄脸",faceNarrow,-1,1,.01,NO),
    PGS(PGChin,"下巴",faceChin,-1,1,.01,NO),
    PGS(PGVFace,"V 脸",faceV,0,1,.01,YES),
    PGS(PGJaw,"下颌",faceJaw,0,1,.01,YES),
    PGS(PGCheekbone,"颧骨",faceCheekbone,0,1,.01,YES),
    PGS(PGSmallHead,"小头",faceSmallHead,0,1,.01,YES),
    PGS(PGSmallHeadRange,"小头范围",faceSmallHeadRange,0,1,.01,YES),
    PGS(PGThreshold,"蒙版阈值",maskThreshold,0,255,1,NO),
    PGS(PGSoftness,"蒙版柔度",maskSoftness,0,1,.01,YES),
    PGS(PGEdgeProtect,"边缘保护",maskEdgeProtect,0,1,.01,YES),
    PGS(PGJumpGuard,"防跳脸范围",faceJumpGuardRange,1,4,.05,NO),
    PGS(PGMix,"整体混合",mix,0,1,.01,YES),
};
#undef PGS

static BOOL PGFail(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:FxPlugErrorDomain code:kFxError_InvalidParameter
                                      userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}
static CIImage *PGImageFromTile(FxImageTile *tile) {
    if (!tile.ioSurface) return nil;
    NSDictionary *options = tile.colorSpace ? @{kCIImageColorSpace:(__bridge id)tile.colorSpace} : @{};
    CIImage *image = [CIImage imageWithIOSurface:(__bridge IOSurfaceRef)tile.ioSurface options:options];
    if (tile.imageOrigin == kFxImageOrigin_TOP_LEFT) {
        image = [image imageByApplyingTransform:CGAffineTransformMake(1,0,0,-1,0,image.extent.size.height)];
    }
    FxRect b = tile.tilePixelBounds;
    return [image imageByApplyingTransform:CGAffineTransformMakeTranslation(b.left,b.bottom)];
}

@interface beatygrilPlugIn ()
@property (strong) PGBeautyRenderer *beautyRenderer;
@property (strong) PGFaceProcessor *faceProcessor;
@property (strong) NSMutableDictionary<NSNumber *,CIContext *> *contexts;
@property PGBeautySettings analysisSettings;
@property CMTime analysisTime;
@property NSUInteger analyzedFrames;
@property BOOL analyzing;
@property (strong) NSArray<NSString *> *loadedTracks;
@end

@implementation beatygrilPlugIn
- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)manager {
    if ((self=[super init])) {
        _apiManager=manager;
        _beautyRenderer=[PGBeautyRenderer new]; _faceProcessor=[PGFaceProcessor new];
        _contexts=[NSMutableDictionary new]; _analysisSettings=PGBeautyDefaults();
        _analysisTime=kCMTimeZero;
    }
    return self;
}
- (BOOL)properties:(NSDictionary **)properties error:(NSError **)error {
    if (!properties) return PGFail(error,@"宿主未提供属性输出位置。");
    *properties=@{kFxPropertyKey_MayRemapTime:@NO,
                  kFxPropertyKey_PixelTransformSupport:@(kFxPixelTransform_ScaleTranslate),
                  kFxPropertyKey_VariesWhenParamsAreStatic:@NO,
                  @"NeedsFullBuffer":@YES, @"ChangesOutputSize":@NO,
                  kFxPropertyKey_DesiredProcessingColorInfo:@(kFxImageColorInfo_RGB_GAMMA_VIDEO)};
    return YES;
}
- (BOOL)addSlider:(UInt32)identifier api:(id<FxParameterCreationAPI_v5>)api {
    PGBeautySettings defaults=PGBeautyDefaults();
    for (NSUInteger i=0;i<sizeof(PGSliders)/sizeof(PGSlider);i++) {
        PGSlider spec=PGSliders[i]; if (spec.identifier!=identifier) continue;
        NSString *name=[NSString stringWithUTF8String:spec.name];
        float value=*(float *)((uint8_t *)&defaults+spec.offset);
        if (spec.percent) return [api addPercentSliderWithName:name parameterID:identifier defaultValue:value parameterMin:spec.min parameterMax:spec.max sliderMin:spec.min sliderMax:spec.max delta:spec.step parameterFlags:kFxParameterFlag_DEFAULT];
        return [api addFloatSliderWithName:name parameterID:identifier defaultValue:value parameterMin:spec.min parameterMax:spec.max sliderMin:spec.min sliderMax:spec.max delta:spec.step parameterFlags:kFxParameterFlag_DEFAULT];
    }
    return NO;
}
- (BOOL)addParametersWithError:(NSError **)error {
    id<FxParameterCreationAPI_v5> api=[_apiManager apiForProtocol:@protocol(FxParameterCreationAPI_v5)];
    if (!api) return PGFail(error,@"无法取得 FxPlug 参数创建接口。");
    __block BOOL ok=YES;
    void (^slider)(UInt32)=^(UInt32 identifier){ok=[self addSlider:identifier api:api]&&ok;};
    void (^toggle)(NSString *,UInt32,BOOL)=^(NSString *name,UInt32 identifier,BOOL value){ok=[api addToggleButtonWithName:name parameterID:identifier defaultValue:value parameterFlags:kFxParameterFlag_DEFAULT]&&ok;};
    void (^group)(NSString *,UInt32)=^(NSString *name,UInt32 identifier){ok=[api startParameterSubGroup:name parameterID:identifier parameterFlags:kFxParameterFlag_DEFAULT]&&ok;};
    void (^end)(void)=^{ok=[api endParameterSubGroup]&&ok;};
    group(@"磨皮",100); toggle(@"启用磨皮",PGSmoothingEnabled,YES);
    slider(PGAmount); slider(PGMidtone); slider(PGRadius); toggle(@"保护五官",PGFeatureProtect,YES); end();
    group(@"肤色",101); toggle(@"启用肤色",PGColorEnabled,YES);
    ok=[api addPopupMenuWithName:@"肤色风格" parameterID:PGTonePreset defaultValue:0 menuEntries:@[@"原色",@"自然白",@"冷白",@"暖白",@"红润白",@"小麦",@"古铜"] parameterFlags:0]&&ok;
    slider(PGBrightness); slider(PGHue); slider(PGSaturation); slider(PGEvenTone); slider(PGTeeth); slider(PGEyeBright); end();
    group(@"细节",102); toggle(@"启用细节",PGDetailEnabled,YES); slider(PGHighPass); slider(PGSharpness); end();
    group(@"脸型",103); toggle(@"启用脸型",PGShapeEnabled,YES);
    UInt32 shape[]={PGThin,PGBigEye,PGShort,PGNarrow,PGChin,PGVFace,PGJaw,PGCheekbone,PGSmallHead,PGSmallHeadRange};
    for(NSUInteger i=0;i<sizeof(shape)/sizeof(UInt32);i++) slider(shape[i]); end();
    group(@"人脸选择与跟踪",104); toggle(@"只处理选中人脸",PGSingleFace,NO);
    ok=[api addPointParameterWithName:@"选脸位置" parameterID:PGSelection defaultX:.5 defaultY:.5 parameterFlags:0]&&ok;
    toggle(@"多人高速模式",PGFastMulti,NO); slider(PGJumpGuard);
    toggle(@"使用跟踪数据",PGTrackEnabled,NO);
    ok=[api addPopupMenuWithName:@"跟踪目标" parameterID:PGTarget defaultValue:0 menuEntries:@[@"目标 1",@"目标 2",@"目标 3"] parameterFlags:kFxParameterFlag_NOT_ANIMATABLE]&&ok;
    ok=[api addPushButtonWithName:@"向前分析" parameterID:PGAnalyzeForward selector:@selector(analyzeForward) parameterFlags:0]&&ok;
    ok=[api addPushButtonWithName:@"向后分析" parameterID:PGAnalyzeBackward selector:@selector(analyzeBackward) parameterFlags:0]&&ok;
    ok=[api addPushButtonWithName:@"清除当前目标" parameterID:PGClearTrack selector:@selector(clearTracking) parameterFlags:0]&&ok;
    ok=[api addStringParameterWithName:@"跟踪状态" parameterID:PGStatus defaultValue:@"选择画面中的人脸后开始分析" parameterFlags:kFxParameterFlag_NOT_ANIMATABLE|kFxParameterFlag_DISABLED]&&ok;
    toggle(@"显示人脸框",PGFaceBoxes,NO); toggle(@"显示跟踪框",PGTrackBoxes,NO); end();
    group(@"蒙版与输出",105); slider(PGThreshold); slider(PGSoftness); slider(PGEdgeProtect);
    toggle(@"预览蒙版",PGShowMask,NO); toggle(@"反转蒙版",PGInvertMask,NO);
    ok=[api addPopupMenuWithName:@"蒙版通道" parameterID:PGDebugChannel defaultValue:0 menuEntries:@[@"皮肤",@"牙齿",@"眼睛"] parameterFlags:0]&&ok;
    slider(PGMix); end();
    for(UInt32 identifier=PGTrackData1;identifier<=PGTrackData3;identifier++)
        ok=[api addStringParameterWithName:@"分析数据" parameterID:identifier defaultValue:@"" parameterFlags:kFxParameterFlag_HIDDEN|kFxParameterFlag_NOT_ANIMATABLE]&&ok;
    return ok ? YES : PGFail(error,@"宿主未能创建完整的人像美化参数。");
}
- (PGBeautySettings)settingsAtTime:(CMTime)time {
    PGBeautySettings s=PGBeautyDefaults();
    id<FxParameterRetrievalAPI_v6> api=[_apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    if(!api) return s;
    for(NSUInteger i=0;i<sizeof(PGSliders)/sizeof(PGSlider);i++) {
        PGSlider spec=PGSliders[i]; double value=*(float *)((uint8_t *)&s+spec.offset);
        if([api getFloatValue:&value fromParameter:spec.identifier atTime:time] && isfinite(value))
            *(float *)((uint8_t *)&s+spec.offset)=(float)fmin(spec.max,fmax(spec.min,value));
    }
    struct {UInt32 identifier;size_t offset;} toggles[]={
        {PGFeatureProtect,offsetof(PGBeautySettings,featureProtection)}, {PGShowMask,offsetof(PGBeautySettings,showMask)},
        {PGInvertMask,offsetof(PGBeautySettings,invertMask)}, {PGFaceBoxes,offsetof(PGBeautySettings,showFaceBoxes)},
        {PGTrackBoxes,offsetof(PGBeautySettings,showTrackBox)}, {PGSingleFace,offsetof(PGBeautySettings,singleFace)},
        {PGFastMulti,offsetof(PGBeautySettings,fastMultiFace)}, {PGTrackEnabled,offsetof(PGBeautySettings,trackingEnabled)}};
    for(NSUInteger i=0;i<sizeof(toggles)/sizeof(toggles[0]);i++) {
        BOOL value=*(uint32_t *)((uint8_t *)&s+toggles[i].offset)!=0;
        [api getBoolValue:&value fromParameter:toggles[i].identifier atTime:time];
        *(uint32_t *)((uint8_t *)&s+toggles[i].offset)=value;
    }
    int value=0; [api getIntValue:&value fromParameter:PGTonePreset atTime:time]; s.skinTonePreset=MIN(6,MAX(0,value));
    value=0; [api getIntValue:&value fromParameter:PGDebugChannel atTime:time]; s.debugChannel=MIN(2,MAX(0,value));
    value=0; [api getIntValue:&value fromParameter:PGTarget atTime:time]; s.targetIndex=MIN(2,MAX(0,value));
    double x=.5,y=.5; [api getXValue:&x YValue:&y fromParameter:PGSelection atTime:time];
    s.selectionX=isfinite(x)?fmin(1,fmax(0,x)):.5; s.selectionY=isfinite(y)?fmin(1,fmax(0,y)):.5;
    BOOL enabled=YES;
    [api getBoolValue:&enabled fromParameter:PGSmoothingEnabled atTime:time]; if(!enabled) s.amount=s.midtoneDetail=0;
    enabled=YES; [api getBoolValue:&enabled fromParameter:PGColorEnabled atTime:time];
    if(!enabled) {s.skinBrightness=s.skinHue=s.skinSaturation=s.skinEvenTone=s.teethWhitening=s.eyeBrightening=0;s.skinTonePreset=0;}
    enabled=YES; [api getBoolValue:&enabled fromParameter:PGDetailEnabled atTime:time]; if(!enabled) s.highPassDetail=s.sharpness=0;
    enabled=YES; [api getBoolValue:&enabled fromParameter:PGShapeEnabled atTime:time];
    if(!enabled) s.faceThin=s.faceBigEye=s.faceShort=s.faceNarrow=s.faceChin=s.faceV=s.faceJaw=s.faceCheekbone=s.faceSmallHead=0;
    if(s.fastMultiFace) s.singleFace=0;
    return s;
}
- (NSArray<NSString *> *)trackStrings {
    id<FxParameterRetrievalAPI_v6> api=[_apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    NSMutableArray *tracks=[NSMutableArray new];
    for(UInt32 identifier=PGTrackData1;identifier<=PGTrackData3;identifier++) {
        NSString *value=@"";[api getStringParameterValue:&value fromParameter:identifier];
        [tracks addObject:value?:@""];
    }
    return tracks;
}
- (BOOL)pluginState:(NSData **)state atTime:(CMTime)time quality:(FxQuality)quality error:(NSError **)error {
    if(!state) return PGFail(error,@"缺少渲染状态输出位置。");
    if(![_apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)]) return PGFail(error,@"无法读取宿主参数。");
    PGBeautySettings s=[self settingsAtTime:time];
    @synchronized(self) {_analysisTime=time;}
    *state=[NSPropertyListSerialization dataWithPropertyList:@{@"settings":[NSData dataWithBytes:&s length:sizeof(s)],@"tracks":[self trackStrings]} format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    return *state!=nil;
}
- (BOOL)destinationImageRect:(FxRect *)rect sourceImages:(NSArray<FxImageTile *> *)sources destinationImage:(FxImageTile *)destination pluginState:(NSData *)state atTime:(CMTime)time error:(NSError **)error {
    if(!rect||sources.count==0) return PGFail(error,@"缺少输入图像。");
    *rect=sources.firstObject.imagePixelBounds;return YES;
}
- (BOOL)sourceTileRect:(FxRect *)rect sourceImageIndex:(NSUInteger)index sourceImages:(NSArray<FxImageTile *> *)sources destinationTileRect:(FxRect)destinationRect destinationImage:(FxImageTile *)destination pluginState:(NSData *)state atTime:(CMTime)time error:(NSError **)error {
    if(!rect||index>=sources.count) return PGFail(error,@"输入图像索引无效。");
    *rect=sources[index].imagePixelBounds;return YES;
}
- (CIContext *)contextForTile:(FxImageTile *)tile {
    NSNumber *key=@(tile.deviceRegistryID);
    @synchronized(_contexts) {
        if(!_contexts[key]) {
            id<MTLDevice> device=nil;
            for(id<MTLDevice> candidate in MTLCopyAllDevices()) if(candidate.registryID==tile.deviceRegistryID) {device=candidate;break;}
            if(!device) device=MTLCreateSystemDefaultDevice();
            if(!device) return nil;
            _contexts[key]=[CIContext contextWithMTLDevice:device options:@{kCIContextCacheIntermediates:@NO}];
        }
        return _contexts[key];
    }
}
- (BOOL)renderDestinationImage:(FxImageTile *)destination sourceImages:(NSArray<FxImageTile *> *)sources pluginState:(NSData *)state atTime:(CMTime)time error:(NSError **)error {
    @autoreleasepool {
        if(sources.count==0||!sources.firstObject.ioSurface||!destination.ioSurface||state.length>16*1024*1024) return PGFail(error,@"宿主传入的画面或状态无效。");
        NSDictionary *plist=[NSPropertyListSerialization propertyListWithData:state options:NSPropertyListImmutable format:nil error:error];
        if(![plist isKindOfClass:NSDictionary.class]||![plist[@"settings"] isKindOfClass:NSData.class]||[plist[@"settings"] length]!=sizeof(PGBeautySettings)) return PGFail(error,@"渲染状态版本无效。");
        PGBeautySettings s;[plist[@"settings"] getBytes:&s length:sizeof(s)];
        if(s.version!=1) return PGFail(error,@"此版本不支持保存的渲染状态。");
        CIImage *input=PGImageFromTile(sources.firstObject); if(!input) return PGFail(error,@"无法读取 IOSurface。");
        CIContext *context=[self contextForTile:destination]; if(!context) return PGFail(error,@"没有可用的 Metal 图形设备。");
        CIImage *output=nil;
        @synchronized(_faceProcessor) {
            NSArray *tracks=plist[@"tracks"];
            if(![tracks isKindOfClass:NSArray.class]||tracks.count!=3) return PGFail(error,@"跟踪状态无效。");
            if(![_loadedTracks isEqualToArray:tracks]) {
                for(NSUInteger i=0;i<3;i++) {
                    if(![tracks[i] isKindOfClass:NSString.class]) return PGFail(error,@"跟踪记录无效。");
                    [_faceProcessor setTrackingData:[[NSData alloc] initWithBase64EncodedString:tracks[i] options:0] forTarget:i];
                }
                _loadedTracks=[tracks copy];
            }
            PGFaceFrame *frame=[_faceProcessor processImage:input settings:s time:time error:error];
            if(!frame) return NO;
            output=[_beautyRenderer processImage:frame.image settings:s skinMask:frame.skinMask teethMask:frame.teethMask eyeMask:frame.eyeMask error:error];
        }
        if(!output) return NO;
        // Blend from the original frame so zero mix also disables geometry.
        if(s.mix<1 && !s.showMask) {
            output=[output imageByApplyingFilter:@"CIDissolveTransition" withInputParameters:@{kCIInputTargetImageKey:input,kCIInputTimeKey:@(1-s.mix)}];
        }
        FxRect b=destination.tilePixelBounds;
        output=[output imageByApplyingTransform:CGAffineTransformMakeTranslation(-b.left,-b.bottom)];
        size_t width=IOSurfaceGetWidth((__bridge IOSurfaceRef)destination.ioSurface),height=IOSurfaceGetHeight((__bridge IOSurfaceRef)destination.ioSurface);
        if(destination.imageOrigin==kFxImageOrigin_TOP_LEFT) output=[output imageByApplyingTransform:CGAffineTransformMake(1,0,0,-1,0,height)];
        @try {[context render:output toIOSurface:(__bridge IOSurfaceRef)destination.ioSurface bounds:CGRectMake(0,0,width,height) colorSpace:destination.colorSpace];}
        @catch(NSException *exception) {return PGFail(error,exception.reason?:@"图像处理失败。");}
        return YES;
    }
}
- (void)setStatus:(NSString *)status {
    id<FxParameterSettingAPI_v5> api=[_apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    [api setStringParameterValue:status toParameter:PGStatus];
}
- (void)startAnalysisForward:(BOOL)forward {
    NSError *error=nil;
    PGBeautySettings s=[self settingsAtTime:_analysisTime];
    @synchronized(_faceProcessor) {[_faceProcessor setTrackingData:nil forTarget:s.targetIndex];}
    _analysisSettings=s;_analysisSettings.trackingEnabled=1;_analysisSettings.singleFace=1;
    id<FxAnalysisAPI> api=[_apiManager apiForProtocol:@protocol(FxAnalysisAPI)];
    BOOL ok=forward?[api startForwardAnalysis:kFxAnalysisLocation_CPU error:&error]:[api startBackwardAnalysis:kFxAnalysisLocation_CPU error:&error];
    [self setStatus:ok?@"正在分析所选人脸…":(error.localizedDescription?:@"当前宿主不提供帧分析接口。")];
}
- (void)analyzeForward {[self startAnalysisForward:YES];}
- (void)analyzeBackward {[self startAnalysisForward:NO];}
- (void)clearTracking {
    PGBeautySettings s=[self settingsAtTime:_analysisTime];
    @synchronized(_faceProcessor) {[_faceProcessor setTrackingData:nil forTarget:s.targetIndex];_loadedTracks=nil;}
    id<FxParameterSettingAPI_v5> api=[_apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    [api setStringParameterValue:@"" toParameter:PGTrackData1+s.targetIndex];
    [self setStatus:@"已清除当前目标的分析数据"];
}
- (BOOL)desiredAnalysisTimeRange:(CMTimeRange *)desired forInputWithTimeRange:(CMTimeRange)range error:(NSError **)error {
    if(!desired) return PGFail(error,@"缺少分析时间范围。");*desired=range;return YES;
}
- (BOOL)setupAnalysisForTimeRange:(CMTimeRange)range frameDuration:(CMTime)duration error:(NSError **)error {
    _analyzedFrames=0;_analyzing=YES;return YES;
}
- (BOOL)analyzeFrame:(FxImageTile *)frame atTime:(CMTime)time error:(NSError **)error {
    CIImage *image=PGImageFromTile(frame);if(!image) return PGFail(error,@"无法读取分析帧。");
    BOOL ok=NO;
    @synchronized(_faceProcessor) {ok=[_faceProcessor analyzeImage:image settings:_analysisSettings time:time error:error];}
    if(ok) _analyzedFrames++;
    return ok;
}
- (BOOL)cleanupAnalysis:(NSError **)error {
    id<FxParameterSettingAPI_v5> api=[_apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    NSData *data=nil;
    @synchronized(_faceProcessor) {data=[_faceProcessor trackingDataForTarget:_analysisSettings.targetIndex];_loadedTracks=nil;}
    if(data) {
        if(![api setStringParameterValue:[data base64EncodedStringWithOptions:0] toParameter:PGTrackData1+_analysisSettings.targetIndex]) return PGFail(error,@"无法将分析数据保存到工程。");
        [api setBoolValue:YES toParameter:PGTrackEnabled atTime:_analysisTime];
    }
    [self setStatus:[NSString stringWithFormat:@"目标 %u：已分析 %lu 帧",_analysisSettings.targetIndex+1,(unsigned long)_analyzedFrames]];
    _analyzing=NO;return YES;
}
@end
