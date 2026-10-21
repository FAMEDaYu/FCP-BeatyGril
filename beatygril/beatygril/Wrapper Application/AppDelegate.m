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
    NSTextField *description=[NSTextField wrappingLabelWithString:@"在 Motion 的滤镜资源库中选择「大鱼 → 大鱼人像美化」。Final Cut Pro 的效果浏览器中也可使用配套效果。\n\n磨皮、肤色、细节和脸型可分别开关。启用「只处理选中人脸」后，在检视器调整选脸位置，或直接点击画面选脸。选定目标后可向前、向后分析并将跟踪数据保存在工程中。"];
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
