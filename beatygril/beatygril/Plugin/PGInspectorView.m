#import "PGInspectorView.h"
#include <math.h>

static NSColor *PGUIColor(CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    return [NSColor colorWithSRGBRed:r green:g blue:b alpha:a];
}
static NSColor *PGUIText(void) { return PGUIColor(.88,.91,.95,1); }
static NSColor *PGUIMuted(void) { return PGUIColor(.60,.65,.73,1); }
static NSTextField *PGUILabel(NSString *text, CGFloat size, NSFontWeight weight) {
    NSTextField *label=[NSTextField labelWithString:text ?: @""];
    label.font=[NSFont systemFontOfSize:size weight:weight]; label.textColor=PGUIText();
    label.lineBreakMode=NSLineBreakByTruncatingTail; return label;
}
static CGFloat PGValueScale(NSDictionary *descriptor) {
    return [descriptor[@"format"] isEqual:@"percent"] && [descriptor[@"max"] doubleValue]<=10 ? 100 : 1;
}
static NSString *PGFormattedValue(NSDictionary *descriptor, double value) {
    NSString *format=descriptor[@"format"];
    if ([format isEqual:@"percent"]) return [NSString stringWithFormat:@"%.0f%%",value*PGValueScale(descriptor)];
    if ([format isEqual:@"degrees"]) return [NSString stringWithFormat:@"%+.0f°",value];
    if ([format isEqual:@"signed"]) return [NSString stringWithFormat:@"%.2f",value];
    if ([format isEqual:@"integer"]) return [NSString stringWithFormat:@"%.0f",value];
    return [NSString stringWithFormat:@"%.1f",value];
}

@interface PGInspectorGlyphButton : NSButton
@property (nonatomic, copy) NSString *glyph;
@property (nonatomic, strong) NSColor *accent;
@property (nonatomic, strong) NSColor *swatch;
@end
@implementation PGInspectorGlyphButton
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect; NSRect b=NSInsetRect(self.bounds,1,1);
    CGFloat opacity=self.enabled?1:.35;
    NSColor *accent=[self.accent colorWithAlphaComponent:opacity];
    BOOL on=self.state==NSControlStateValueOn;
    if ([self.glyph isEqual:@"swatch"]) {
        NSRect circle=NSInsetRect(b,3,3);
        [[(self.swatch ?: PGUIColor(.12,.19,.23,1)) colorWithAlphaComponent:opacity] setFill]; [[NSBezierPath bezierPathWithOvalInRect:circle] fill];
        [[PGUIText() colorWithAlphaComponent:.25*opacity] setStroke];
        NSBezierPath *ring=[NSBezierPath bezierPathWithOvalInRect:circle];ring.lineWidth=1;[ring stroke];
        if (!self.swatch) {
            [PGUIMuted() setStroke];NSBezierPath *slash=[NSBezierPath bezierPath];
            [slash moveToPoint:NSMakePoint(NSMinX(circle)+4,NSMinY(circle)+4)];[slash lineToPoint:NSMakePoint(NSMaxX(circle)-4,NSMaxY(circle)-4)];slash.lineWidth=1.5;[slash stroke];
        }
        if(on) { [accent setStroke];NSBezierPath *selection=[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(b,.5,.5)];selection.lineWidth=1.5;[selection stroke]; }
    } else if ([self.glyph isEqual:@"switch"]) {
        NSRect pill=NSInsetRect(b,1,3);
        [(on?accent:PGUIColor(.20,.25,.34,opacity)) setFill];[[NSBezierPath bezierPathWithRoundedRect:pill xRadius:NSHeight(pill)/2 yRadius:NSHeight(pill)/2]fill];
        CGFloat diameter=NSHeight(pill)-4;CGFloat x=on?NSMaxX(pill)-diameter-2:NSMinX(pill)+2;
        [[NSColor colorWithWhite:.98 alpha:opacity]setFill];[[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x,NSMinY(pill)+2,diameter,diameter)]fill];
    } else {
        NSBezierPath *back=[NSBezierPath bezierPathWithRoundedRect:b xRadius:7 yRadius:7];
        [[self.accent colorWithAlphaComponent:([self.glyph isEqual:@"eye"]?.055:.13)*opacity]setFill];[back fill];
        if ([self.glyph isEqual:@"eye"]) {
            [[self.accent colorWithAlphaComponent:.35*opacity]setStroke];back.lineWidth=.7;[back stroke];
            NSPoint c=NSMakePoint(NSMidX(b),NSMidY(b));
            NSBezierPath *eye=[NSBezierPath bezierPath];[eye moveToPoint:NSMakePoint(c.x-6,c.y)];
            [eye curveToPoint:NSMakePoint(c.x+6,c.y) controlPoint1:NSMakePoint(c.x-3,c.y-5.5) controlPoint2:NSMakePoint(c.x+3,c.y-5.5)];
            [eye curveToPoint:NSMakePoint(c.x-6,c.y) controlPoint1:NSMakePoint(c.x+3,c.y+5.5) controlPoint2:NSMakePoint(c.x-3,c.y+5.5)];eye.lineWidth=1.3;[accent setStroke];[eye stroke];
            if(on){[accent setFill];[[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(c.x-1.8,c.y-1.8,3.6,3.6)]fill];}
            else{NSBezierPath *slash=[NSBezierPath bezierPath];[slash moveToPoint:NSMakePoint(c.x-6,c.y+6)];[slash lineToPoint:NSMakePoint(c.x+6,c.y-6)];slash.lineWidth=1.2;[slash stroke];}
        } else {
            NSString *symbol=[self.glyph isEqual:@"disclosure"]?(on?@"⌄":@"›"):@"↻";
            NSFont *font=[NSFont systemFontOfSize:[self.glyph isEqual:@"disclosure"]?19:18 weight:NSFontWeightSemibold];
            NSDictionary *attributes=@{NSFontAttributeName:font,NSForegroundColorAttributeName:[self.accent colorWithAlphaComponent:(on?1:.58)*opacity]};
            NSSize size=[symbol sizeWithAttributes:attributes];[symbol drawAtPoint:NSMakePoint(NSMidX(b)-size.width/2,NSMidY(b)-size.height/2)withAttributes:attributes];
        }
    }
    if(self.window.firstResponder==self){[[self.accent colorWithAlphaComponent:.8]setStroke];NSBezierPath *focus=[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,.5,.5) xRadius:7 yRadius:7];focus.lineWidth=1;[focus stroke];}
}
- (void)setState:(NSControlStateValue)state { [super setState:state];self.needsDisplay=YES; }
- (void)setEnabled:(BOOL)enabled { [super setEnabled:enabled];self.needsDisplay=YES; }
@end
static PGInspectorGlyphButton *PGUIButton(NSString *glyph, NSColor *accent, id target, SEL action) {
    PGInspectorGlyphButton *button=[[PGInspectorGlyphButton alloc]initWithFrame:NSZeroRect];
    button.glyph=glyph;button.accent=accent;button.bordered=NO;button.title=@"";
    [button setButtonType:([glyph isEqual:@"eye"]||[glyph isEqual:@"switch"]||[glyph isEqual:@"disclosure"]||[glyph isEqual:@"swatch"])?NSButtonTypePushOnPushOff:NSButtonTypeMomentaryPushIn];
    button.target=target;button.action=action;button.focusRingType=NSFocusRingTypeExterior;
    return button;
}

@interface PGInspectorSliderCell : NSSliderCell
@property (nonatomic, strong) NSColor *accent;
@end
@implementation PGInspectorSliderCell
- (void)drawBarInside:(NSRect)rect flipped:(BOOL)flipped {
    (void)flipped;NSRect bar=NSMakeRect(NSMinX(rect),NSMidY(rect)-2,NSWidth(rect),4);
    [PGUIColor(.08,.13,.20,self.enabled?1:.5)setFill];NSBezierPath *track=[NSBezierPath bezierPathWithRoundedRect:bar xRadius:2 yRadius:2];[track fill];
    [[self.accent colorWithAlphaComponent:.18]setStroke];track.lineWidth=.7;[track stroke];
    double range=self.maxValue-self.minValue;if(range<=0)return;
    CGFloat from=self.minValue<0?(CGFloat)((0-self.minValue)/range):0;
    CGFloat to=(CGFloat)((self.doubleValue-self.minValue)/range);
    NSRect fill=NSMakeRect(NSMinX(bar)+MIN(from,to)*NSWidth(bar),NSMinY(bar),fabs(to-from)*NSWidth(bar),NSHeight(bar));
    [[self.accent colorWithAlphaComponent:self.enabled?.85:.23]setFill];[[NSBezierPath bezierPathWithRoundedRect:fill xRadius:2 yRadius:2]fill];
}
- (void)drawKnob:(NSRect)knobRect {
    CGFloat d=12;NSRect r=NSMakeRect(NSMidX(knobRect)-d/2,NSMidY(knobRect)-d/2,d,d);
    [[self.accent colorWithAlphaComponent:self.enabled?.22:.08]setFill];[[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(r,-2,-2)]fill];
    [[NSColor colorWithWhite:.97 alpha:self.enabled?1:.5]setFill];NSBezierPath *knob=[NSBezierPath bezierPathWithOvalInRect:r];[knob fill];
    [[self.accent colorWithAlphaComponent:self.enabled?.85:.25]setStroke];knob.lineWidth=1;[knob stroke];
}
- (CGFloat)knobThickness { return 14; }
@end
@interface PGInspectorSlider : NSSlider
@property (nonatomic, copy) void (^interactionBegan)(void);
@property (nonatomic, copy) void (^interactionEnded)(void);
@end
@implementation PGInspectorSlider
- (void)mouseDown:(NSEvent *)event {
    if(!self.enabled)return;if(self.interactionBegan)self.interactionBegan();
    @try{[super mouseDown:event];}@finally{if(self.interactionEnded)self.interactionEnded();}
}
- (void)keyDown:(NSEvent *)event {
    if(self.interactionBegan)self.interactionBegan();
    @try{[super keyDown:event];}@finally{if(self.interactionEnded)self.interactionEnded();}
}
@end

@interface PGInspectorNumberCell : NSTextFieldCell
@end
@implementation PGInspectorNumberCell
- (NSRect)drawingRectForBounds:(NSRect)bounds {
    NSRect rect=[super drawingRectForBounds:bounds];CGFloat height=[self cellSizeForBounds:bounds].height;
    if(NSHeight(rect)>height){rect.origin.y+=(NSHeight(rect)-height)*.5;rect.size.height=height;}return rect;
}
@end
@interface PGInspectorNumberField : NSTextField
@end
@implementation PGInspectorNumberField
+ (Class)cellClass { return PGInspectorNumberCell.class; }
@end

@class PGInspectorRow;
@interface PGInspectorCard : NSView
@property (nonatomic, strong) NSColor *accent;
@property (nonatomic, copy) NSString *heading;
@property (nonatomic, strong) NSTextField *titleLabel;
@property (nonatomic, strong) PGInspectorGlyphButton *master;
@property (nonatomic, copy) NSArray<PGInspectorRow *> *rows;
@property (nonatomic) BOOL expanded;
- (CGFloat)heightForWidth:(CGFloat)width;
@end
@interface PGInspectorView ()
@property (nonatomic, strong, readwrite) PGInspectorController *controller;
- (void)reloadControls;
- (void)beginControlInteraction;
- (void)endControlInteraction;
- (void)writeValue:(double)value parameter:(UInt32)identifier;
@end
@interface PGInspectorRow : NSView <NSTextFieldDelegate>
@property (nonatomic, weak) PGInspectorView *inspector;
@property (nonatomic, copy) NSDictionary *descriptor;
@property (nonatomic, strong) NSColor *accent;
@property (nonatomic, strong) NSTextField *label;
@property (nonatomic, strong) NSTextField *valueField;
@property (nonatomic, strong) NSTextField *hint;
@property (nonatomic, strong) PGInspectorSlider *slider;
@property (nonatomic, strong) PGInspectorGlyphButton *eye;
@property (nonatomic, strong) PGInspectorGlyphButton *reset;
@property (nonatomic, strong) PGInspectorGlyphButton *toggle;
@property (nonatomic, copy) NSArray<PGInspectorGlyphButton *> *swatches;
- (instancetype)initWithDescriptor:(NSDictionary *)descriptor accent:(NSColor *)accent inspector:(PGInspectorView *)inspector;
- (CGFloat)heightForWidth:(CGFloat)width;
- (void)reloadState:(PGInspectorState *)state master:(BOOL)master available:(BOOL)available;
@end
@implementation PGInspectorRow
- (BOOL)isFlipped { return YES; }
- (instancetype)initWithDescriptor:(NSDictionary *)descriptor accent:(NSColor *)accent inspector:(PGInspectorView *)inspector {
    if((self=[super initWithFrame:NSZeroRect])) {
        _descriptor=[descriptor copy];_accent=accent;_inspector=inspector;
        self.identifier=[NSString stringWithFormat:@"pg.parameter.%@",descriptor[@"id"]];
        NSString *name=descriptor[@"name"];_label=PGUILabel(name,12,NSFontWeightSemibold);[self addSubview:_label];
        NSString *kind=descriptor[@"kind"];
        if([descriptor[@"bypass"]boolValue]){
            _eye=PGUIButton(@"eye",accent,self,@selector(toggleEnabled:));_eye.toolTip=[@"启用 / 停用 · " stringByAppendingString:name];_eye.accessibilityLabel=_eye.toolTip;[self addSubview:_eye];
        }
        if([kind isEqual:@"preset"]){
            NSArray *colors=@[NSNull.null,PGUIColor(.95,.87,.80,1),PGUIColor(.88,.88,.95,1),PGUIColor(1,.86,.72,1),PGUIColor(.99,.78,.75,1),PGUIColor(.76,.57,.39,1),PGUIColor(.48,.32,.22,1)];
            NSArray *options=descriptor[@"options"] ?: @[];NSMutableArray *buttons=[NSMutableArray new];
            for(NSUInteger i=0;i<7;i++){
                PGInspectorGlyphButton *button=PGUIButton(@"swatch",accent,self,@selector(selectPreset:));button.tag=i;button.swatch=i?colors[i]:nil;
                button.toolTip=i<options.count?options[i]:[NSString stringWithFormat:@"%@ %lu",name,(unsigned long)i];button.accessibilityLabel=button.toolTip;
                [self addSubview:button];[buttons addObject:button];
            }_swatches=[buttons copy];
        }else{
            _reset=PGUIButton(@"reset",accent,self,@selector(resetValue:));_reset.toolTip=[@"重置 · "stringByAppendingString:name];_reset.accessibilityLabel=_reset.toolTip;[self addSubview:_reset];
            if([kind isEqual:@"toggle"]){
                _toggle=PGUIButton(@"switch",accent,self,@selector(toggleValue:));_toggle.accessibilityLabel=name;[self addSubview:_toggle];
                _hint=PGUILabel(@"",10,NSFontWeightMedium);_hint.textColor=PGUIMuted();_hint.alignment=NSTextAlignmentRight;[self addSubview:_hint];
                _label.lineBreakMode=NSLineBreakByWordWrapping;_label.maximumNumberOfLines=2;
            }else{
                _slider=[[PGInspectorSlider alloc]initWithFrame:NSZeroRect];PGInspectorSliderCell *cell=[PGInspectorSliderCell new];cell.accent=accent;_slider.cell=cell;
                _slider.minValue=[descriptor[@"min"]doubleValue];_slider.maxValue=[descriptor[@"max"]doubleValue];_slider.continuous=YES;_slider.target=self;_slider.action=@selector(sliderChanged:);_slider.accessibilityLabel=name;
                __weak PGInspectorView *weakInspector=inspector;
                _slider.interactionBegan=^{[weakInspector beginControlInteraction];};_slider.interactionEnded=^{[weakInspector endControlInteraction];};[self addSubview:_slider];
                _valueField=[[PGInspectorNumberField alloc]initWithFrame:NSZeroRect];_valueField.font=[NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightSemibold];_valueField.textColor=PGUIText();_valueField.alignment=NSTextAlignmentCenter;
                _valueField.bordered=NO;_valueField.bezeled=NO;_valueField.drawsBackground=NO;_valueField.backgroundColor=PGUIColor(.14,.19,.26,1);_valueField.wantsLayer=YES;_valueField.layer.backgroundColor=_valueField.backgroundColor.CGColor;_valueField.layer.cornerRadius=7;_valueField.layer.borderWidth=.7;_valueField.layer.borderColor=[accent colorWithAlphaComponent:.24].CGColor;
                _valueField.target=self;_valueField.action=@selector(numberCommitted:);_valueField.delegate=self;_valueField.accessibilityLabel=[name stringByAppendingString:@"数值"];[self addSubview:_valueField];
            }
        }
        NSString *key=[descriptor[@"id"]stringValue];
        _slider.identifier=[@"pg.value."stringByAppendingString:key];_valueField.identifier=[@"pg.number."stringByAppendingString:key];
        _toggle.identifier=[@"pg.toggle."stringByAppendingString:key];_eye.identifier=[@"pg.enable."stringByAppendingString:key];_reset.identifier=[@"pg.reset."stringByAppendingString:key];
    }return self;
}
- (CGFloat)heightForWidth:(CGFloat)width {
    if(_swatches)return 46;
    if(_toggle)return width<310 && [_descriptor[@"name"]length]>12 ? 48 : 36;
    return width<310?52:36;
}
- (void)layout {
    [super layout];CGFloat w=NSWidth(self.bounds),h=NSHeight(self.bounds);BOOL narrow=w<310;
    CGFloat labelX=_eye?25:0;
    _eye.frame=NSMakeRect(0,6,20,22);
    if(_swatches){
        _label.frame=NSMakeRect(labelX,14,33,20);CGFloat x=labelX+37;CGFloat d=MIN(28,MAX(12,(w-x-24)/7));CGFloat gap=MIN(8,MAX(0,(w-x-7*d)/6));
        for(NSUInteger i=0;i<_swatches.count;i++)_swatches[i].frame=NSMakeRect(x+i*(d+gap),7,d,d);return;
    }
    _reset.frame=NSMakeRect(w-23,6,23,23);
    if(_toggle){
        CGFloat switchX=w-76;_toggle.frame=NSMakeRect(switchX,4+(h-36)/2,46,28);_hint.frame=NSMakeRect(switchX-39,10+(h-36)/2,34,18);
        _label.frame=NSMakeRect(labelX,h>36?3:9,MAX(20,switchX-labelX-42),h>36?42:22);return;
    }
    CGFloat fieldW=49,fieldX=w-23-7-fieldW;_valueField.frame=NSMakeRect(fieldX,5,fieldW,25);
    if(narrow){_label.frame=NSMakeRect(labelX,8,MAX(20,fieldX-labelX-6),22);_slider.frame=NSMakeRect(labelX,29,MAX(20,w-labelX-30),18);}
    else{CGFloat labelW=MIN(116,MAX(71,w*.29));_label.frame=NSMakeRect(labelX,9,labelW,21);CGFloat start=labelX+labelW+5;_slider.frame=NSMakeRect(start,7,MAX(20,fieldX-start-8),22);}
}
- (void)reloadState:(PGInspectorState *)state master:(BOOL)master available:(BOOL)available {
    UInt32 identifier=[_descriptor[@"id"]unsignedIntValue];double value=[state valueForParameter:identifier];BOOL enabled=[state isParameterEnabled:identifier];
    _label.alphaValue=master&&enabled?1:.5;_eye.state=enabled?NSControlStateValueOn:NSControlStateValueOff;_eye.enabled=available&&master;
    _reset.enabled=available;_reset.state=fabs(value-[_descriptor[@"default"]doubleValue])>.000001?NSControlStateValueOn:NSControlStateValueOff;
    _slider.enabled=available&&master&&enabled;_slider.doubleValue=value;
    _valueField.enabled=available&&master&&enabled;if(!_valueField.currentEditor)_valueField.stringValue=PGFormattedValue(_descriptor,value);
    _toggle.enabled=available&&master&&enabled;_toggle.state=value>.5?NSControlStateValueOn:NSControlStateValueOff;
    UInt32 identifierForHint=[_descriptor[@"id"]unsignedIntValue];
    _hint.stringValue=identifierForHint==PGFastMulti?(value>.5?@"多人":@"单人"):identifierForHint==PGTrackBoxes?(value>.5?@"预览中":@"隐藏"):(value>.5?@"开启":@"关闭");
    for(NSUInteger i=0;i<_swatches.count;i++){_swatches[i].enabled=available&&master&&enabled;_swatches[i].state=i==(NSUInteger)llround(value)?NSControlStateValueOn:NSControlStateValueOff;}
}
- (void)sliderChanged:(NSSlider *)sender { [_inspector writeValue:sender.doubleValue parameter:[_descriptor[@"id"]unsignedIntValue]]; }
- (void)toggleValue:(NSButton *)sender { [_inspector writeValue:sender.state==NSControlStateValueOn?1:0 parameter:[_descriptor[@"id"]unsignedIntValue]]; }
- (void)selectPreset:(NSButton *)sender { [_inspector writeValue:sender.tag parameter:[_descriptor[@"id"]unsignedIntValue]]; }
- (void)toggleEnabled:(id)sender { (void)sender;[_inspector.controller toggleEnabledForParameter:[_descriptor[@"id"]unsignedIntValue]];[_inspector reloadControls]; }
- (void)resetValue:(id)sender { (void)sender;[_inspector.controller resetParameter:[_descriptor[@"id"]unsignedIntValue]];[_inspector reloadControls]; }
- (void)numberCommitted:(id)sender {
    (void)sender;NSString *text=[_valueField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if([text hasSuffix:@"%"]||[text hasSuffix:@"°"])text=[text substringToIndex:text.length-1];
    NSNumber *number=nil;
    for(NSLocale *locale in @[NSLocale.currentLocale,[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]]){
        NSScanner *scanner=[NSScanner scannerWithString:text];scanner.locale=locale;double parsed;
        if([scanner scanDouble:&parsed]&&scanner.isAtEnd){number=@(parsed);break;}
    }
    if(number&&isfinite(number.doubleValue)){
        double value=number.doubleValue/PGValueScale(_descriptor);value=fmin([_descriptor[@"max"]doubleValue],fmax([_descriptor[@"min"]doubleValue],value));
        // Commit explicit input even when it equals our last displayed value:
        // the document may have changed while the field editor held focus.
        // The controller rereads the host and deduplicates the actual value.
        [_inspector writeValue:value parameter:[_descriptor[@"id"]unsignedIntValue]];
    }else NSBeep();
    _valueField.stringValue=PGFormattedValue(_descriptor,[_inspector.controller.state valueForParameter:[_descriptor[@"id"]unsignedIntValue]]);
}
- (void)controlTextDidEndEditing:(NSNotification *)notification { (void)notification;[self numberCommitted:_valueField]; }
@end

@implementation PGInspectorCard
- (BOOL)isFlipped { return YES; }
- (CGFloat)heightForWidth:(CGFloat)width {
    if(!_expanded)return 44;CGFloat height=49;for(PGInspectorRow *row in _rows){height+=[row heightForWidth:MAX(0,width-24)];if([row.descriptor[@"id"]unsignedIntValue]==PGJumpGuard)height+=8;}return height+7;
}
- (void)layout {
    [super layout];CGFloat w=NSWidth(self.bounds);_titleLabel.frame=NSMakeRect(25,13,MAX(70,w-80),22);_master.frame=NSMakeRect(w-39,10,25,25);
    CGFloat y=49;for(PGInspectorRow *row in _rows){row.hidden=!_expanded;if(!_expanded)continue;CGFloat h=[row heightForWidth:w-24];row.frame=NSMakeRect(12,y,w-24,h);y+=h;if([row.descriptor[@"id"]unsignedIntValue]==PGJumpGuard)y+=8;}
}
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;NSBezierPath *shape=[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,.5,.5) xRadius:13 yRadius:13];
    [NSGraphicsContext saveGraphicsState];[shape addClip];NSGradient *gradient=[[NSGradient alloc]initWithStartingColor:[_accent blendedColorWithFraction:.87 ofColor:PGUIColor(.09,.14,.21,1)] endingColor:PGUIColor(.055,.085,.14,1)];[gradient drawInRect:self.bounds angle:90];[NSGraphicsContext restoreGraphicsState];
    [[_accent colorWithAlphaComponent:.22]setStroke];shape.lineWidth=.8;[shape stroke];
    NSRect pill=NSMakeRect(12,10,MAX(53,[_heading length]*13+20),25);[[_accent colorWithAlphaComponent:.10]setFill];NSBezierPath *p=[NSBezierPath bezierPathWithRoundedRect:pill xRadius:8 yRadius:8];[p fill];[[_accent colorWithAlphaComponent:.32]setStroke];p.lineWidth=.7;[p stroke];
    if(_expanded){[[PGUIMuted() colorWithAlphaComponent:.20]setStroke];NSBezierPath *line=[NSBezierPath bezierPath];[line moveToPoint:NSMakePoint(12,43)];[line lineToPoint:NSMakePoint(NSWidth(self.bounds)-12,43)];line.lineWidth=.5;[line stroke];
        for(PGInspectorRow *row in _rows)if([row.descriptor[@"id"]unsignedIntValue]==PGJumpGuard){CGFloat y=NSMaxY(row.frame)+4;[line removeAllPoints];[line moveToPoint:NSMakePoint(12,y)];[line lineToPoint:NSMakePoint(NSWidth(self.bounds)-12,y)];[line stroke];}
    }
}
@end

@implementation PGInspectorView {
    NSArray<PGInspectorCard *> *_cards;
    PGInspectorCard *_more;
    NSTextField *_brand,*_website,*_status;
    NSTimer *_refreshTimer;
    NSUInteger _interactionDepth;
}
- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)manager { return [self initWithController:[[PGInspectorController alloc]initWithAPIManager:manager]]; }
- (instancetype)initWithController:(PGInspectorController *)controller {
    if((self=[super initWithFrame:NSMakeRect(0,0,320,100)])){
        _controller=controller;self.appearance=[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        NSArray *sections=@[@"smooth",@"color",@"shape",@"more"],*headings=@[@"磨皮",@"美白",@"瘦脸",@"更多设置"];
        NSArray *colors=@[PGUIColor(.28,.83,.96,1),PGUIColor(.34,.89,.84,1),PGUIColor(.59,.69,.98,1),PGUIColor(.54,.64,.76,1)];
        NSMutableArray *cards=[NSMutableArray new];
        for(NSUInteger index=0;index<sections.count;index++){
            NSString *section=sections[index];PGInspectorCard *card=[[PGInspectorCard alloc]initWithFrame:NSZeroRect];card.accent=colors[index];card.heading=headings[index];card.expanded=index<3;
            card.titleLabel=PGUILabel(headings[index],12,NSFontWeightSemibold);card.titleLabel.textColor=colors[index];[card addSubview:card.titleLabel];NSMutableArray *rows=[NSMutableArray new];
            for(NSDictionary *descriptor in PGInspectorControls()){
                if(![descriptor[@"section"]isEqual:section])continue;
                if([descriptor[@"kind"]isEqual:@"master"]){card.master=PGUIButton(@"eye",colors[index],self,@selector(masterChanged:));card.master.tag=[descriptor[@"id"]integerValue];card.master.identifier=[NSString stringWithFormat:@"pg.master.%@",descriptor[@"id"]];card.master.accessibilityLabel=descriptor[@"name"];card.master.toolTip=descriptor[@"name"];[card addSubview:card.master];continue;}
                PGInspectorRow *row=[[PGInspectorRow alloc]initWithDescriptor:descriptor accent:colors[index] inspector:self];[rows addObject:row];[card addSubview:row];
            }
            card.rows=rows;if(index==3){_more=card;card.master=PGUIButton(@"disclosure",colors[index],self,@selector(moreChanged:));card.master.identifier=@"pg.more";card.master.accessibilityLabel=@"展开更多设置";[card addSubview:card.master];}
            [self addSubview:card];[cards addObject:card];
        }_cards=[cards copy];
        _brand=PGUILabel(@"大鱼 · 人像美化",15,NSFontWeightSemibold);_brand.alignment=NSTextAlignmentCenter;[self addSubview:_brand];
        _website=PGUILabel(@"dayu.media",10,NSFontWeightMedium);_website.alignment=NSTextAlignmentCenter;_website.textColor=PGUIMuted();[self addSubview:_website];
        _status=PGUILabel(@"",10,NSFontWeightRegular);_status.textColor=PGUIMuted();_status.alignment=NSTextAlignmentCenter;[self addSubview:_status];
        [self reloadControls];[self setFrameSize:NSMakeSize(320,[self heightForWidth:320])];
    }return self;
}
- (BOOL)isFlipped { return YES; }
- (CGFloat)heightForWidth:(CGFloat)width { CGFloat h=12;for(PGInspectorCard *card in _cards)h+=[card heightForWidth:MAX(0,width-20)]+10;return h+83; }
- (NSSize)intrinsicContentSize { return NSMakeSize(NSViewNoIntrinsicMetric,[self heightForWidth:NSWidth(self.bounds)>0?NSWidth(self.bounds):320]); }
- (NSSize)fittingSize { CGFloat w=NSWidth(self.bounds)>0?NSWidth(self.bounds):320;return NSMakeSize(w,[self heightForWidth:w]); }
- (void)setFrameSize:(NSSize)newSize { if(_cards)newSize.height=[self heightForWidth:newSize.width];[super setFrameSize:newSize];[self invalidateIntrinsicContentSize];self.needsLayout=YES; }
- (void)layout {
    [super layout];CGFloat w=NSWidth(self.bounds),y=12;for(PGInspectorCard *card in _cards){CGFloat h=[card heightForWidth:w-20];card.frame=NSMakeRect(10,y,MAX(0,w-20),h);y+=h+10;}
    _brand.frame=NSMakeRect(12,y+12,MAX(0,w-24),23);_website.frame=NSMakeRect(12,y+38,MAX(0,w-24),17);_status.frame=NSMakeRect(12,y+61,MAX(0,w-24),16);
}
- (void)drawRect:(NSRect)dirtyRect { [PGUIColor(.035,.060,.105,1)setFill];NSRectFill(dirtyRect); }
- (void)reloadControls {
    PGInspectorState *state=_controller.state;BOOL available=_controller.available;
    for(PGInspectorCard *card in _cards){BOOL master=card==_more || [state valueForParameter:(UInt32)card.master.tag]>.5;
        if(card!=_more){card.master.state=master?NSControlStateValueOn:NSControlStateValueOff;card.master.enabled=available;}
        for(PGInspectorRow *row in card.rows)[row reloadState:state master:master available:available];
    }
    _status.stringValue=_controller.statusMessage.length?_controller.statusMessage:@"自动跟随 · 无需手动分析";_status.toolTip=_status.stringValue;
}
- (BOOL)hasActiveTextEditor { for(PGInspectorCard *card in _cards)for(PGInspectorRow *row in card.rows)if(row.valueField.currentEditor)return YES;return NO; }
- (void)refreshFromHost { if(_interactionDepth || [self hasActiveTextEditor])return;[_controller refresh];[self reloadControls]; }
- (void)hostParameterChanged { if(_interactionDepth || [self hasActiveTextEditor])return;[_controller documentDidChange];[self reloadControls]; }
- (void)writeValue:(double)value parameter:(UInt32)identifier { [_controller setValue:value forParameter:identifier];[self reloadControls]; }
- (void)beginControlInteraction { if(_interactionDepth++==0)[_controller beginInteraction]; }
- (void)endControlInteraction { if(!_interactionDepth)return;if(--_interactionDepth==0){[_controller endInteraction];[self refreshFromHost];} }
- (void)masterChanged:(NSButton *)sender { [_controller setValue:sender.state==NSControlStateValueOn?1:0 forParameter:(UInt32)sender.tag];[self reloadControls]; }
- (void)moreChanged:(NSButton *)sender { _more.expanded=sender.state==NSControlStateValueOn;sender.accessibilityLabel=_more.expanded?@"收起更多设置":@"展开更多设置";[_more setNeedsDisplay:YES];[self setFrameSize:self.frame.size]; }
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];[_refreshTimer invalidate];_refreshTimer=nil;
    if(self.window){[self refreshFromHost];__weak PGInspectorView *weakSelf=self;_refreshTimer=[NSTimer timerWithTimeInterval:.65 repeats:YES block:^(NSTimer *timer){PGInspectorView *view=weakSelf;if(!view||!view.window){[timer invalidate];return;}[view refreshFromHost];}];[[NSRunLoop mainRunLoop]addTimer:_refreshTimer forMode:NSRunLoopCommonModes];}
}
- (void)dealloc { [_refreshTimer invalidate]; }
@end
