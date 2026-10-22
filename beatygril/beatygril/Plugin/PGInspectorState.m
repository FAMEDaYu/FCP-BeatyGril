#import "PGInspectorState.h"
#import <math.h>
#import <stddef.h>
#import <os/log.h>

NSArray<NSDictionary *> *PGInspectorControls(void) {
    static NSArray *controls; static dispatch_once_t once;
    dispatch_once(&once, ^{
        PGBeautySettings defaults=PGBeautyDefaults();
        NSMutableArray *items=[NSMutableArray new];
#define ITEM(ID,NAME,FIELD,SECTION,KIND,FORMAT,MIN,MAX,BYPASS,STORAGE) \
        [items addObject:@{@"id":@(ID),@"name":@NAME,@"section":@SECTION,@"kind":@KIND,@"format":@FORMAT,@"min":@(MIN),@"max":@(MAX),@"default":@(defaults.FIELD),@"bypass":@(BYPASS),@"offset":@(offsetof(PGBeautySettings,FIELD)),@"storage":@STORAGE}]
        ITEM(PGSmoothingEnabled,"磨皮",featureProtection,"smooth","master","integer",0,1,NO,"master");
        ITEM(PGMidtone,"磨皮程度",midtoneDetail,"smooth","slider","percent",0,1,YES,"float");
        ITEM(PGMicroDetail,"微细锐化",microDetail,"smooth","slider","percent",0,1,YES,"float");
        ITEM(PGFeatureProtectionAmount,"五官保护",featureProtectionAmount,"smooth","slider","percent",0,1,YES,"float");
        ITEM(PGNonSkinProtection,"非肤色区保护",nonSkinProtection,"smooth","slider","percent",0,1,YES,"float");
        ITEM(PGColorEnabled,"美白",featureProtection,"color","master","integer",0,1,NO,"master");
        ITEM(PGTonePreset,"肤色",skinTonePreset,"color","preset","integer",0,6,NO,"uint");
        NSMutableDictionary *preset=[items.lastObject mutableCopy];
        preset[@"options"]=@[@"原色",@"自然白",@"冷白",@"暖白",@"红润白",@"小麦",@"古铜"];items[items.count-1]=preset;
        ITEM(PGBrightness,"肤色亮度",skinBrightness,"color","slider","percent",0,1,YES,"float");
        ITEM(PGTeeth,"白牙",teethWhitening,"color","slider","percent",0,1,YES,"float");
        ITEM(PGHue,"皮肤色相",skinHue,"color","slider","degrees",-30,30,YES,"float");
        ITEM(PGShapeEnabled,"瘦脸",featureProtection,"shape","master","integer",0,1,NO,"master");
        ITEM(PGTrackBoxes,"检测框预览",showTrackBox,"shape","toggle","integer",0,1,NO,"uint");
        ITEM(PGFastMulti,"多人模式",fastMultiFace,"shape","toggle","integer",0,1,NO,"uint");
        NSMutableDictionary *multi=[items.lastObject mutableCopy];
        multi[@"tooltip"]=@"多人模式易抖动，请谨慎使用";items[items.count-1]=multi;
        ITEM(PGThin,"瘦脸",faceThin,"shape","slider","signed",0,1,YES,"float");
        ITEM(PGBigEye,"大眼",faceBigEye,"shape","slider","signed",0,1,YES,"float");
        ITEM(PGShort,"短脸",faceShort,"shape","slider","signed",-1,1,YES,"float");
        ITEM(PGNarrow,"窄脸",faceNarrow,"shape","slider","signed",-1,1,YES,"float");
        ITEM(PGChin,"下巴",faceChin,"shape","slider","signed",-1,1,YES,"float");
        ITEM(PGVFace,"V脸",faceV,"shape","slider","signed",0,1,YES,"float");
        ITEM(PGJaw,"下颌骨",faceJaw,"shape","slider","signed",0,1,YES,"float");
        ITEM(PGCheekbone,"颧骨",faceCheekbone,"shape","slider","signed",0,1,YES,"float");
        ITEM(PGSmallHead,"小头",faceSmallHead,"shape","slider","signed",0,1,YES,"float");
        ITEM(PGSmallHeadRange,"小头范围",faceSmallHeadRange,"shape","slider","percent",0,1,NO,"float");
        ITEM(PGAmount,"磨皮强度",amount,"more","slider","percent",0,1,YES,"float");
        ITEM(PGHighPass,"全局磨皮",highPassDetail,"more","slider","percent",0,1,YES,"float");
        ITEM(PGRadius,"磨皮半径",radius,"more","slider","radius",1,30,NO,"float");
        ITEM(PGSaturation,"肤色饱和度",skinSaturation,"more","slider","percent",-100,100,YES,"float");
        ITEM(PGEvenTone,"均匀肤色",skinEvenTone,"more","slider","percent",0,1,YES,"float");
        ITEM(PGEyeBright,"眼睛提亮",eyeBrightening,"more","slider","percent",0,1,YES,"float");
        ITEM(PGSharpness,"锐化",sharpness,"more","slider","percent",0,1,YES,"float");
        ITEM(PGJumpGuard,"防跳脸范围",faceJumpGuardRange,"more","slider","percent",1,4,NO,"float");
        ITEM(PGMix,"整体混合",mix,"more","slider","percent",0,1,NO,"float");
#undef ITEM
        controls=[items copy];
    }); return controls;
}
NSDictionary *PGInspectorDescriptor(UInt32 identifier) {
    for(NSDictionary *d in PGInspectorControls()) if([d[@"id"] unsignedIntValue]==identifier) return d;
    return nil;
}
static double PGControlValue(id raw,NSDictionary *d) {
    double value=[raw isKindOfClass:NSNumber.class]?[raw doubleValue]:[d[@"default"] doubleValue];
    if(!isfinite(value)) value=[d[@"default"] doubleValue];
    value=fmin([d[@"max"] doubleValue],fmax([d[@"min"] doubleValue],value));
    if(![d[@"storage"] isEqual:@"float"]) value=round(value);
    return value;
}
@implementation PGInspectorState
+ (BOOL)supportsSecureCoding {return YES;}
+ (instancetype)stateWithValues:(NSDictionary *)values disabledParameters:(NSSet *)disabled hasEdits:(BOOL)edited {
    PGInspectorState *state=[self new]; NSMutableDictionary *safe=[NSMutableDictionary new];NSMutableSet *bypassed=[NSMutableSet new];
    for(NSDictionary *d in PGInspectorControls()) {
        NSNumber *key=d[@"id"];id raw=values[key];
        // Schema 1 documents stored five-feature protection as the legacy bool.
        // New numeric values win when present; old archives gain its exact 0/1.
        if(key.unsignedIntValue==PGFeatureProtectionAmount && !raw && [values[@(PGFeatureProtect)] isKindOfClass:NSNumber.class])
            raw=@([values[@(PGFeatureProtect)] boolValue]?1:0);
        safe[key]=@(PGControlValue(raw,d));
        if([d[@"bypass"] boolValue] && [disabled containsObject:key]) [bypassed addObject:key];
    }
    state->_values=[safe copy];state->_disabledParameters=[bypassed copy];state->_hasEdits=edited;return state;
}
- (instancetype)init {if((self=[super init])) {_values=@{};_disabledParameters=[NSSet set];}return self;}
- (instancetype)initWithCoder:(NSCoder *)coder {
    NSInteger version=[coder decodeIntegerForKey:@"schema"];
    if(version!=1) return nil;
    NSSet *classes=[NSSet setWithObjects:NSDictionary.class,NSNumber.class,nil];
    NSDictionary *values=[coder decodeObjectOfClasses:classes forKey:@"values"];
    NSSet *disabled=[coder decodeObjectOfClasses:[NSSet setWithObjects:NSSet.class,NSNumber.class,nil] forKey:@"disabled"];
    return [PGInspectorState stateWithValues:values?:@{} disabledParameters:disabled?:[NSSet set] hasEdits:[coder decodeBoolForKey:@"edited"]];
}
- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeInteger:1 forKey:@"schema"];[coder encodeObject:_values forKey:@"values"];
    [coder encodeObject:_disabledParameters forKey:@"disabled"];[coder encodeBool:_hasEdits forKey:@"edited"];
}
- (id)copyWithZone:(NSZone *)zone {return [PGInspectorState stateWithValues:_values disabledParameters:_disabledParameters hasEdits:_hasEdits];}
- (double)valueForParameter:(UInt32)identifier {NSDictionary *d=PGInspectorDescriptor(identifier);return d?PGControlValue(_values[@(identifier)],d):0;}
- (BOOL)isParameterEnabled:(UInt32)identifier {return ![_disabledParameters containsObject:@(identifier)];}
- (BOOL)isEqual:(id)object {
    if(object==self)return YES;
    if(![object isKindOfClass:PGInspectorState.class])return NO;
    PGInspectorState *other=object;return _hasEdits==other.hasEdits && [_values isEqual:other.values] && [_disabledParameters isEqual:other.disabledParameters];
}
- (NSUInteger)hash {return _values.hash ^ _disabledParameters.hash ^ _hasEdits;}
- (NSObject<NSSecureCoding,NSCopying> *)interpolateBetween:(NSObject<NSSecureCoding,NSCopying> *)rightValue withWeight:(float)weight {
    if(![rightValue isKindOfClass:PGInspectorState.class])return [self copy];
    PGInspectorState *right=(PGInspectorState *)rightValue;double t=isfinite(weight)?fmin(1,fmax(0,weight)):0;
    if(t==0)return [self copy];if(t==1)return [right copy];
    if(!_hasEdits || !right.hasEdits)return [self copy];
    NSMutableDictionary *values=[NSMutableDictionary new];
    for(NSDictionary *d in PGInspectorControls()) {
        UInt32 key=[d[@"id"] unsignedIntValue];double a=[self valueForParameter:key],b=[right valueForParameter:key];
        // Menus, switches and enable masks hold the preceding key until the
        // next key. Numeric slider values interpolate within their valid range.
        values[@(key)]=[d[@"storage"] isEqual:@"float"]?@(a+(b-a)*t):@(a);
    }
    return [PGInspectorState stateWithValues:values disabledParameters:_disabledParameters hasEdits:_hasEdits||right.hasEdits];
}
@end

PGBeautySettings PGSettingsWithInspectorState(PGBeautySettings s,PGInspectorState *state) {
    if(!state.hasEdits)return s;
    for(NSDictionary *d in PGInspectorControls()) {
        NSString *storage=d[@"storage"];if([storage isEqual:@"master"])continue;
        UInt32 key=[d[@"id"] unsignedIntValue];double value=[state valueForParameter:key];
        if(![state isParameterEnabled:key]) value=0;
        size_t offset=[d[@"offset"] unsignedIntegerValue];
        if([storage isEqual:@"float"]) *(float *)((uint8_t *)&s+offset)=value;
        else *(uint32_t *)((uint8_t *)&s+offset)=(uint32_t)value;
    }
    s.featureProtection=s.featureProtectionAmount>0;
    if(![state valueForParameter:PGSmoothingEnabled])s.amount=s.midtoneDetail=s.highPassDetail=s.microDetail=0;
    if(![state valueForParameter:PGColorEnabled]) {s.skinBrightness=s.skinHue=s.skinSaturation=s.skinEvenTone=s.teethWhitening=s.eyeBrightening=0;s.skinTonePreset=0;}
    if(![state valueForParameter:PGShapeEnabled]) {s.faceThin=s.faceBigEye=s.faceShort=s.faceNarrow=s.faceChin=s.faceV=s.faceJaw=s.faceCheekbone=s.faceSmallHead=0;s.showTrackBox=0;}
    return s;
}

@interface PGInspectorController ()
@property (nonatomic,strong,readwrite) PGInspectorState *state;
@property (nonatomic,readwrite) BOOL available;
@property (nonatomic,copy,readwrite) NSString *statusMessage;
@property (nonatomic,strong) id<PROAPIAccessing> manager;
@property (nonatomic,strong) id<FxCustomParameterActionAPI_v4> action;
@property (nonatomic) BOOL interacting;
@property (nonatomic) NSTimeInterval pendingUntil;
@property (nonatomic) CMTime pendingTime;
@property (nonatomic, strong) id activeSender;
@property (nonatomic) BOOL reportedConnection;
@property (nonatomic) BOOL reportedMissingAction;
@end
@implementation PGInspectorController
- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)manager {
    if((self=[super init])){_manager=manager;_state=[PGInspectorState stateWithValues:@{} disabledParameters:[NSSet set] hasEdits:NO];_statusMessage=@"";}
    return self;
}
- (BOOL)start {
    if(_interacting)return YES;
    _action=[_manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    if(!_action){
        _available=NO;_statusMessage=@"等待宿主连接";
        if(!_reportedMissingAction){os_log(OS_LOG_DEFAULT,"PGInspector action API unavailable manager=%{public}d viewSender=%{public}d onMain=%{public}d",_manager!=nil,_actionSender!=nil,NSThread.isMainThread);_reportedMissingAction=YES;}
        return NO;
    }
    // A native host can expose parameter APIs only after the custom view's
    // action has established its document context. Never gate startAction on
    // those APIs being available before entering the action.
    BOOL readBefore=NO,writeBefore=NO;
    if(!_reportedConnection){
        readBefore=[_manager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)]!=nil;
        writeBefore=[_manager apiForProtocol:@protocol(FxParameterSettingAPI_v5)]!=nil;
    }
    _activeSender=_actionSender ?: self;
    [_action startAction:_activeSender];_interacting=YES;
    @try {
        id retrieval=[_manager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
        id setting=[_manager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
        _available=retrieval && setting;
        if(!_reportedConnection){
            os_log(OS_LOG_DEFAULT,"PGInspector connection readBefore=%{public}d writeBefore=%{public}d readInAction=%{public}d writeInAction=%{public}d viewSender=%{public}d onMain=%{public}d",readBefore,writeBefore,retrieval!=nil,setting!=nil,[_activeSender isKindOfClass:NSView.class],NSThread.isMainThread);
            _reportedConnection=YES;
        }
        if(!_available){_statusMessage=@"等待宿主连接";[self finish];return NO;}
    } @catch(NSException *exception) {[self finish];@throw exception;}
    return YES;
}
- (void)finish {if(_interacting){_interacting=NO;[_action endAction:_activeSender];_action=nil;_activeSender=nil;}}
- (void)readAtTime:(CMTime)time {
    if(_pendingUntil && CMTimeCompare(time,_pendingTime)!=0)_pendingUntil=0;
    id<FxParameterRetrievalAPI_v6> api=[_manager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    NSObject *object=nil;[api getCustomParameterValue:&object fromParameter:PGInspectorPanel atTime:time];
    if([object isKindOfClass:PGInspectorState.class] && [(PGInspectorState *)object hasEdits]) {
        PGInspectorState *host=(PGInspectorState *)object;
        if([host isEqual:_state])_pendingUntil=0;
        if(!_pendingUntil || NSDate.timeIntervalSinceReferenceDate>=_pendingUntil)_state=[host copy];
        return;
    }
    if(_pendingUntil && NSDate.timeIntervalSinceReferenceDate<_pendingUntil)return;
    NSMutableDictionary *values=[NSMutableDictionary new];
    for(NSDictionary *d in PGInspectorControls()) {
        UInt32 key=[d[@"id"] unsignedIntValue];double value=[d[@"default"] doubleValue];
        if([d[@"kind"] isEqual:@"preset"]) {int menu=(int)value;if([api getIntValue:&menu fromParameter:key atTime:time])value=menu;}
        else if([d[@"kind"] isEqual:@"toggle"] || [d[@"kind"] isEqual:@"master"]) {BOOL on=value!=0;if([api getBoolValue:&on fromParameter:key atTime:time])value=on;}
        else [api getFloatValue:&value fromParameter:key atTime:time];
        values[@(key)]=@(value);
    }
    // The old bool can still disable protection. A true value must preserve a
    // numeric setting already read above; its registered default is one for
    // old documents that have no independently stored numeric parameter.
    BOOL legacyFeatureProtection=YES;
    if([api getBoolValue:&legacyFeatureProtection fromParameter:PGFeatureProtect atTime:time] && !legacyFeatureProtection)
        values[@(PGFeatureProtectionAmount)]=@0;
    BOOL legacyDetail=YES;[api getBoolValue:&legacyDetail fromParameter:PGDetailEnabled atTime:time];
    NSMutableSet *disabled=legacyDetail?[NSMutableSet set]:[NSMutableSet setWithObjects:@(PGHighPass),@(PGSharpness),nil];
    // Earlier versions put high-pass smoothing under a different group. Keep
    // its effective state when importing a document whose local-skin group was
    // off, rather than turning a still-active global effect off on first edit.
    if(![values[@(PGSmoothingEnabled)] boolValue] && legacyDetail && [values[@(PGHighPass)] doubleValue]>0) {
        values[@(PGSmoothingEnabled)]=@YES;
        [disabled addObject:@(PGMidtone)];[disabled addObject:@(PGAmount)];[disabled addObject:@(PGMicroDetail)];
    }
    _state=[PGInspectorState stateWithValues:values disabledParameters:disabled hasEdits:NO];
}
- (void)refresh {
    if(_interacting)return;
    if(![self start])return;
    @try {[self readAtTime:[_action currentTime]];_statusMessage=@"";} @finally {[self finish];}
}
- (void)documentDidChange {if(_interacting)return;_pendingUntil=0;[self refresh];}
- (void)beginInteraction {
    if(_interacting)return;
    if([self start]) {
        // A new gesture starts from the authoritative document, including an
        // immediate undo. The short pending hold only prevents display flicker;
        // it must never resurrect an undone value in a subsequent edit.
        _pendingUntil=0;[self readAtTime:[_action currentTime]];
    }
}
- (void)endInteraction {[self finish];}
- (BOOL)commit:(PGInspectorState *)next {
    if([next isEqual:_state] && _state.hasEdits)return YES;
    id<FxParameterSettingAPI_v5> api=[_manager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    CMTime time=[_action currentTime];
    // The published object is authoritative. Only mirror after its write was
    // accepted; a rejected write must never leave half-applied hidden values.
    if(![api setCustomParameterValue:next toParameter:PGInspectorPanel atTime:time]){_statusMessage=@"参数未能保存，请重试";return NO;}
    for(NSDictionary *d in PGInspectorControls()) {
        UInt32 key=[d[@"id"] unsignedIntValue];double value=[next valueForParameter:key];
        if(![next isParameterEnabled:key])value=0;
        double previous=[_state isParameterEnabled:key]?[_state valueForParameter:key]:0;
        if(previous==value)continue;
        if([d[@"kind"] isEqual:@"preset"]) [api setIntValue:(int)value toParameter:key atTime:time];
        else if([d[@"kind"] isEqual:@"toggle"] || [d[@"kind"] isEqual:@"master"]) [api setBoolValue:value!=0 toParameter:key atTime:time];
        else [api setFloatValue:value toParameter:key atTime:time];
    }
    BOOL featureProtection=[next isParameterEnabled:PGFeatureProtectionAmount] && [next valueForParameter:PGFeatureProtectionAmount]>0;
    id<FxParameterRetrievalAPI_v6> reader=[_manager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    BOOL previousProtection=!featureProtection;
    if(![reader getBoolValue:&previousProtection fromParameter:PGFeatureProtect atTime:time] || previousProtection!=featureProtection)
        [api setBoolValue:featureProtection toParameter:PGFeatureProtect atTime:time];
    _state=next;_pendingUntil=NSDate.timeIntervalSinceReferenceDate+.35;_pendingTime=time;_statusMessage=@"";return YES;
}
- (BOOL)setValue:(double)value forParameter:(UInt32)identifier {
    NSDictionary *d=PGInspectorDescriptor(identifier);if(!d || !isfinite(value))return NO;
    BOOL owned=!_interacting;if(owned)[self beginInteraction];if(!_interacting)return NO;
    BOOL ok=NO;@try {
        NSMutableDictionary *values=[_state.values mutableCopy];values[@(identifier)]=@(PGControlValue(@(value),d));
        ok=[self commit:[PGInspectorState stateWithValues:values disabledParameters:_state.disabledParameters hasEdits:YES]];
    } @finally {if(owned)[self finish];}return ok;
}
- (BOOL)toggleEnabledForParameter:(UInt32)identifier {
    NSDictionary *d=PGInspectorDescriptor(identifier);if(!d)return NO;
    if([d[@"kind"] isEqual:@"master"] || [d[@"kind"] isEqual:@"toggle"]) {
        BOOL owned=!_interacting;if(owned)[self beginInteraction];if(!_interacting)return NO;
        BOOL ok=NO;@try {ok=[self setValue:![_state valueForParameter:identifier] forParameter:identifier];}
        @finally {if(owned)[self finish];}return ok;
    }
    if(![d[@"bypass"] boolValue])return NO;
    BOOL owned=!_interacting;if(owned)[self beginInteraction];if(!_interacting)return NO;
    BOOL ok=NO;@try {
        NSMutableSet *disabled=[_state.disabledParameters mutableCopy];NSNumber *key=@(identifier);
        if([disabled containsObject:key])[disabled removeObject:key];else [disabled addObject:key];
        ok=[self commit:[PGInspectorState stateWithValues:_state.values disabledParameters:disabled hasEdits:YES]];
    } @finally {if(owned)[self finish];}return ok;
}
- (BOOL)resetParameter:(UInt32)identifier {
    NSDictionary *d=PGInspectorDescriptor(identifier);if(!d)return NO;
    BOOL owned=!_interacting;if(owned)[self beginInteraction];if(!_interacting)return NO;
    BOOL ok=NO;@try {
        NSMutableDictionary *values=[_state.values mutableCopy];values[@(identifier)]=d[@"default"];
        NSMutableSet *disabled=[_state.disabledParameters mutableCopy];[disabled removeObject:@(identifier)];
        ok=[self commit:[PGInspectorState stateWithValues:values disabledParameters:disabled hasEdits:YES]];
    } @finally {if(owned)[self finish];}return ok;
}
- (void)dealloc {if(_interacting)[_action endAction:_activeSender];}
@end
