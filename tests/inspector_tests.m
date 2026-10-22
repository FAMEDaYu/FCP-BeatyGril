#define main PGExistingHostAdapterMain
#include "host_adapter_tests.m"
#undef main
#import "PGInspectorView.h"

@interface PGInspectorTestAPI : PGHostAPI
@property NSUInteger accessViolations;
@property NSUInteger customWrites;
@property NSUInteger scalarWrites;
@property (strong) NSDictionary *actionBefore;
@property (strong) NSDictionary *undoValues;
@property BOOL parameterAPIsRequireAction;
@property BOOL actionRequiresView;
@property NSUInteger invalidActionSenders;
@property (weak) id lastActionSender;
@property NSUInteger previewPublications;
@property (strong) NSDictionary *previewValues;
@end
@implementation PGInspectorTestAPI
- (id)apiForProtocol:(Protocol *)protocol {
    NSString *name=NSStringFromProtocol(protocol);
    if(_parameterAPIsRequireAction && !self.actionDepth &&
       ([name isEqual:@"FxParameterRetrievalAPI_v6"] || [name isEqual:@"FxParameterSettingAPI_v5"]))return nil;
    return [super apiForProtocol:protocol];
}
- (void)guard {if(!self.actionDepth)_accessViolations++;}
- (void)startAction:(id)sender {
    _lastActionSender=sender;
    if(_actionRequiresView && ![sender isKindOfClass:NSView.class]){_invalidActionSenders++;return;}
    if(!self.actionDepth)_actionBefore=[self.values copy];[super startAction:sender];
}
- (void)endAction:(id)sender {
    if(self.actionDepth==1 && ![self.values isEqual:_actionBefore]) {
        _undoValues=_actionBefore;_previewValues=[self.values copy];_previewPublications++;
    }
    [super endAction:sender];
}
- (CMTime)currentTime {[self guard];return [super currentTime];}
- (BOOL)getCustomParameterValue:(NSObject **)v fromParameter:(UInt32)i atTime:(CMTime)t {[self guard];return [super getCustomParameterValue:v fromParameter:i atTime:t];}
- (BOOL)getFloatValue:(double *)v fromParameter:(UInt32)i atTime:(CMTime)t {[self guard];return [super getFloatValue:v fromParameter:i atTime:t];}
- (BOOL)getBoolValue:(BOOL *)v fromParameter:(UInt32)i atTime:(CMTime)t {[self guard];return [super getBoolValue:v fromParameter:i atTime:t];}
- (BOOL)getIntValue:(int *)v fromParameter:(UInt32)i atTime:(CMTime)t {[self guard];return [super getIntValue:v fromParameter:i atTime:t];}
- (BOOL)setCustomParameterValue:(NSObject<NSSecureCoding,NSCopying> *)v toParameter:(UInt32)i atTime:(CMTime)t {[self guard];_customWrites++;return [super setCustomParameterValue:v toParameter:i atTime:t];}
- (BOOL)setFloatValue:(double)v toParameter:(UInt32)i atTime:(CMTime)t {[self guard];_scalarWrites++;return [super setFloatValue:v toParameter:i atTime:t];}
- (BOOL)setBoolValue:(BOOL)v toParameter:(UInt32)i atTime:(CMTime)t {[self guard];_scalarWrites++;return [super setBoolValue:v toParameter:i atTime:t];}
- (BOOL)setIntValue:(int)v toParameter:(UInt32)i atTime:(CMTime)t {[self guard];_scalarWrites++;return [super setIntValue:v toParameter:i atTime:t];}
@end

static NSControl *FindControl(NSView *view,Class type,NSString *label) {
    if([view isKindOfClass:type] && [view.accessibilityLabel isEqual:label])return (NSControl *)view;
    for(NSView *child in view.subviews){NSControl *found=FindControl(child,type,label);if(found)return found;}return nil;
}
static void Fire(NSControl *control) {[control sendAction:control.action to:control.target];}
static BOOL Near(double a,double b) {return fabs(a-b)<.00001;}
static PGInspectorState *State(NSDictionary *values,NSSet *disabled) {
    return [PGInspectorState stateWithValues:values disabledParameters:disabled?:[NSSet set] hasEdits:YES];
}
static void RegistrationTests(void) {
    PGHostAPI *api=[PGHostAPI new];FCPBeautyGirlPlugIn *plugin=[[FCPBeautyGirlPlugIn alloc]initWithAPIManager:api];[plugin addParametersWithError:nil];
    NSUInteger visible=0;for(NSNumber *key in api.definitions){NSDictionary *d=api.definitions[key];if(!([d[@"flags"]unsignedIntValue]&kFxParameterFlag_HIDDEN)){visible++;Check(key.unsignedIntValue==PGInspectorPanel,@"only the custom panel is visible in the native parameter list");}}
    Check(visible==1,@"all duplicate standard controls and manual-analysis groups are hidden");
    FxParameterFlags flags=[api.definitions[@(PGInspectorPanel)][@"flags"]unsignedIntValue];
    Check((flags&kFxParameterFlag_CUSTOM_UI) && (flags&kFxParameterFlag_USE_FULL_VIEW_WIDTH),@"panel requests full-width custom UI");
    Check([plugin classForCustomParameterID:PGInspectorPanel]==PGInspectorState.class && [[plugin classesForCustomParameterID:PGInspectorPanel]containsObject:NSDictionary.class],@"host can securely decode the published state and its nested classes");
    for(NSNumber *key in @[@(PGAnalyzeForward),@(PGAnalyzeBackward),@(PGClearTrack)])Check(([api.definitions[key][@"flags"]unsignedIntValue]&(kFxParameterFlag_HIDDEN|kFxParameterFlag_DISABLED))==(kFxParameterFlag_HIDDEN|kFxParameterFlag_DISABLED),@"legacy analysis commands are hidden and disabled");
    Check([plugin createViewForParameterID:999]==nil,@"unknown parameter IDs do not create a second inspector");
    for(NSDictionary *d in PGInspectorControls()) {
        NSNumber *key=d[@"id"];Check(api.definitions[key]!=nil,@"every inspector control maps to an existing stable parameter ID");
        if([d[@"kind"]isEqual:@"slider"])Check(Near([d[@"min"]doubleValue],[api.definitions[key][@"min"]doubleValue]) && Near([d[@"max"]doubleValue],[api.definitions[key][@"max"]doubleValue]),@"UI and renderer enforce the same slider range");
    }
    NSMutableArray *smoothIDs=[NSMutableArray new];
    for(NSDictionary *d in PGInspectorControls())if([d[@"section"]isEqual:@"smooth"] && ![d[@"kind"]isEqual:@"master"])[smoothIDs addObject:d[@"id"]];
    Check([smoothIDs isEqual:@[@(PGMidtone),@(PGMicroDetail),@(PGFeatureProtectionAmount),@(PGNonSkinProtection)]],@"primary smoothing card exposes the four new controls in reference order");
    Check(PGInspectorDescriptor(PGFeatureProtect)==nil && [PGInspectorDescriptor(PGHighPass)[@"section"]isEqual:@"more"] && [PGInspectorDescriptor(PGSharpness)[@"section"]isEqual:@"more"],@"legacy boolean stays hidden while legacy global smoothing and sharpening remain available in more settings");
    api.values[@(PGTrackEnabled)]=@YES;api.values[@(PGSingleFace)]=@YES;api.values[@(PGShowMask)]=@YES;
    PGBeautySettings s=[plugin settingsAtTime:kCMTimeZero];Check(!s.trackingEnabled && !s.singleFace && !s.showMask,@"old manual analysis, selection and debug flags cannot override automatic output");
    NSData *snapshot=Snapshot(plugin,kCMTimeZero);NSDictionary *plist=[NSPropertyListSerialization propertyListWithData:snapshot options:0 format:nil error:nil];
    Check([plist[@"tracks"]isEqual:@[@"",@"",@""]],@"automatic render snapshots do not transfer persisted manual-analysis payloads");
}
static void BeautyControlModelTests(void) {
    PGInspectorState *defaults=State(@{},nil);
    Check([defaults valueForParameter:PGFeatureProtectionAmount]==1 && [defaults valueForParameter:PGNonSkinProtection]==1 && [defaults valueForParameter:PGMicroDetail]==0,@"new controls default to full five-feature/non-skin protection and zero micro detail");
    for(NSNumber *legacy in @[@NO,@YES]) {
        PGInspectorState *migrated=State(@{@(PGFeatureProtect):legacy,@(PGHighPass):@.63},nil);
        PGBeautySettings s=PGSettingsWithInspectorState(PGBeautyDefaults(),migrated);
        Check([migrated valueForParameter:PGFeatureProtectionAmount]==legacy.boolValue && s.featureProtection==legacy.boolValue && Near(s.highPassDetail,.63) && s.nonSkinProtection==1,@"old schema dictionaries migrate five-feature bool without reinterpreting legacy global smoothing");
    }
    PGInspectorState *explicit=State(@{@(PGFeatureProtect):@NO,@(PGFeatureProtectionAmount):@.37},nil);
    Check(Near([explicit valueForParameter:PGFeatureProtectionAmount],.37),@"an explicit numeric protection setting takes precedence over the old boolean");
    NSDictionary *values=@{@(PGFeatureProtectionAmount):@.25,@(PGNonSkinProtection):@.6,@(PGMicroDetail):@.8,@(PGMidtone):@.7,@(PGHighPass):@.4,@(PGSharpness):@.5,@(PGHue):@12,@(PGBrightness):@.3,@(PGTonePreset):@2};
    PGInspectorState *a=State(values,nil);
    NSData *archive=[NSKeyedArchiver archivedDataWithRootObject:a requiringSecureCoding:YES error:nil];
    PGInspectorState *restored=[NSKeyedUnarchiver unarchivedObjectOfClass:PGInspectorState.class fromData:archive error:nil];
    Check([restored isEqual:a] && Near([restored valueForParameter:PGFeatureProtectionAmount],.25) && Near([restored valueForParameter:PGNonSkinProtection],.6) && Near([restored valueForParameter:PGMicroDetail],.8),@"secure document archive retains all three independent numeric controls");
    NSMutableDictionary *right=[values mutableCopy];right[@(PGFeatureProtectionAmount)]=@.75;right[@(PGNonSkinProtection)]=@.2;right[@(PGMicroDetail)]=@.4;
    PGInspectorState *mid=(PGInspectorState *)[a interpolateBetween:State(right,nil) withWeight:.5];
    Check(Near([mid valueForParameter:PGFeatureProtectionAmount],.5) && Near([mid valueForParameter:PGNonSkinProtection],.4) && Near([mid valueForParameter:PGMicroDetail],.6),@"new floating-point protection and micro-detail keyframes interpolate independently");
    for(NSNumber *key in @[@(PGFeatureProtectionAmount),@(PGNonSkinProtection),@(PGMicroDetail)]) {
        PGInspectorState *bypassed=State(values,[NSSet setWithObject:key]);
        PGBeautySettings s=PGSettingsWithInspectorState(PGBeautyDefaults(),bypassed);
        Check(Near(s.featureProtectionAmount,key.unsignedIntValue==PGFeatureProtectionAmount?0:.25) && Near(s.nonSkinProtection,key.unsignedIntValue==PGNonSkinProtection?0:.6) && Near(s.microDetail,key.unsignedIntValue==PGMicroDetail?0:.8),@"each new bypass affects only its own render setting");
        Check(s.featureProtection==(s.featureProtectionAmount>0) && Near(s.skinHue,12) && Near(s.skinBrightness,.3) && s.skinTonePreset==2 && Near(s.highPassDetail,.4) && Near(s.sharpness,.5),@"protection bypass preserves color and legacy detail settings and derives the old feature bool");
    }
    NSMutableDictionary *off=[values mutableCopy];off[@(PGSmoothingEnabled)]=@0;
    PGBeautySettings s=PGSettingsWithInspectorState(PGBeautyDefaults(),State(off,nil));
    Check(s.amount==0 && s.midtoneDetail==0 && s.highPassDetail==0 && s.microDetail==0 && Near(s.skinHue,12) && Near(s.skinBrightness,.3),@"smoothing master bypass also disables micro detail while preserving color adjustments");
    PGInspectorState *untouched=[PGInspectorState stateWithValues:@{@(PGFeatureProtect):@NO} disabledParameters:[NSSet set] hasEdits:NO];
    PGBeautySettings original=PGBeautyDefaults();original.featureProtectionAmount=.8;original.nonSkinProtection=.2;original.microDetail=.7;
    PGBeautySettings result=PGSettingsWithInspectorState(original,untouched);
    Check(memcmp(&original,&result,sizeof(result))==0,@"an untouched migrated inspector still leaves existing document settings unchanged");
}
static void ModelTests(void) {
    PGInspectorState *plain=[PGInspectorState stateWithValues:@{} disabledParameters:[NSSet set] hasEdits:NO];
    PGBeautySettings original=PGBeautyDefaults();original.midtoneDetail=.5;original.faceChin=-.3;
    PGBeautySettings untouched=PGSettingsWithInspectorState(original,plain);
    Check(memcmp(&original,&untouched,sizeof(original))==0,@"untouched panel preserves a legacy document's exact settings");
    NSMutableDictionary *values=[plain.values mutableCopy];values[@(PGChin)]=@(-.6);values[@(PGBigEye)]=@.2;values[@(PGBrightness)]=@.37;values[@(PGTonePreset)]=@4;values[@(PGMidtone)]=@.7;
    PGInspectorState *a=[PGInspectorState stateWithValues:values disabledParameters:[NSSet setWithObject:@(PGBrightness)] hasEdits:YES];
    NSData *encoded=[NSKeyedArchiver archivedDataWithRootObject:a requiringSecureCoding:YES error:nil];
    PGInspectorState *decoded=[NSKeyedUnarchiver unarchivedObjectOfClass:PGInspectorState.class fromData:encoded error:nil];
    Check([decoded isEqual:a] && decoded!=a && decoded.hasEdits,@"secure host archive restores values, per-control bypass and edit state");
    Check([[a copy]isEqual:a] && a.hash==[[a copy]hash],@"copy and equality are stable for host undo snapshots");
    PGBeautySettings s=PGSettingsWithInspectorState(PGBeautyDefaults(),decoded);
    Check(Near(s.faceChin,-.6) && Near(s.faceBigEye,.2) && s.skinBrightness==0 && s.skinTonePreset==4,@"chin, eyes and bypass route to the correct independent render fields");
    NSMutableDictionary *bValues=[values mutableCopy];bValues[@(PGChin)]=@.6;bValues[@(PGTonePreset)]=@6;
    PGInspectorState *b=[PGInspectorState stateWithValues:bValues disabledParameters:[NSSet set] hasEdits:YES];
    PGInspectorState *mid=(PGInspectorState *)[a interpolateBetween:b withWeight:.5];
    Check(Near([mid valueForParameter:PGChin],0) && [mid valueForParameter:PGTonePreset]==4 && ![mid isParameterEnabled:PGBrightness],@"numeric keyframes interpolate while menu and enable states hold the preceding key");
    Check([[a interpolateBetween:b withWeight:0]isEqual:a] && [[a interpolateBetween:b withWeight:1]isEqual:b],@"keyframe endpoints restore exact independent states");
    Check([[plain interpolateBetween:b withWeight:.5]isEqual:plain],@"uncommitted legacy state does not invent a numeric transition before the first panel edit");
    NSDictionary *bad=@{@(PGChin):@9,@(PGTonePreset):@(-2),@(PGBrightness):@(NAN),@999:@.5};
    PGInspectorState *safe=[PGInspectorState stateWithValues:bad disabledParameters:[NSSet setWithObjects:@(PGRadius),@999,nil] hasEdits:YES];
    Check([safe valueForParameter:PGChin]==1 && [safe valueForParameter:PGTonePreset]==0 && [safe valueForParameter:PGBrightness]==0 && safe.values[@999]==nil && safe.disabledParameters.count==0,@"malformed controls are clamped, finite and limited to the supported schema");
    NSMutableDictionary *off=[a.values mutableCopy];off[@(PGShapeEnabled)]=@0;off[@(PGColorEnabled)]=@0;off[@(PGSmoothingEnabled)]=@0;off[@(PGTrackBoxes)]=@1;
    s=PGSettingsWithInspectorState(PGBeautyDefaults(),[PGInspectorState stateWithValues:off disabledParameters:[NSSet set] hasEdits:YES]);
    Check(s.faceChin==0 && s.faceBigEye==0 && s.skinBrightness==0 && s.skinTonePreset==0 && s.midtoneDetail==0 && s.highPassDetail==0 && s.showTrackBox==0,@"card eye switches bypass the complete associated effect group");
}
static void ControllerTests(void) {
    PGInspectorTestAPI *api=[PGInspectorTestAPI new];FCPBeautyGirlPlugIn *plugin=[[FCPBeautyGirlPlugIn alloc]initWithAPIManager:api];[plugin addParametersWithError:nil];
    api.values[@(PGMidtone)]=@.5;
    PGInspectorController *c=[[PGInspectorController alloc]initWithAPIManager:api];[c refresh];
    Check(c.available && Near([c.state valueForParameter:PGMidtone],.5) && !c.state.hasEdits,@"initial UI reads the current legacy/template values instead of replacing them");
    NSUInteger starts=api.actionStarts,writes=api.customWrites;
    [c beginInteraction];[c setValue:.1 forParameter:PGChin];[c setValue:.3 forParameter:PGChin];[c setValue:.5 forParameter:PGChin];[c endInteraction];
    Check(api.actionStarts==starts+1 && api.actionDepth==0 && api.customWrites==writes+3,@"an explicitly grouped controller transaction uses one balanced host action");
    Check(api.scalarWrites==3,@"continuous drags mirror only changed values rather than rewriting every hidden parameter");
    PGInspectorState *saved=api.values[@(PGInspectorPanel)];Check(saved.hasEdits && Near([saved valueForParameter:PGChin],.5) && Near([saved valueForParameter:PGMidtone],.5),@"published state contains the edited control and all untouched document values");
    NSUInteger before=api.customWrites;[c setValue:.5 forParameter:PGChin];Check(api.customWrites==before,@"an unchanged value does not create duplicate undo writes");
    PGInspectorController *restored=[[PGInspectorController alloc]initWithAPIManager:api];[restored refresh];Check([restored.state isEqual:saved],@"fresh inspector restores the full custom parameter state");
    [c setValue:.37 forParameter:PGBrightness];[c toggleEnabledForParameter:PGBrightness];
    Check(Near([c.state valueForParameter:PGBrightness],.37) && ![c.state isParameterEnabled:PGBrightness],@"eye bypass preserves the prior slider value");
    [c toggleEnabledForParameter:PGBrightness];Check([c.state isParameterEnabled:PGBrightness] && Near([c.state valueForParameter:PGBrightness],.37),@"reenabling restores the exact amount");
    [c toggleEnabledForParameter:PGBrightness];[c resetParameter:PGBrightness];Check([c.state isParameterEnabled:PGBrightness] && [c.state valueForParameter:PGBrightness]==0,@"reset restores default and clears that item's bypass");
    NSDictionary *unchanged=[api.values copy];PGInspectorState *old=[c.state copy];api.rejectedWriteParameter=PGInspectorPanel;
    Check(![c setValue:.9 forParameter:PGChin] && [api.values isEqual:unchanged] && [c.state isEqual:old] && c.statusMessage.length>0,@"rejected custom writes leave the UI and all render parameters unchanged");api.rejectedWriteParameter=0;
    Check(![c setValue:NAN forParameter:PGChin] && ![c setValue:.3 forParameter:999] && ![c toggleEnabledForParameter:PGRadius],@"invalid edits and unsupported bypass are safely rejected");
    [c setValue:-.4 forParameter:PGChin];NSDictionary *undo=api.undoValues;
    api.values=[undo mutableCopy];[[NSRunLoop currentRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.36]];[c refresh];
    Check(Near([c.state valueForParameter:PGChin],[old valueForParameter:PGChin]),@"host undo refresh restores the prior committed state after pending synchronization expires");
    Check(api.accessViolations==0 && api.actionDepth==0 && api.actionStarts==api.actionEnds,@"all arbitrary-time reads and writes are inside balanced FxPlug action pairs");
    [c setValue:.7 forParameter:PGBrightness];NSDictionary *beforeUndo=api.undoValues;
    api.values=[beforeUndo mutableCopy];[c setValue:.2 forParameter:PGThin];
    PGInspectorState *afterImmediateUndo=api.values[@(PGInspectorPanel)];
    PGInspectorState *undoneState=beforeUndo[@(PGInspectorPanel)];
    Check(Near([afterImmediateUndo valueForParameter:PGBrightness],[undoneState valueForParameter:PGBrightness]) && Near([afterImmediateUndo valueForParameter:PGThin],.2),@"a new gesture immediately after host undo cannot resurrect the undone value");
    NSMutableDictionary *seekValues=[c.state.values mutableCopy];seekValues[@(PGChin)]=@(-.8);seekValues[@(PGMidtone)]=@.6;
    api.values[@(PGInspectorPanel)]=[PGInspectorState stateWithValues:seekValues disabledParameters:[NSSet set] hasEdits:YES];api.hostTime=CMTimeAdd(api.hostTime,CMTimeMake(1,24));[c refresh];
    Check(Near([c.state valueForParameter:PGChin],-.8) && Near([c.state valueForParameter:PGMidtone],.6),@"seeking invalidates pending display state immediately at the new CMTime");
    [c setValue:.1 forParameter:PGBrightness];Check(Near([c.state valueForParameter:PGChin],-.8),@"new-time edits preserve the other controls from that time instead of a stale prior frame");
    api.values=[api.undoValues mutableCopy];[c documentDidChange];
    Check(Near([c.state valueForParameter:PGBrightness],[seekValues[@(PGBrightness)]doubleValue]),@"a host undo notification refreshes same-time state immediately without a timed wait");
    PGHostAPI *legacy=[PGHostAPI new];FCPBeautyGirlPlugIn *legacyPlugin=[[FCPBeautyGirlPlugIn alloc]initWithAPIManager:legacy];[legacyPlugin addParametersWithError:nil];
    legacy.values[@(PGDetailEnabled)]=@NO;legacy.values[@(PGHighPass)]=@.6;legacy.values[@(PGSharpness)]=@.4;
    PGInspectorController *imported=[[PGInspectorController alloc]initWithAPIManager:legacy];[imported refresh];[imported setValue:.3 forParameter:PGBrightness];
    PGBeautySettings migrated=PGSettingsWithInspectorState(PGBeautyDefaults(),imported.state);
    Check(migrated.highPassDetail==0 && migrated.sharpness==0 && Near([imported.state valueForParameter:PGHighPass],.6),@"first panel edit preserves disabled legacy detail controls and their stored amounts");
    legacy.values[@(PGInspectorPanel)]=[PGInspectorState stateWithValues:@{} disabledParameters:[NSSet set] hasEdits:NO];
    legacy.values[@(PGDetailEnabled)]=@YES;legacy.values[@(PGSmoothingEnabled)]=@NO;
    PGInspectorController *split=[[PGInspectorController alloc]initWithAPIManager:legacy];[split refresh];[split setValue:.2 forParameter:PGBrightness];
    PGBeautySettings splitSettings=PGSettingsWithInspectorState(PGBeautyDefaults(),split.state);
    Check(Near(splitSettings.highPassDetail,.6) && splitSettings.amount==0 && splitSettings.midtoneDetail==0,@"legacy global smoothing remains active when its old local-skin group was disabled");
    Check(api.forwardRequests==0 && api.backwardRequests==0,@"normal inspector edits never request manual analysis");
    [api.disabledAPIs addObject:@"FxCustomParameterActionAPI_v4"];
    PGInspectorController *offline=[[PGInspectorController alloc]initWithAPIManager:api];[offline refresh];
    Check(!offline.available && ![offline setValue:.2 forParameter:PGChin],@"missing host actions disable editing instead of unsafe parameter access");
}
static void ViewInteractionTests(void) {
    PGHostAPI *api=[PGHostAPI new];FCPBeautyGirlPlugIn *plugin=[[FCPBeautyGirlPlugIn alloc]initWithAPIManager:api];[plugin addParametersWithError:nil];
    PGInspectorView *view=(PGInspectorView *)[plugin createViewForParameterID:PGInspectorPanel];[view refreshFromHost];
    NSSlider *chin=(NSSlider *)FindControl(view,NSSlider.class,@"下巴");Check(chin!=nil && chin.enabled,@"custom view exposes an accessible native chin slider");
    chin.doubleValue=-.75;Fire(chin);PGInspectorState *s=api.values[@(PGInspectorPanel)];
    Check(Near([s valueForParameter:PGChin],-.75) && [s valueForParameter:PGBigEye]==0,@"actual chin slider events do not write the eye parameter");
    NSTextField *number=(NSTextField *)FindControl(view,NSTextField.class,@"下巴数值");number.stringValue=@"0.40";Fire(number);s=api.values[@(PGInspectorPanel)];Check(Near([s valueForParameter:PGChin],.4),@"editable numeric field writes its signed control");
    number.stringValue=@"invalid";Fire(number);s=api.values[@(PGInspectorPanel)];Check(Near([s valueForParameter:PGChin],.4),@"invalid number entry preserves the last valid value");
    NSMutableDictionary *changed=[s.values mutableCopy];changed[@(PGChin)]=@.8;
    api.values[@(PGInspectorPanel)]=[PGInspectorState stateWithValues:changed disabledParameters:s.disabledParameters hasEdits:YES];
    number.stringValue=@"0.40";Fire(number);s=api.values[@(PGInspectorPanel)];
    Check(Near([s valueForParameter:PGChin],.4),@"explicit input matching old UI cache still overrides a newer host value");
    // Return has already submitted .40. Losing focus after an external undo
    // must not send that old field text again and resurrect the undone value.
    changed=[s.values mutableCopy];changed[@(PGChin)]=@.8;
    api.values[@(PGInspectorPanel)]=[PGInspectorState stateWithValues:changed disabledParameters:s.disabledParameters hasEdits:YES];
    [number.delegate controlTextDidEndEditing:[NSNotification notificationWithName:NSControlTextDidEndEditingNotification object:number]];
    s=api.values[@(PGInspectorPanel)];
    Check(Near([s valueForParameter:PGChin],.8),@"focus loss after a submitted number does not resurrect an externally undone value");
    number.stringValue=@"0.65";
    [number.delegate controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:number]];
    [number.delegate controlTextDidEndEditing:[NSNotification notificationWithName:NSControlTextDidEndEditingNotification object:number]];
    s=api.values[@(PGInspectorPanel)];
    Check(Near([s valueForParameter:PGChin],.65),@"genuinely edited number still commits when focus leaves without Return");
    changed=[s.values mutableCopy];changed[@(PGChin)]=@.2;
    api.values[@(PGInspectorPanel)]=[PGInspectorState stateWithValues:changed disabledParameters:s.disabledParameters hasEdits:YES];
    [number.delegate controlTextDidEndEditing:[NSNotification notificationWithName:NSControlTextDidEndEditingNotification object:number]];
    s=api.values[@(PGInspectorPanel)];
    Check(Near([s valueForParameter:PGChin],.2),@"duplicate end-editing notifications do not create another parameter transaction");
    NSWindow *window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,380,900) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed=NO;window.contentView=view;
    [number selectText:nil];
    Check(number.currentEditor!=nil,@"offscreen AppKit window supplies a real field editor for Return handling");
    changed=[s.values mutableCopy];changed[@(PGChin)]=@.7;
    api.values[@(PGInspectorPanel)]=[PGInspectorState stateWithValues:changed disabledParameters:s.disabledParameters hasEdits:YES];
    [view hostParameterChanged];
    Check(Near([view.controller.state valueForParameter:PGChin],.7) && Near(number.doubleValue,.7),@"a focused but unmodified editor cannot hide a host undo or reset");
    number.stringValue=@"0.25";
    [number.delegate controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:number]];
    changed[@(PGChin)]=@.8;
    api.values[@(PGInspectorPanel)]=[PGInspectorState stateWithValues:changed disabledParameters:s.disabledParameters hasEdits:YES];
    [view hostParameterChanged];
    Check(Near(number.doubleValue,.25),@"host refresh preserves genuinely unsubmitted typing");
    Fire(number);
    Check(number.currentEditor==nil && Near([(PGInspectorState *)api.values[@(PGInspectorPanel)] valueForParameter:PGChin],.25),@"Return commits once and releases the actual AppKit editor before host commands");
    [window close];
    NSButton *preview=(NSButton *)FindControl(view,NSButton.class,@"检测框预览");preview.state=NSControlStateValueOn;Fire(preview);s=api.values[@(PGInspectorPanel)];Check([s valueForParameter:PGTrackBoxes]==1,@"preview switch events change the automatic face box setting");
    for(NSNumber *width in @[@280,@320,@380,@520]) {
        [view setFrameSize:NSMakeSize(width.doubleValue,20)];[view layoutSubtreeIfNeeded];
        Check(view.frame.size.height>500 && Near(view.frame.size.height,view.fittingSize.height) && Near(view.frame.size.height,view.intrinsicContentSize.height),@"width changes produce a complete consistent intrinsic/fitting height");
        for(NSView *card in view.subviews)if(!card.hidden)Check(NSMaxY(card.frame)<=NSHeight(view.bounds)+1 && NSMaxX(card.frame)<=NSWidth(view.bounds)+1,@"every visible card and footer remains inside the panel at all inspector widths");
    }
}
static void BeautyControlInteractionTests(void) {
    PGInspectorTestAPI *api=[PGInspectorTestAPI new];FCPBeautyGirlPlugIn *plugin=[[FCPBeautyGirlPlugIn alloc]initWithAPIManager:api];[plugin addParametersWithError:nil];
    api.values[@(PGFeatureProtectionAmount)]=@.37;api.values[@(PGHighPass)]=@.63;api.values[@(PGHue)]=@12;api.values[@(PGBrightness)]=@.3;
    PGInspectorView *view=(PGInspectorView *)[plugin createViewForParameterID:PGInspectorPanel];[view refreshFromHost];
    Check(Near([view.controller.state valueForParameter:PGFeatureProtectionAmount],.37) && !view.controller.state.hasEdits,@"an untouched inspector preserves native fractional protection when the legacy boolean is enabled");
    [view.controller setValue:.35 forParameter:PGBrightness];
    Check(Near([(PGInspectorState *)api.values[@(PGInspectorPanel)] valueForParameter:PGFeatureProtectionAmount],.37) && Near([api.values[@(PGFeatureProtectionAmount)]doubleValue],.37),@"first unrelated edit captures native fractional protection without replacing it with the legacy true value");
    api.values[@(PGInspectorPanel)]=[PGInspectorState stateWithValues:@{} disabledParameters:[NSSet set] hasEdits:NO];
    api.values[@(PGFeatureProtect)]=@NO;[view hostParameterChanged];
    Check([view.controller.state valueForParameter:PGFeatureProtectionAmount]==0 && !view.controller.state.hasEdits,@"untouched inspector imports the old host five-feature boolean into the new numeric control");
    [view.controller setValue:.35 forParameter:PGBrightness];
    Check(![api.values[@(PGFeatureProtect)]boolValue] && Near([view.controller.state valueForParameter:PGFeatureProtectionAmount],0),@"first unrelated edit preserves disabled legacy feature protection");
    NSArray *ids=@[@(PGFeatureProtectionAmount),@(PGNonSkinProtection),@(PGMicroDetail)],*names=@[@"五官保护",@"非肤色区保护",@"微细锐化"];
    for(NSUInteger i=0;i<ids.count;i++) {
        UInt32 key=[ids[i]unsignedIntValue];NSString *name=names[i];
        NSSlider *slider=(NSSlider *)FindControl(view,NSSlider.class,name);
        NSTextField *number=(NSTextField *)FindControl(view,NSTextField.class,[name stringByAppendingString:@"数值"]);
        Check(slider && number && slider.enabled && number.enabled,@"each new control exposes an enabled native slider and numeric field");
        number.stringValue=@"27%";Fire(number);
        Check(Near([view.controller.state valueForParameter:key],.27) && [number.stringValue isEqual:@"27%"],@"new numeric controls accept direct percentages without inverse interpretation");
        slider.doubleValue=.42;Fire(slider);
        Check(Near([view.controller.state valueForParameter:key],.42) && [number.stringValue isEqual:@"42%"],@"actual new slider events publish their direct amount and update the percentage display");
        NSButton *eye=(NSButton *)FindControl(view,NSButton.class,[@"启用 / 停用 · "stringByAppendingString:name]);Fire(eye);
        Check(![view.controller.state isParameterEnabled:key] && Near([view.controller.state valueForParameter:key],.42) && !slider.enabled,@"new individual bypass preserves its value and disables its native controls");
        if(key==PGFeatureProtectionAmount)Check(![api.values[@(PGFeatureProtect)]boolValue],@"bypassed numeric feature protection mirrors false into the legacy hidden boolean");
        NSButton *reset=(NSButton *)FindControl(view,NSButton.class,[@"重置 · "stringByAppendingString:name]);Fire(reset);
        Check([view.controller.state isParameterEnabled:key] && [view.controller.state valueForParameter:key]==(key==PGMicroDetail?0:1) && slider.enabled,@"new individual reset restores the proper default and clears bypass");
    }
    Check([api.values[@(PGFeatureProtect)]boolValue] && Near([view.controller.state valueForParameter:PGHighPass],.63) && Near([view.controller.state valueForParameter:PGHue],12) && Near([view.controller.state valueForParameter:PGBrightness],.35),@"new resets restore the legacy feature bool without modifying global smoothing, hue or brightness");
    NSButton *multi=(NSButton *)FindControl(view,NSButton.class,@"多人模式");Check([multi.toolTip containsString:@"易抖动"],@"multi-face mode exposes its instability notice as a tooltip");
    [view.controller setValue:.6 forParameter:PGMicroDetail];
    NSButton *master=(NSButton *)FindControl(view,NSButton.class,@"磨皮");master.state=NSControlStateValueOff;Fire(master);
    PGBeautySettings s=PGSettingsWithInspectorState(PGBeautyDefaults(),view.controller.state);
    Check(s.microDetail==0 && s.midtoneDetail==0 && s.highPassDetail==0 && Near(s.skinHue,12) && Near(s.skinBrightness,.35),@"actual smoothing master event disables new detail processing independently from whitening");
    master.state=NSControlStateValueOn;Fire(master);
    Check(Near(PGSettingsWithInspectorState(PGBeautyDefaults(),view.controller.state).microDetail,.6),@"reenabling the master restores the stored micro-detail amount");
    Check(api.actionDepth==0 && api.actionStarts==api.actionEnds && api.accessViolations==0,@"all new numeric, bypass, reset and master interactions use balanced host actions");
}
static void HostHandshakeTests(void) {
    PGInspectorTestAPI *api=[PGInspectorTestAPI new];FCPBeautyGirlPlugIn *plugin=[[FCPBeautyGirlPlugIn alloc]initWithAPIManager:api];[plugin addParametersWithError:nil];
    api.values[@(PGMidtone)]=@.5;
    api.parameterAPIsRequireAction=YES;api.actionRequiresView=YES;
    PGInspectorView *view=(PGInspectorView *)[plugin createViewForParameterID:PGInspectorPanel];[view refreshFromHost];
    Check(view.controller.available && Near([view.controller.state valueForParameter:PGMidtone],.5),@"an action-scoped host connects and reads the actual template values");
    Check(api.lastActionSender==view && api.invalidActionSenders==0,@"custom parameter actions identify their actual inspector NSView");
    NSSlider *brightness=(NSSlider *)FindControl(view,NSSlider.class,@"肤色亮度");
    Check(brightness.enabled,@"action-scoped parameter APIs do not leave the whole native panel disabled");
    brightness.doubleValue=.42;Fire(brightness);PGInspectorState *saved=api.values[@(PGInspectorPanel)];
    Check(saved.hasEdits && Near([saved valueForParameter:PGBrightness],.42),@"a connected native control writes through the action-scoped setting API");
    [api.disabledAPIs addObject:@"FxParameterSettingAPI_v5"];[view refreshFromHost];
    Check(!view.controller.available && api.actionDepth==0 && api.actionStarts==api.actionEnds,@"a genuinely missing setting API closes the already-started host action");
    [api.disabledAPIs removeObject:@"FxParameterSettingAPI_v5"];[view refreshFromHost];
    Check(view.controller.available && brightness.enabled,@"a later host connection restores controls after a transient API failure");
    Check(api.accessViolations==0 && api.actionDepth==0 && api.actionStarts==api.actionEnds,@"action-scoped connection, edits, failure and reconnection remain balanced");
}
static void ContinuousPreviewTests(void) {
    PGInspectorTestAPI *api=[PGInspectorTestAPI new];FCPBeautyGirlPlugIn *plugin=[[FCPBeautyGirlPlugIn alloc]initWithAPIManager:api];[plugin addParametersWithError:nil];
    api.parameterAPIsRequireAction=YES;api.actionRequiresView=YES;
    PGInspectorView *view=(PGInspectorView *)[plugin createViewForParameterID:PGInspectorPanel];[view refreshFromHost];
    NSArray *names=@[@"短脸",@"五官保护",@"非肤色区保护",@"微细锐化"],*ids=@[@(PGShort),@(PGFeatureProtectionAmount),@(PGNonSkinProtection),@(PGMicroDetail)];
    for(NSUInteger i=0;i<names.count;i++) {
        UInt32 key=[ids[i]unsignedIntValue];NSSlider *slider=(NSSlider *)FindControl(view,NSSlider.class,names[i]);
        void (^began)(void)=[slider valueForKey:@"interactionBegan"], (^ended)(void)=[slider valueForKey:@"interactionEnded"];
        Check(slider.continuous && began && ended,@"native slider emits continuous events and exposes balanced gesture callbacks");
        began();
        for(NSNumber *value in @[@.2,@.5,@1]) {
            NSUInteger publications=api.previewPublications;slider.doubleValue=value.doubleValue;Fire(slider);
            PGInspectorState *visible=api.previewValues[@(PGInspectorPanel)];
            Check(api.actionDepth==0 && api.previewPublications==publications+1 && Near([visible valueForParameter:key],value.doubleValue),@"every old and new slider step publishes a completed host snapshot before mouse-up");
            PGBeautySettings s=PGSettingsWithInspectorState(PGBeautyDefaults(),visible);
            double actual=key==PGShort?s.faceShort:key==PGFeatureProtectionAmount?s.featureProtectionAmount:key==PGNonSkinProtection?s.nonSkinProtection:s.microDetail;
            Check(visible && Near(actual,value.doubleValue),@"published frame settings contain each intermediate new protection/detail value while gesture is still open");
        }
        NSUInteger publications=api.previewPublications;Fire(slider);
        Check(api.previewPublications==publications,@"unchanged drag events do not enqueue redundant previews");
        ended();
    }
    Check(api.actionDepth==0 && api.actionStarts==api.actionEnds && api.accessViolations==0 && api.invalidActionSenders==0,@"step-wise publication preserves action-scoped APIs and the actual view sender");
}
static void OptionalInspectorPreview(void) {
    NSString *path=NSProcessInfo.processInfo.environment[@"PAINTFCP_INSPECTOR_PNG"];
    if(!path.length)return;
    PGHostAPI *api=[PGHostAPI new];FCPBeautyGirlPlugIn *plugin=[[FCPBeautyGirlPlugIn alloc]initWithAPIManager:api];[plugin addParametersWithError:nil];
    api.values[@(PGMidtone)]=@.4;
    PGInspectorView *view=(PGInspectorView *)[plugin createViewForParameterID:PGInspectorPanel];[view refreshFromHost];
    [view setFrameSize:NSMakeSize(380,20)];
    NSWindow *window=[[NSWindow alloc]initWithContentRect:view.bounds styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed=NO;window.appearance=[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];window.contentView=view;
    [window setContentSize:view.frame.size];[view layoutSubtreeIfNeeded];[window displayIfNeeded];
    NSBitmapImageRep *bitmap=[view bitmapImageRepForCachingDisplayInRect:view.bounds];
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];
    NSData *png=[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    Check(png.length>0 && [png writeToFile:path atomically:YES],@"optional offscreen inspector PNG is written to the requested review path");
    [window close];
}
int main(int argc,const char **argv) {@autoreleasepool {
    [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    RegistrationTests();ModelTests();BeautyControlModelTests();ControllerTests();ViewInteractionTests();BeautyControlInteractionTests();HostHandshakeTests();ContinuousPreviewTests();OptionalInspectorPreview();
    if(argc>2) {
        NSData *inner=[NSData dataWithContentsOfFile:@(argv[1])],*outer=[NSData dataWithContentsOfFile:@(argv[2])];NSError *error=nil;
        NSKeyedUnarchiver *reader=[[NSKeyedUnarchiver alloc]initForReadingFromData:inner error:&error];reader.requiresSecureCoding=YES;
        PGInspectorState *state=[reader decodeObjectOfClass:PGInspectorState.class forKey:@"Custom Data"];[reader finishDecoding];
        PGInspectorState *expected=[PGInspectorState stateWithValues:@{} disabledParameters:[NSSet set] hasEdits:NO];
        Check(!error && !reader.error && [state isEqual:expected],@"the template's actual Custom Data bytes securely decode to our untouched state class");
        NSKeyedUnarchiver *envelope=[[NSKeyedUnarchiver alloc]initForReadingFromData:outer error:&error];envelope.requiresSecureCoding=YES;
        NSData *payload=[envelope decodeObjectOfClass:NSData.class forKey:@"BlindDataObject"];
        NSNumber *legacy=[envelope decodeObjectOfClass:NSNumber.class forKey:@"DataIsLegacy"];[envelope finishDecoding];
        Check(!error && !envelope.error && legacy && !legacy.boolValue && [payload isEqual:inner],@"Foundation reads the Motion envelope as the exact secure custom payload");
    }
    printf("Inspector: %lu checks, %lu failures\n",(unsigned long)Checks,(unsigned long)Failures);return Failures?1:0;
}}
