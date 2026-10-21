//
//  beatygrilPlugIn.h
//  beatygril
//
//  Created by dayu on 2026/10/21.
//

#import <Foundation/Foundation.h>
#import <FxPlug/FxPlugSDK.h>

@interface beatygrilPlugIn : NSObject <FxTileableEffect>
@property (assign) id<PROAPIAccessing> apiManager;
@end
