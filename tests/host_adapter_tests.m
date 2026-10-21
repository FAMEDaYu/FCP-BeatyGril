#import <Foundation/Foundation.h>
#import <FxPlug/FxPlugSDK.h>
#import <CoreImage/CoreImage.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>
#import "beatygrilPlugIn.h"
#import "PGParameterIDs.h"

// This adapter simulates host callbacks, but uses real IOSurface buffers and the
// production FxPlug entry points. It does not simulate FCP plugin discovery/UI.
@interface PGHostAPI : NSObject <PROAPIAccessing>
@property NSMutableDictionary<NSNumber *, id> *values;
@property NSMutableDictionary<NSNumber *, NSDictionary *> *definitions;
@property NSMutableSet<NSString *> *disabledAPIs;
@property NSInteger depth;
@property BOOL duplicate;
@property UInt32 rejectedParameter;
@property CMTime hostTime;
@property CMTime lastReadTime;
@property CMTime lastSetBoolTime;
@property NSUInteger forwardRequests;
@property NSUInteger backwardRequests;
@property BOOL rejectAnalysis;
@property BOOL targetAtCurrentTime;
@property UInt32 rejectedWriteParameter;
@end

@implementation PGHostAPI
- (instancetype)init {
    if ((self = [super init])) {
        _values = [NSMutableDictionary dictionary]; _definitions = [NSMutableDictionary dictionary];
        _disabledAPIs = [NSMutableSet set]; _hostTime = CMTimeMake(120, 24);
    }
    return self;
}
- (id)apiForProtocol:(Protocol *)protocol {
    NSString *name = NSStringFromProtocol(protocol);
    if ([_disabledAPIs containsObject:name]) return nil;
    if ([@[@"FxParameterCreationAPI_v5", @"FxParameterRetrievalAPI_v6", @"FxParameterSettingAPI_v5", @"FxCustomParameterActionAPI_v4", @"FxAnalysisAPI"] containsObject:name]) return self;
    return nil;
}
- (BOOL)define:(UInt32)identifier kind:(NSString *)kind value:(id)value flags:(FxParameterFlags)flags extra:(NSDictionary *)extra {
    if (_definitions[@(identifier)]) _duplicate = YES;
    NSMutableDictionary *definition = [@{@"kind":kind, @"flags":@(flags)} mutableCopy];
    if (extra) [definition addEntriesFromDictionary:extra];
    _definitions[@(identifier)] = definition;
    if (value) _values[@(identifier)] = value;
    return identifier != _rejectedParameter;
}
- (BOOL)addFloatSliderWithName:(NSString *)name parameterID:(UInt32)identifier defaultValue:(double)value parameterMin:(double)minimum parameterMax:(double)maximum sliderMin:(double)sliderMin sliderMax:(double)sliderMax delta:(double)delta parameterFlags:(FxParameterFlags)flags {
    return [self define:identifier kind:@"float" value:@(value) flags:flags extra:@{@"name":name, @"min":@(minimum), @"max":@(maximum)}];
}
- (BOOL)addPercentSliderWithName:(NSString *)name parameterID:(UInt32)identifier defaultValue:(double)value parameterMin:(double)minimum parameterMax:(double)maximum sliderMin:(double)sliderMin sliderMax:(double)sliderMax delta:(double)delta parameterFlags:(FxParameterFlags)flags {
    return [self define:identifier kind:@"percent" value:@(value) flags:flags extra:@{@"name":name, @"min":@(minimum), @"max":@(maximum)}];
}
- (BOOL)addToggleButtonWithName:(NSString *)name parameterID:(UInt32)identifier defaultValue:(BOOL)value parameterFlags:(FxParameterFlags)flags {
    return [self define:identifier kind:@"toggle" value:@(value) flags:flags extra:@{@"name":name}];
}
- (BOOL)addPopupMenuWithName:(NSString *)name parameterID:(UInt32)identifier defaultValue:(int)value menuEntries:(NSArray *)entries parameterFlags:(FxParameterFlags)flags {
    return [self define:identifier kind:@"popup" value:@(value) flags:flags extra:@{@"name":name, @"entries":entries}];
}
- (BOOL)addPointParameterWithName:(NSString *)name parameterID:(UInt32)identifier defaultX:(double)x defaultY:(double)y parameterFlags:(FxParameterFlags)flags {
    return [self define:identifier kind:@"point" value:@[@(x), @(y)] flags:flags extra:@{@"name":name}];
}
- (BOOL)addPushButtonWithName:(NSString *)name parameterID:(UInt32)identifier selector:(SEL)selector parameterFlags:(FxParameterFlags)flags {
    return [self define:identifier kind:@"button" value:nil flags:flags extra:@{@"name":name, @"selector":NSStringFromSelector(selector)}];
}
- (BOOL)addStringParameterWithName:(NSString *)name parameterID:(UInt32)identifier defaultValue:(NSString *)value parameterFlags:(FxParameterFlags)flags {
    return [self define:identifier kind:@"string" value:value flags:flags extra:@{@"name":name}];
}
- (BOOL)startParameterSubGroup:(NSString *)name parameterID:(UInt32)identifier parameterFlags:(FxParameterFlags)flags {
    _depth++;
    return [self define:identifier kind:@"group" value:nil flags:flags extra:@{@"name":name}];
}
- (BOOL)endParameterSubGroup { _depth--; return _depth >= 0; }
- (BOOL)getFloatValue:(double *)value fromParameter:(UInt32)identifier atTime:(CMTime)time {
    _lastReadTime = time; id object = _values[@(identifier)];
    if (![object isKindOfClass:NSNumber.class]) return NO; *value = [object doubleValue]; return YES;
}
- (BOOL)getIntValue:(int *)value fromParameter:(UInt32)identifier atTime:(CMTime)time {
    _lastReadTime = time;
    if (identifier == PGTarget && _targetAtCurrentTime) { *value = CMTimeCompare(time, _hostTime) == 0 ? 2 : 0; return YES; }
    id object = _values[@(identifier)]; if (![object isKindOfClass:NSNumber.class]) return NO; *value = [object intValue]; return YES;
}
- (BOOL)getBoolValue:(BOOL *)value fromParameter:(UInt32)identifier atTime:(CMTime)time {
    _lastReadTime = time; id object = _values[@(identifier)];
    if (![object isKindOfClass:NSNumber.class]) return NO; *value = [object boolValue]; return YES;
}
- (BOOL)getXValue:(double *)x YValue:(double *)y fromParameter:(UInt32)identifier atTime:(CMTime)time {
    _lastReadTime = time; NSArray *point = _values[@(identifier)];
    if (![point isKindOfClass:NSArray.class] || point.count != 2) return NO;
    *x = [point[0] doubleValue]; *y = [point[1] doubleValue]; return YES;
}
- (BOOL)getStringParameterValue:(NSString **)value fromParameter:(UInt32)identifier {
    id object = _values[@(identifier)]; if (![object isKindOfClass:NSString.class]) return NO; *value = object; return YES;
}
- (BOOL)setStringParameterValue:(NSString *)value toParameter:(UInt32)identifier {
    if (identifier == _rejectedWriteParameter) return NO;
    _values[@(identifier)] = value; return YES;
}
- (BOOL)setBoolValue:(BOOL)value toParameter:(UInt32)identifier atTime:(CMTime)time { _lastSetBoolTime = time; _values[@(identifier)] = @(value); return YES; }
- (CMTime)currentTime { return _hostTime; }
- (BOOL)startForwardAnalysis:(FxAnalysisLocation)location error:(NSError **)error {
    _forwardRequests++; return !_rejectAnalysis;
}
- (BOOL)startBackwardAnalysis:(FxAnalysisLocation)location error:(NSError **)error {
    _backwardRequests++; return !_rejectAnalysis;
}
@end

@interface PGHostTile : FxImageTile
@property (strong) IOSurface *storage;
@property FxRect pixelBounds;
@property FxRect fullBounds;
@property FxImageOrigin origin;
@property uint64_t registry;
@property CGColorSpaceRef space;
@end
@implementation PGHostTile
- (IOSurface *)ioSurface { return _storage; }
- (FxRect)tilePixelBounds { return _pixelBounds; }
- (FxRect)imagePixelBounds { return _fullBounds; }
- (FxImageOrigin)imageOrigin { return _origin; }
- (uint64_t)deviceRegistryID { return _registry; }
- (CGColorSpaceRef)colorSpace { return _space; }
- (void)dealloc { if (_space) CGColorSpaceRelease(_space); }
@end

static NSUInteger Checks = 0, Failures = 0;
static BOOL RectEqual(FxRect a, FxRect b) { return a.left == b.left && a.bottom == b.bottom && a.right == b.right && a.top == b.top; }
static void Check(BOOL condition, NSString *description) {
    Checks++;
    if (!condition) { Failures++; fprintf(stderr, "FAIL: %s\n", description.UTF8String); }
    else if (getenv("PAINTFCP_HOST_TEST_VERBOSE")) fprintf(stdout, "PASS: %s\n", description.UTF8String);
}
static PGHostTile *Tile(NSUInteger width, NSUInteger height, NSInteger left, NSInteger bottom, FxImageOrigin origin) {
    IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)@{
        (__bridge id)kIOSurfaceWidth:@(width), (__bridge id)kIOSurfaceHeight:@(height),
        (__bridge id)kIOSurfaceBytesPerElement:@4, (__bridge id)kIOSurfaceBytesPerRow:@(width * 4),
        (__bridge id)kIOSurfacePixelFormat:@(kCVPixelFormatType_32BGRA),
        (__bridge id)kIOSurfaceAllocSize:@(width * height * 4)});
    PGHostTile *tile = [PGHostTile new]; tile.storage = CFBridgingRelease(surface);
    tile.pixelBounds = (FxRect){(SInt32)left, (SInt32)bottom, (SInt32)(left + width), (SInt32)(bottom + height)};
    tile.fullBounds = tile.pixelBounds; tile.origin = origin;
    tile.registry = MTLCreateSystemDefaultDevice().registryID;
    tile.space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    return tile;
}
static void Fill(PGHostTile *tile) {
    IOSurfaceRef surface = (__bridge IOSurfaceRef)tile.storage;
    IOSurfaceLock(surface, 0, NULL);
    unsigned char *bytes = IOSurfaceGetBaseAddress(surface); size_t row = IOSurfaceGetBytesPerRow(surface);
    for (size_t y = 0; y < IOSurfaceGetHeight(surface); y++) for (size_t x = 0; x < IOSurfaceGetWidth(surface); x++) {
        unsigned char *p = bytes + y * row + x * 4;
        p[0] = 20 + x % 150; p[1] = 35 + y % 170; p[2] = 45 + (x * 3 + y * 5) % 180; p[3] = 255;
    }
    IOSurfaceUnlock(surface, 0, NULL);
}
static NSData *SurfaceBytes(PGHostTile *tile) {
    IOSurfaceRef surface = (__bridge IOSurfaceRef)tile.storage;
    IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
    size_t width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface), row = IOSurfaceGetBytesPerRow(surface);
    NSMutableData *result = [NSMutableData dataWithLength:width * height * 4];
    for (size_t y = 0; y < height; y++) memcpy((unsigned char *)result.mutableBytes + y * width * 4, (unsigned char *)IOSurfaceGetBaseAddress(surface) + y * row, width * 4);
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
    return result;
}
static NSUInteger MaximumDifference(NSData *a, NSData *b) {
    if (a.length != b.length) return NSUIntegerMax;
    const unsigned char *x = a.bytes, *y = b.bytes; NSUInteger maximum = 0;
    for (NSUInteger i = 0; i < a.length; i++) maximum = MAX(maximum, (NSUInteger)abs(x[i] - y[i]));
    return maximum;
}
static NSData *ExpectedCrop(PGHostTile *source, NSUInteger x, NSUInteger y, NSUInteger width, NSUInteger height, BOOL flip) {
    NSData *sourceBytes = SurfaceBytes(source); size_t sourceWidth = IOSurfaceGetWidth((__bridge IOSurfaceRef)source.storage);
    NSMutableData *result = [NSMutableData dataWithLength:width * height * 4];
    for (NSUInteger row = 0; row < height; row++) {
        NSUInteger sourceRow = flip ? IOSurfaceGetHeight((__bridge IOSurfaceRef)source.storage) - 1 - (row + y) : row + y;
        memcpy((unsigned char *)result.mutableBytes + row * width * 4, (const unsigned char *)sourceBytes.bytes + (sourceRow * sourceWidth + x) * 4, width * 4);
    }
    return result;
}
static NSData *Snapshot(beatygrilPlugIn *plugin, CMTime time) {
    NSData *state = nil; NSError *error = nil;
    Check([plugin pluginState:&state atTime:time quality:kFxQuality_HIGH error:&error] && state.length > 0 && !error, @"plugin snapshot serializes through host parameter API");
    return state;
}
static BOOL Render(beatygrilPlugIn *plugin, PGHostTile *destination, NSArray *sources, NSData *state, CMTime time, NSError **error, BOOL *escaped) {
    @try { return [plugin renderDestinationImage:destination sourceImages:sources pluginState:state atTime:time error:error]; }
    @catch (NSException *exception) {
        if (escaped) *escaped = YES;
        fprintf(stderr, "EXCEPTION: %s\n", exception.reason.UTF8String); return NO;
    }
}
static void RejectState(beatygrilPlugIn *plugin, PGHostTile *destination, PGHostTile *source, NSData *state, NSString *description) {
    NSError *error = nil; BOOL escaped = NO;
    BOOL rendered = Render(plugin, destination, @[source], state, kCMTimeZero, &error, &escaped);
    Check(!rendered && !escaped && error != nil, description);
}
static NSData *PlistState(id value) { return [NSPropertyListSerialization dataWithPropertyList:value format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil]; }
static void WritePortrait(PGHostTile *tile, CIImage *image) {
    CIContext *context = [CIContext contextWithOptions:@{kCIContextWorkingColorSpace:NSNull.null, kCIContextOutputColorSpace:NSNull.null}];
    [context render:image toIOSurface:(__bridge IOSurfaceRef)tile.storage bounds:image.extent colorSpace:nil];
}
static BOOL Preview(PGHostTile *before, PGHostTile *after, NSString *path) {
    CIContext *context = [CIContext contextWithOptions:@{kCIContextWorkingColorSpace:NSNull.null, kCIContextOutputColorSpace:NSNull.null}];
    size_t width = IOSurfaceGetWidth((__bridge IOSurfaceRef)before.storage), height = IOSurfaceGetHeight((__bridge IOSurfaceRef)before.storage);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef canvas = CGBitmapContextCreate(NULL, width * 2, height, 8, width * 2 * 4, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    NSArray *tiles = @[before, after];
    for (NSUInteger index = 0; index < 2; index++) {
        PGHostTile *tile = tiles[index];
        CIImage *image = [CIImage imageWithIOSurface:(__bridge IOSurfaceRef)tile.storage options:@{kCIImageColorSpace:NSNull.null}];
        CGImageRef panel = [context createCGImage:image fromRect:CGRectMake(0, 0, width, height)];
        CGContextDrawImage(canvas, CGRectMake(width * index, 0, width, height), panel); CGImageRelease(panel);
    }
    CGImageRef output = CGBitmapContextCreateImage(canvas);
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], CFSTR("public.png"), 1, NULL);
    BOOL ok = NO;
    if (destination && output) { CGImageDestinationAddImage(destination, output, NULL); ok = CGImageDestinationFinalize(destination); }
    if (destination) CFRelease(destination); CGImageRelease(output); CGContextRelease(canvas); CGColorSpaceRelease(space);
    return ok;
}

int main(int argc, const char *argv[]) {
    setbuf(stdout, NULL);
    @autoreleasepool {
        PGHostAPI *api = [PGHostAPI new]; beatygrilPlugIn *plugin = [[beatygrilPlugIn alloc] initWithAPIManager:api];
        NSError *error = nil;
        Check([plugin addParametersWithError:&error] && !error, @"host creates complete parameter set");
        UInt32 identifiers[] = {PGAmount,PGBrightness,PGRadius,PGSharpness,PGMix,PGThreshold,PGSoftness,PGEdgeProtect,PGShowMask,PGMidtone,PGHue,PGSaturation,PGHighPass,PGThin,PGFaceBoxes,PGSingleFace,PGSelection,PGShort,PGNarrow,PGChin,PGVFace,PGJaw,PGCheekbone,PGSmallHead,PGSmallHeadRange,PGFeatureProtect,PGTeeth,PGEyeBright,PGBigEye,PGTrackBoxes,PGFastMulti,PGJumpGuard,PGEvenTone,PGTonePreset,PGInvertMask,PGDebugChannel,PGTrackEnabled,PGTarget,PGAnalyzeForward,PGAnalyzeBackward,PGClearTrack,PGStatus,PGTrackData1,PGTrackData2,PGTrackData3,PGSmoothingEnabled,PGColorEnabled,PGShapeEnabled,PGDetailEnabled};
        for (NSUInteger i = 0; i < sizeof(identifiers) / sizeof(UInt32); i++) Check(api.definitions[@(identifiers[i])] != nil, [NSString stringWithFormat:@"required parameter %u exists", identifiers[i]]);
        Check(api.depth == 0 && !api.duplicate && api.definitions.count == sizeof(identifiers) / sizeof(UInt32) + 6, @"parameter groups close and IDs are unique");
        Check([api.values[@(PGMidtone)] doubleValue] == 0 && [api.values[@(PGMix)] doubleValue] == 1, @"default detail and mix form identity filter");
        Check([api.definitions[@(PGShort)][@"min"] doubleValue] == -1 && [api.definitions[@(PGShort)][@"max"] doubleValue] == 1, @"signed face control exposes both directions");
        Check([api.definitions[@(PGTrackData1)][@"flags"] unsignedLongLongValue] & kFxParameterFlag_HIDDEN, @"persistent tracking data stays hidden in host UI");
        NSDictionary *defaults = [api.values copy];
        NSDictionary *properties = nil;
        Check([plugin properties:&properties error:&error] && [properties[kFxPropertyKey_DesiredProcessingColorInfo] intValue] == kFxImageColorInfo_RGB_GAMMA_VIDEO, @"adapter requests host gamma-video samples");
        NSData *state = Snapshot(plugin, kCMTimeZero);
        NSDictionary *decoded = [NSPropertyListSerialization propertyListWithData:state options:0 format:nil error:nil];
        Check([decoded[@"tracks"] count] == 3 && [decoded[@"settings"] length] == sizeof(PGBeautySettings), @"snapshot contains fixed settings schema and three target slots");
        PGBeautySettings settings; [decoded[@"settings"] getBytes:&settings length:sizeof(settings)];
        Check(settings.version == 1 && settings.mix == 1 && settings.midtoneDetail == 0, @"snapshot round-trips default numeric state");
        api.values[@(PGThin)] = @5; api.values[@(PGRadius)] = @(-9); api.values[@(PGSelection)] = @[@(-1), @2];
        settings = [plugin settingsAtTime:api.hostTime];
        Check(settings.faceThin == 1 && settings.radius == 1 && settings.selectionX == 0 && settings.selectionY == 1, @"host parameter limits and normalized selection are enforced");
        api.values[@(PGShapeEnabled)] = @NO;
        Check([plugin settingsAtTime:kCMTimeZero].faceThin == 0, @"disabling face group disables shape amount");
        api.values = [defaults mutableCopy];
        PGHostTile *source = Tile(96, 80, 0, 0, kFxImageOrigin_BOTTOM_LEFT), *destination = Tile(96, 80, 0, 0, kFxImageOrigin_BOTTOM_LEFT);
        Fill(source);
        Check(Render(plugin, destination, @[source], state, kCMTimeZero, &error, NULL), @"production adapter renders real BGRA IOSurface");
        NSUInteger difference = MaximumDifference(SurfaceBytes(source), SurfaceBytes(destination));
        printf("Default IOSurface maximum byte difference: %lu\n", (unsigned long)difference);
        Check(difference <= 1, @"default adapter output preserves gamma-video numeric samples");
        CGColorSpaceRelease(destination.space); destination.space = CGColorSpaceCreateWithName(kCGColorSpaceLinearSRGB);
        Check(Render(plugin, destination, @[source], state, kCMTimeZero, &error, NULL), @"numeric host render accepts destination color-space metadata");
        difference = MaximumDifference(SurfaceBytes(source), SurfaceBytes(destination));
        printf("Alternate destination tag maximum byte difference: %lu\n", (unsigned long)difference);
        Check(difference <= 1, @"host color-space tags do not double-convert already-requested gamma-video samples");
        CGColorSpaceRelease(destination.space); destination.space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        FxRect rectangle;
        Check([plugin destinationImageRect:&rectangle sourceImages:@[source] destinationImage:destination pluginState:state atTime:kCMTimeZero error:&error] && RectEqual(rectangle, source.fullBounds), @"destination bounds preserve full input extent");
        Check([plugin sourceTileRect:&rectangle sourceImageIndex:0 sourceImages:@[source] destinationTileRect:destination.pixelBounds destinationImage:destination pluginState:state atTime:kCMTimeZero error:&error] && RectEqual(rectangle, source.fullBounds), @"adapter requests full source buffer for face processing");
        RejectState(plugin, destination, source, nil, @"nil snapshot is rejected with NSError, without escaping exception");
        RejectState(plugin, destination, source, [NSData data], @"empty snapshot is rejected safely");
        RejectState(plugin, destination, source, (NSData *)(id)@"wrong type", @"non-NSData snapshot is rejected safely");
        RejectState(plugin, destination, source, [@"bad data" dataUsingEncoding:NSUTF8StringEncoding], @"malformed snapshot is rejected safely");
        RejectState(plugin, destination, source, PlistState(@[]), @"non-dictionary snapshot is rejected safely");
        RejectState(plugin, destination, source, PlistState(@{@"settings":[NSData data], @"tracks":@[@"",@"",@""]}), @"wrong settings size is rejected safely");
        settings = PGBeautyDefaults(); settings.version = 99;
        RejectState(plugin, destination, source, PlistState(@{@"settings":[NSData dataWithBytes:&settings length:sizeof(settings)], @"tracks":@[@"",@"",@""]}), @"unknown saved settings version is rejected safely");
        settings.version = 1;
        RejectState(plugin, destination, source, PlistState(@{@"settings":[NSData dataWithBytes:&settings length:sizeof(settings)], @"tracks":@[@"",@""]}), @"wrong target slot count is rejected safely");
        RejectState(plugin, destination, source, PlistState(@{@"settings":[NSData dataWithBytes:&settings length:sizeof(settings)], @"tracks":@[@"",@7,@""]}), @"non-string target slot is rejected safely");
        for (NSUInteger top = 0; top < 2; top++) {
            FxImageOrigin origin = top ? kFxImageOrigin_TOP_LEFT : kFxImageOrigin_BOTTOM_LEFT;
            PGHostTile *input = Tile(48, 32, 37, -21, origin), *output = Tile(48, 32, 37, -21, origin); Fill(input);
            Check(Render(plugin, output, @[input], state, kCMTimeZero, &error, NULL), @"nonzero-origin tile renders");
            Check(MaximumDifference(SurfaceBytes(input), SurfaceBytes(output)) <= 1, top ? @"top-left tile preserves sample rows at nonzero origin" : @"bottom-left tile preserves sample rows at nonzero origin");
            output.origin = top ? kFxImageOrigin_BOTTOM_LEFT : kFxImageOrigin_TOP_LEFT;
            Check(Render(plugin, output, @[input], state, kCMTimeZero, &error, NULL), @"opposite-origin tile renders");
            Check(MaximumDifference(ExpectedCrop(input, 0, 0, 48, 32, YES), SurfaceBytes(output)) <= 1, @"opposite image origins flip rows exactly once");
        }
        PGHostTile *full = Tile(48, 32, 37, -21, kFxImageOrigin_BOTTOM_LEFT), *crop = Tile(16, 12, 43, -17, kFxImageOrigin_BOTTOM_LEFT); Fill(full);
        Check(Render(plugin, crop, @[full], state, kCMTimeZero, &error, NULL), @"destination sub-tile renders from full input buffer");
        // IOSurface memory rows are top-down. In a BOTTOM_LEFT image, a logical
        // lower-edge offset of 4 selects physical row 32 - 4 - 12 = 16.
        NSData *expectedCrop = ExpectedCrop(full, 6, 16, 16, 12, NO), *actualCrop = SurfaceBytes(crop);
        NSUInteger cropDifference = MaximumDifference(expectedCrop, actualCrop);
        if (cropDifference > 1) {
            const unsigned char *a = expectedCrop.bytes, *b = actualCrop.bytes;
            fprintf(stderr, "Crop max difference %lu, first expected BGRA %u/%u/%u/%u, actual %u/%u/%u/%u\n", (unsigned long)cropDifference, a[0], a[1], a[2], a[3], b[0], b[1], b[2], b[3]);
        }
        Check(cropDifference <= 1, @"destination sub-tile translates global pixel bounds correctly");
        full.origin = kFxImageOrigin_TOP_LEFT; crop.origin = kFxImageOrigin_TOP_LEFT;
        Check(Render(plugin, crop, @[full], state, kCMTimeZero, &error, NULL), @"top-left destination sub-tile renders");
        Check(MaximumDifference(ExpectedCrop(full, 6, 4, 16, 12, NO), SurfaceBytes(crop)) <= 1, @"top-left sub-tile selects correct physical source rows");

        NSString *fixture = argc > 1 ? @(argv[1]) : @"tests/fixtures/astronaut.png";
        CIImage *portrait = [CIImage imageWithContentsOfURL:[NSURL fileURLWithPath:fixture] options:@{kCIImageColorSpace:NSNull.null}];
        Check(portrait != nil, @"NASA portrait opens for full adapter test");
        PGHostTile *portraitSource = Tile(512, 512, 0, 0, kFxImageOrigin_BOTTOM_LEFT), *portraitOutput = Tile(512, 512, 0, 0, kFxImageOrigin_BOTTOM_LEFT);
        WritePortrait(portraitSource, portrait);
        api.values[@(PGThin)] = @0.8; api.values[@(PGBigEye)] = @0.6; api.values[@(PGMidtone)] = @0.8; api.values[@(PGBrightness)] = @0.25; api.values[@(PGMix)] = @0;
        NSData *zeroMix = Snapshot(plugin, kCMTimeZero);
        Check(Render(plugin, portraitOutput, @[portraitSource], zeroMix, kCMTimeZero, &error, NULL), @"zero overall mix renders with active skin and face controls");
        Check(MaximumDifference(SurfaceBytes(portraitSource), SurfaceBytes(portraitOutput)) <= 1, @"zero mix also disables geometry and color/detail output");
        api.values[@(PGThin)] = @0.2; api.values[@(PGBigEye)] = @0; api.values[@(PGMix)] = @1;
        NSData *beautyState = Snapshot(plugin, kCMTimeZero);
        Check(Render(plugin, portraitOutput, @[portraitSource], beautyState, kCMTimeZero, &error, NULL), @"real portrait renders through face, skin and IOSurface adapter");
        Check(MaximumDifference(SurfaceBytes(portraitSource), SurfaceBytes(portraitOutput)) > 5, @"active portrait settings produce visible full-chain change");
        if (argc > 2) Check(Preview(portraitSource, portraitOutput, @(argv[2])), @"full adapter before/after preview writes PNG");

        api.values = [defaults mutableCopy]; api.targetAtCurrentTime = YES;
        api.values[@(PGSelection)] = @[@0.43, @0.76];
        NSData *oldRenderState = Snapshot(plugin, api.hostTime);
        [plugin analyzeForward];
        Check(api.forwardRequests == 1, @"forward analyze button calls host analysis API");
        CMTimeRange desired, clip = CMTimeRangeMake(kCMTimeZero, CMTimeMake(240, 24));
        [plugin desiredAnalysisTimeRange:&desired forInputWithTimeRange:clip error:&error];
        Check(CMTimeCompare(desired.start, api.hostTime) == 0 && CMTimeCompare(CMTimeRangeGetEnd(desired), CMTimeRangeGetEnd(clip)) == 0, @"analysis seed comes from current host playhead time");
        [plugin analyzeForward];
        Check(api.forwardRequests == 1, @"second analyze click is blocked before host setup callback");
        Check([plugin setupAnalysisForTimeRange:desired frameDuration:CMTimeMake(1, 24) error:&error], @"host setup starts analysis session");
        api.values[@(PGTrackData3)] = @"preserve-until-analysis-finishes";
        [plugin clearTracking];
        Check([api.values[@(PGTrackData3)] isEqualToString:@"preserve-until-analysis-finishes"], @"clear is blocked while selected target analysis is active");
        api.values[@(PGTrackData3)] = @"";
        Check([plugin analyzeFrame:portraitSource atTime:api.hostTime error:&error], @"analyzer accepts real portrait IOSurface");
        Check(Render(plugin, portraitOutput, @[portraitSource], oldRenderState, api.hostTime, &error, NULL), @"rendering an older snapshot is allowed during analysis");
        Check([plugin analyzeFrame:portraitSource atTime:CMTimeAdd(api.hostTime, CMTimeMake(1, 24)) error:&error], @"analysis continues after old snapshot render");
        Check([plugin cleanupAnalysis:&error], @"analysis persists target data into host parameters");
        NSString *target = api.values[@(PGTrackData3)];
        Check(target.length > 0 && [api.values[@(PGTrackData1)] length] == 0 && [api.values[@(PGTrackData2)] length] == 0, @"analysis stores only target selected at current host time");
        NSData *tracking = [[NSData alloc] initWithBase64EncodedString:target options:0];
        NSDictionary *trackingArchive = tracking ? [NSPropertyListSerialization propertyListWithData:tracking options:0 format:nil error:nil] : nil;
        Check([trackingArchive[@"frames"] count] == 2, @"old render snapshot does not erase either newly analyzed frame");
        Check([api.values[@(PGTrackEnabled)] boolValue] && CMTimeCompare(api.lastSetBoolTime, api.hostTime) == 0, @"analysis enables saved target at host seed time");
        NSData *trackedState = Snapshot(plugin, api.hostTime);
        beatygrilPlugIn *restoredPlugin = [[beatygrilPlugIn alloc] initWithAPIManager:api];
        Check(Render(restoredPlugin, portraitOutput, @[portraitSource], trackedState, api.hostTime, &error, NULL), @"fresh plugin instance restores target data from serialized host snapshot");
        [plugin analyzeBackward];
        Check(api.backwardRequests == 1, @"backward analyze button calls host API");
        [plugin desiredAnalysisTimeRange:&desired forInputWithTimeRange:clip error:&error];
        Check(CMTimeCompare(desired.start, kCMTimeZero) == 0 && CMTimeCompare(CMTimeRangeGetEnd(desired), CMTimeAdd(api.hostTime, CMTimeMake(1, 24))) == 0, @"backward analysis range includes the current host frame");
        [plugin setupAnalysisForTimeRange:desired frameDuration:CMTimeMake(1, 24) error:&error]; [plugin cleanupAnalysis:&error];
        [plugin clearTracking]; Check([api.values[@(PGTrackData3)] length] == 0, @"clear button uses current host target");
        PGHostAPI *writeFailureAPI = [PGHostAPI new];
        beatygrilPlugIn *writeFailurePlugin = [[beatygrilPlugIn alloc] initWithAPIManager:writeFailureAPI];
        [writeFailurePlugin addParametersWithError:&error]; [writeFailurePlugin analyzeForward];
        [writeFailurePlugin setupAnalysisForTimeRange:clip frameDuration:CMTimeMake(1, 24) error:&error];
        [writeFailurePlugin analyzeFrame:portraitSource atTime:writeFailureAPI.hostTime error:&error];
        writeFailureAPI.rejectedWriteParameter = PGTrackData1; error = nil;
        Check(![writeFailurePlugin cleanupAnalysis:&error] && error != nil, @"host refusing saved tracking data reports persistence failure");
        writeFailureAPI.rejectedWriteParameter = 0;
        [writeFailurePlugin analyzeForward];
        Check(writeFailureAPI.forwardRequests == 2, @"persistence failure releases analysis busy state for retry");
        PGHostAPI *unavailable = [PGHostAPI new]; [unavailable.disabledAPIs addObject:@"FxParameterCreationAPI_v5"];
        beatygrilPlugIn *missingPlugin = [[beatygrilPlugIn alloc] initWithAPIManager:unavailable];
        error = nil; Check(![missingPlugin addParametersWithError:&error] && error != nil, @"missing host creation API reports error");
        [unavailable.disabledAPIs removeAllObjects]; unavailable.rejectedParameter = PGThin;
        error = nil; Check(![missingPlugin addParametersWithError:&error] && error != nil, @"host rejecting one control fails complete parameter creation");
        [unavailable.disabledAPIs addObject:@"FxParameterRetrievalAPI_v6"];
        NSData *invalid = nil; error = nil;
        Check(![missingPlugin pluginState:&invalid atTime:kCMTimeZero quality:kFxQuality_HIGH error:&error] && error != nil, @"missing host retrieval API rejects snapshot");
        printf("Host adapter: %lu checks, %lu failures\n", (unsigned long)Checks, (unsigned long)Failures);
    }
    return Failures ? 1 : 0;
}
