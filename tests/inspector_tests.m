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
@end
@implementation PGInspectorTestAPI
- (void)guard {if(!self.actionDepth)_accessViolations++;}
- (void)startAction:(id)sender {if(!self.actionDepth)_actionBefore=[self.values copy];[super startAction:sender];}
- (void)endAction:(id)sender {if(self.actionDepth==1 && ![self.values isEqual:_actionBefore])_undoValues=_actionBefore;[super endAction:sender];}
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
static void RegistrationTests(void) {
    PGHostAPI *api=[PGHostAPI new];beatygrilPlugIn *plugin=[[beatygrilPlugIn alloc]initWithAPIManager:api];[plugin addParametersWithError:nil];
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
    api.values[@(PGTrackEnabled)]=@YES;api.values[@(PGSingleFace)]=@YES;api.values[@(PGShowMask)]=@YES;
    PGBeautySettings s=[plugin settingsAtTime:kCMTimeZero];Check(!s.trackingEnabled && !s.singleFace && !s.showMask,@"old manual analysis, selection and debug flags cannot override automatic output");
    NSData *snapshot=Snapshot(plugin,kCMTimeZero);NSDictionary *plist=[NSPropertyListSerialization propertyListWithData:snapshot options:0 format:nil error:nil];
    Check([plist[@"tracks"]isEqual:@[@"",@"",@""]],@"automatic render snapshots do not transfer persisted manual-analysis payloads");
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
    NSMutableDictionary *off=[a.values mutableCopy];off[@(PGShapeEnabled)]=@0;off[@(PGColorEnabled)]=@0;off[@(PGSmoothingEnabled)]=@0;
    s=PGSettingsWithInspectorState(PGBeautyDefaults(),[PGInspectorState stateWithValues:off disabledParameters:[NSSet set] hasEdits:YES]);
    Check(s.faceChin==0 && s.faceBigEye==0 && s.skinBrightness==0 && s.skinTonePreset==0 && s.midtoneDetail==0 && s.highPassDetail==0,@"card eye switches bypass the complete associated effect group");
}
static void ControllerTests(void) {
    PGInspectorTestAPI *api=[PGInspectorTestAPI new];beatygrilPlugIn *plugin=[[beatygrilPlugIn alloc]initWithAPIManager:api];[plugin addParametersWithError:nil];
    api.values[@(PGMidtone)]=@.5;
    PGInspectorController *c=[[PGInspectorController alloc]initWithAPIManager:api];[c refresh];
    Check(c.available && Near([c.state valueForParameter:PGMidtone],.5) && !c.state.hasEdits,@"initial UI reads the current legacy/template values instead of replacing them");
    NSUInteger starts=api.actionStarts,writes=api.customWrites;
    [c beginInteraction];[c setValue:.1 forParameter:PGChin];[c setValue:.3 forParameter:PGChin];[c setValue:.5 forParameter:PGChin];[c endInteraction];
    Check(api.actionStarts==starts+1 && api.actionDepth==0 && api.customWrites==writes+3,@"a full continuous drag uses one balanced host action");
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
    Check(api.forwardRequests==0 && api.backwardRequests==0,@"normal inspector edits never request manual analysis");
    [api.disabledAPIs addObject:@"FxCustomParameterActionAPI_v4"];
    PGInspectorController *offline=[[PGInspectorController alloc]initWithAPIManager:api];[offline refresh];
    Check(!offline.available && ![offline setValue:.2 forParameter:PGChin],@"missing host actions disable editing instead of unsafe parameter access");
}
static void ViewInteractionTests(void) {
    PGHostAPI *api=[PGHostAPI new];beatygrilPlugIn *plugin=[[beatygrilPlugIn alloc]initWithAPIManager:api];[plugin addParametersWithError:nil];
    PGInspectorView *view=(PGInspectorView *)[plugin createViewForParameterID:PGInspectorPanel];[view refreshFromHost];
    NSSlider *chin=(NSSlider *)FindControl(view,NSSlider.class,@"下巴");Check(chin!=nil && chin.enabled,@"custom view exposes an accessible native chin slider");
    chin.doubleValue=-.75;Fire(chin);PGInspectorState *s=api.values[@(PGInspectorPanel)];
    Check(Near([s valueForParameter:PGChin],-.75) && [s valueForParameter:PGBigEye]==0,@"actual chin slider events do not write the eye parameter");
    NSTextField *number=(NSTextField *)FindControl(view,NSTextField.class,@"下巴数值");number.stringValue=@"0.40";Fire(number);s=api.values[@(PGInspectorPanel)];Check(Near([s valueForParameter:PGChin],.4),@"editable numeric field writes its signed control");
    number.stringValue=@"invalid";Fire(number);s=api.values[@(PGInspectorPanel)];Check(Near([s valueForParameter:PGChin],.4),@"invalid number entry preserves the last valid value");
    NSButton *preview=(NSButton *)FindControl(view,NSButton.class,@"人脸框预览");preview.state=NSControlStateValueOn;Fire(preview);s=api.values[@(PGInspectorPanel)];Check([s valueForParameter:PGTrackBoxes]==1,@"preview switch events change the automatic face box setting");
    for(NSNumber *width in @[@280,@320,@380,@520]) {
        [view setFrameSize:NSMakeSize(width.doubleValue,20)];[view layoutSubtreeIfNeeded];
        Check(view.frame.size.height>500 && Near(view.frame.size.height,view.fittingSize.height) && Near(view.frame.size.height,view.intrinsicContentSize.height),@"width changes produce a complete consistent intrinsic/fitting height");
        for(NSView *card in view.subviews)if(!card.hidden)Check(NSMaxY(card.frame)<=NSHeight(view.bounds)+1 && NSMaxX(card.frame)<=NSWidth(view.bounds)+1,@"every visible card and footer remains inside the panel at all inspector widths");
    }
}
int main(void) {@autoreleasepool {
    [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    RegistrationTests();ModelTests();ControllerTests();ViewInteractionTests();
    printf("Inspector: %lu checks, %lu failures\n",(unsigned long)Checks,(unsigned long)Failures);return Failures?1:0;
}}
