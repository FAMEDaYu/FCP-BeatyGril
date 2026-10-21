#import <AppKit/AppKit.h>
#import "PGInspectorState.h"

NS_ASSUME_NONNULL_BEGIN

/// Native inspector controls. Host access belongs exclusively to the controller.
@interface PGInspectorView : NSView
@property (nonatomic, strong, readonly) PGInspectorController *controller;
- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)manager;
/// Also permits a deterministic controller in an offscreen preview or test.
- (instancetype)initWithController:(PGInspectorController *)controller;
- (void)refreshFromHost;
@end

NS_ASSUME_NONNULL_END
