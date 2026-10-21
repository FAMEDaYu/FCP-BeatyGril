#import "AppDelegate.h"
@interface AppDelegate ()
@property (weak) IBOutlet NSWindow *window;
@end
@implementation AppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.window.title=@"大鱼人像美化";
    [self.window setContentSize:NSMakeSize(600,360)];
    NSView *content=[NSView new];self.window.contentView=content;
    NSStackView *stack=[NSStackView new];stack.orientation=NSUserInterfaceLayoutOrientationVertical;
    stack.alignment=NSLayoutAttributeLeading;stack.spacing=16;stack.translatesAutoresizingMaskIntoConstraints=NO;
    [content addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[[stack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:32],[stack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-32],[stack.topAnchor constraintEqualToAnchor:content.topAnchor constant:30]]];
    NSTextField *title=[NSTextField labelWithString:@"大鱼人像美化"];
    title.font=[NSFont systemFontOfSize:28 weight:NSFontWeightSemibold];[stack addArrangedSubview:title];
    NSTextField *subtitle=[NSTextField labelWithString:@"beatygril  ·  FxPlug 4"];
    subtitle.textColor=NSColor.secondaryLabelColor;[stack addArrangedSubview:subtitle];
    NSTextField *description=[NSTextField wrappingLabelWithString:@"在 Motion 的滤镜资源库中选择「大鱼 → 大鱼人像美化」。Final Cut Pro 的效果浏览器中也可使用配套效果。\n\n美化会随画面人脸自动更新，无需先点分析。脸型默认跟随主要人脸，多人模式可处理多张脸。启用「只处理选中人脸」后，可点击画面更换目标。向前/向后分析为可选功能，结果可随工程保存。"];
    description.font=[NSFont systemFontOfSize:13];[stack addArrangedSubview:description];
    NSStackView *buttons=[NSStackView new];buttons.orientation=NSUserInterfaceLayoutOrientationHorizontal;buttons.spacing=12;
    [buttons addArrangedSubview:[NSButton buttonWithTitle:@"打开 Motion" target:self action:@selector(openMotion:)]];
    [buttons addArrangedSubview:[NSButton buttonWithTitle:@"打开 Final Cut Pro" target:self action:@selector(openFinalCut:)]];
    [stack addArrangedSubview:buttons];
    NSTextField *note=[NSTextField wrappingLabelWithString:@"建议先调高中频磨皮，再按需调节肤色与脸型。肤色风格为本插件独立调色预设。"];
    note.textColor=NSColor.secondaryLabelColor;note.font=[NSFont systemFontOfSize:11];[stack addArrangedSubview:note];
    [self.window center];
}
- (void)openMotion:(id)sender {[self openApplication:@"com.apple.motionapp"];}
- (void)openFinalCut:(id)sender {[self openApplication:@"com.apple.FinalCut"];}
- (void)openApplication:(NSString *)identifier {
    NSURL *url=[NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:identifier];
    if(url) [NSWorkspace.sharedWorkspace openApplicationAtURL:url configuration:NSWorkspaceOpenConfiguration.configuration completionHandler:nil];
}
@end
