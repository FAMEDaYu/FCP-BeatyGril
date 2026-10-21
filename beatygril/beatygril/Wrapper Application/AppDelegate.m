#import "AppDelegate.h"
#import <CoreServices/CoreServices.h>

@interface AppDelegate ()
@property (weak) IBOutlet NSWindow *window;
@property (strong) NSTimer *exitTimer;
@end

@implementation AppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.window.title = @"大鱼人像美化 · 免费开源";
    [self.window setContentSize:NSMakeSize(800, 450)];
    self.window.styleMask &= ~NSWindowStyleMaskResizable;
    self.window.backgroundColor = [NSColor colorWithRed:0.94 green:0.92 blue:0.85 alpha:1];
    NSImageView *card = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, 800, 450)];
    card.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    card.imageScaling = NSImageScaleProportionallyUpOrDown;
    NSURL *artwork = [NSBundle.mainBundle URLForResource:@"LauncherInfo" withExtension:@"png"];
    card.image = [[NSImage alloc] initWithContentsOfURL:artwork];
    card.accessibilityLabel = @"大鱼人像美化，免费开源，自动注册，无需激活码。主程序启动三秒后自动退出；Final Cut Pro 和 Motion 中的滤镜继续独立运行。";
    self.window.contentView = card;
    if (!card.image) {
        NSTextField *fallback = [NSTextField wrappingLabelWithString:card.accessibilityLabel];
        fallback.frame = NSMakeRect(48, 160, 704, 130);
        fallback.font = [NSFont systemFontOfSize:24 weight:NSFontWeightSemibold];
        [card addSubview:fallback];
    }
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    // Only this launcher exits. The FxPlug service has its own process/lifetime.
    self.exitTimer = [NSTimer scheduledTimerWithTimeInterval:3.0 repeats:NO block:^(NSTimer *timer) {
        [NSApp terminate:nil];
    }];
    // Re-register our own bundle. There is no paid activation or account step.
    NSURL *bundleURL = NSBundle.mainBundle.bundleURL;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        OSStatus status = LSRegisterURL((__bridge CFURLRef)bundleURL, true);
        if (status != noErr) NSLog(@"LaunchServices registration status: %d", (int)status);
    });
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}
@end
