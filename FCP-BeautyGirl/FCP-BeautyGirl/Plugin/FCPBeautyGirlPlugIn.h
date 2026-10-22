#import <Foundation/Foundation.h>
#import <FxPlug/FxPlugSDK.h>
#import "PGBeautyTypes.h"

@interface FCPBeautyGirlPlugIn : NSObject <FxTileableEffect, FxAnalyzer, FxCustomParameterViewHost_v2>
@property (nonatomic, assign) id<PROAPIAccessing> apiManager;
- (PGBeautySettings)settingsAtTime:(CMTime)time;
- (void)analyzeForward;
- (void)analyzeBackward;
- (void)clearTracking;
@end
