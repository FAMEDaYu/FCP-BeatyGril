#import <Foundation/Foundation.h>
#import <FxPlug/FxPlugSDK.h>
#import "PGBeautyTypes.h"
#import "PGParameterIDs.h"

NS_ASSUME_NONNULL_BEGIN

/// The descriptor list is shared by UI, persistence and render settings.
/// Keys: id, name, section (smooth/color/shape/more), kind
/// (slider/toggle/preset/master), min, max, default, format, bypass.
FOUNDATION_EXPORT NSArray<NSDictionary *> *PGInspectorControls(void);
FOUNDATION_EXPORT NSDictionary * _Nullable PGInspectorDescriptor(UInt32 identifier);

@interface PGInspectorState : NSObject <NSSecureCoding, NSCopying, FxCustomParameterInterpolation_v2>
@property (nonatomic, copy, readonly) NSDictionary<NSNumber *, NSNumber *> *values;
@property (nonatomic, copy, readonly) NSSet<NSNumber *> *disabledParameters;
/// An untouched panel must not replace parameters from an existing document.
@property (nonatomic, readonly) BOOL hasEdits;
+ (instancetype)stateWithValues:(NSDictionary *)values disabledParameters:(NSSet *)disabled hasEdits:(BOOL)edited;
- (double)valueForParameter:(UInt32)identifier;
- (BOOL)isParameterEnabled:(UInt32)identifier;
@end

FOUNDATION_EXPORT PGBeautySettings PGSettingsWithInspectorState(PGBeautySettings settings, PGInspectorState * _Nullable state);

/// All arbitrary-time FxPlug parameter access is bracketed by host actions.
/// The published custom object owns the full UI state, so FCP save/undo does
/// not depend on unpublished parameters being mirrored by the template.
@interface PGInspectorController : NSObject
@property (nonatomic, strong, readonly) PGInspectorState *state;
@property (nonatomic, readonly) BOOL available;
@property (nonatomic, copy, readonly) NSString *statusMessage;
- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)manager;
- (void)refresh;
- (void)documentDidChange;
- (void)beginInteraction;
- (void)endInteraction;
- (BOOL)setValue:(double)value forParameter:(UInt32)identifier;
- (BOOL)toggleEnabledForParameter:(UInt32)identifier;
- (BOOL)resetParameter:(UInt32)identifier;
@end

NS_ASSUME_NONNULL_END
