#import "CDViews.h"
#import <QuartzCore/QuartzCore.h>
#import <CoreImage/CoreImage.h>

@implementation CDFlippedView
- (BOOL)isFlipped { return YES; }
@end

#pragma mark - Soft button

@interface CDSoftButton ()
@property (nonatomic, strong) CAGradientLayer *glow;
@property (nonatomic, strong) CALayer *content;
@property (nonatomic) BOOL hovering, pressed;
@property (nonatomic) CGSize rendered;
@end

@implementation CDSoftButton
+ (instancetype)buttonWithSymbol:(NSString *)symbol title:(NSString *)title target:(id)target action:(SEL)action {
    CDSoftButton *button = [[self alloc] initWithFrame:NSMakeRect(0, 0, 44, 44)];
    button.symbol = symbol; button.title = title; button.target = target; button.action = action;
    return button;
}
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        self.layer.masksToBounds = NO;
        _glyphSize = 16; _tint = NSColor.whiteColor; _glowColor = NSColor.whiteColor; _restOpacity = .82;
        self.glow = [CAGradientLayer layer];
        self.glow.type = kCAGradientLayerRadial;
        self.glow.startPoint = CGPointMake(.5, .5); self.glow.endPoint = CGPointMake(1, 1);
        self.glow.locations = @[@0, @.42, @1];
        self.content = [CALayer layer];
        self.content.contentsGravity = kCAGravityCenter;
        [self.layer addSublayer:self.glow];
        [self.layer addSublayer:self.content];
        [self refreshGlowColors];
        [self refreshState:NO];
    }
    return self;
}
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (BOOL)isFlipped { return NO; }
- (void)setSymbol:(NSString *)symbol { if ([symbol isEqual:_symbol]) return; _symbol = [symbol copy]; [self renderContent:YES]; }
- (void)setTitle:(NSString *)title { _title = [title copy]; [self renderContent:NO]; }
- (void)setGlyphSize:(CGFloat)glyphSize { if (fabs(glyphSize - _glyphSize) < .01) return; _glyphSize = glyphSize; [self renderContent:NO]; }
- (void)setFont:(NSFont *)font { _font = font; [self renderContent:NO]; }
- (void)setTint:(NSColor *)tint { _tint = tint; [self renderContent:NO]; }
- (void)setGlowColor:(NSColor *)glowColor { _glowColor = glowColor; [self refreshGlowColors]; }
- (void)setRestGlow:(CGFloat)restGlow { _restGlow = restGlow; [self refreshState:NO]; }
- (void)setRestOpacity:(CGFloat)restOpacity { _restOpacity = restOpacity; [self refreshState:NO]; }
- (void)setActive:(BOOL)active { if (_active == active) return; _active = active; [self refreshState:YES]; }
- (void)refreshGlowColors {
    NSColor *c = self.glowColor ?: NSColor.whiteColor;
    self.glow.colors = @[(id)[c colorWithAlphaComponent:.34].CGColor, (id)[c colorWithAlphaComponent:.13].CGColor, (id)[c colorWithAlphaComponent:0].CGColor];
}
- (NSAttributedString *)titleText {
    if (!self.title.length) return nil;
    NSFont *font = self.font ?: [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
    return [[NSAttributedString alloc] initWithString:self.title attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: self.tint, NSKernAttributeName: @(font.pointSize * .16)}];
}
- (NSImage *)glyphImage {
    if (!self.symbol.length) return nil;
    NSImage *symbol = [[NSImage imageWithSystemSymbolName:self.symbol accessibilityDescription:nil] imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:self.glyphSize weight:NSFontWeightMedium]];
    if (!symbol) return nil;
    NSColor *tint = self.tint;
    return [NSImage imageWithSize:symbol.size flipped:NO drawingHandler:^BOOL(NSRect rect) {
        [symbol drawInRect:rect]; [tint set]; NSRectFillUsingOperation(rect, NSCompositingOperationSourceAtop); return YES;
    }];
}
- (CGFloat)contentWidth {
    NSImage *glyph = self.glyphImage;
    NSAttributedString *text = self.titleText;
    CGFloat gap = glyph && text ? self.glyphSize * .5 : 0;
    return ceil((glyph ? glyph.size.width : 0) + gap + (text ? text.size.width : 0));
}
- (void)renderContent:(BOOL)fade {
    CGSize size = self.bounds.size;
    if (size.width < 1) return;
    NSImage *glyph = self.glyphImage;
    NSAttributedString *text = self.titleText;
    CGFloat scale = self.window.backingScaleFactor ?: NSScreen.mainScreen.backingScaleFactor ?: 2;
    NSImage *image = [NSImage imageWithSize:size flipped:NO drawingHandler:^BOOL(NSRect rect) {
        CGFloat gap = glyph && text ? self.glyphSize * .5 : 0;
        CGFloat total = (glyph ? glyph.size.width : 0) + gap + (text ? text.size.width : 0);
        CGFloat x = (size.width - total) / 2;
        if (glyph) { [glyph drawInRect:NSMakeRect(round(x), round((size.height - glyph.size.height) / 2), glyph.size.width, glyph.size.height)]; x += glyph.size.width + gap; }
        if (text) { NSSize t = text.size; [text drawAtPoint:NSMakePoint(round(x), round((size.height - t.height) / 2))]; }
        return YES;
    }];
    if (fade) {
        CATransition *transition = [CATransition animation];
        transition.type = kCATransitionFade; transition.duration = .18;
        [self.content addAnimation:transition forKey:@"contents"];
    }
    self.content.contents = [image layerContentsForContentsScale:scale];
    self.content.contentsScale = scale;
    self.rendered = size;
}
- (void)layout {
    [super layout];
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    CGSize s = self.bounds.size;
    self.glow.frame = CGRectInset(self.bounds, -s.width * .22, -s.height * .22);
    self.content.bounds = self.bounds;
    self.content.position = CGPointMake(s.width / 2, s.height / 2);
    [CATransaction commit];
    if (!CGSizeEqualToSize(self.rendered, s)) [self renderContent:NO];
}
- (void)viewDidChangeBackingProperties { [super viewDidChangeBackingProperties]; [self renderContent:NO]; }
- (void)refreshState:(BOOL)animated {
    [CATransaction begin];
    [CATransaction setAnimationDuration:animated ? (self.pressed ? .08 : .35) : 0];
    [CATransaction setAnimationTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut]];
    CGFloat glow = self.pressed ? 1 : self.hovering ? MAX(.8, self.restGlow) : self.active ? MAX(.6, self.restGlow) : self.restGlow;
    self.glow.opacity = glow;
    self.glow.transform = self.hovering || self.pressed ? CATransform3DMakeScale(1.08, 1.08, 1) : CATransform3DIdentity;
    self.content.opacity = self.hovering || self.pressed || self.active ? 1 : self.restOpacity;
    self.content.transform = self.pressed ? CATransform3DMakeScale(.9, .9, 1) : CATransform3DIdentity;
    [CATransaction commit];
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *area in self.trackingAreas) [self removeTrackingArea:area];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInActiveApp | NSTrackingInVisibleRect owner:self userInfo:nil]];
}
- (void)mouseEntered:(NSEvent *)event { self.hovering = YES; [self refreshState:YES]; }
- (void)mouseExited:(NSEvent *)event { self.hovering = NO; self.pressed = NO; [self refreshState:YES]; }
- (void)mouseDown:(NSEvent *)event { self.pressed = YES; [self refreshState:YES]; }
- (void)mouseDragged:(NSEvent *)event {
    BOOL inside = NSPointInRect([self convertPoint:event.locationInWindow fromView:nil], self.bounds);
    if (inside != self.pressed) { self.pressed = inside; [self refreshState:YES]; }
}
- (void)mouseUp:(NSEvent *)event {
    BOOL inside = NSPointInRect([self convertPoint:event.locationInWindow fromView:nil], self.bounds);
    self.pressed = NO;
    [self refreshState:YES];
    if (inside && self.action) [NSApp sendAction:self.action to:self.target from:self];
}
- (BOOL)isAccessibilityElement { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityButtonRole; }
- (NSString *)accessibilityLabel { return self.toolTip ?: self.title ?: self.symbol; }
- (BOOL)accessibilityPerformPress { if (self.action) [NSApp sendAction:self.action to:self.target from:self]; return YES; }
@end

#pragma mark - Backdrop

static CGImageRef CDSoftDotImage(void) {
    static CGImageRef dot;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const size_t side = 64;
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(NULL, side, side, 8, side * 4, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
        CGFloat components[] = {1, 1, 1, 1, 1, 1, 1, .35, 1, 1, 1, 0};
        CGFloat locations[] = {0, .35, 1};
        CGGradientRef gradient = CGGradientCreateWithColorComponents(space, components, locations, 3);
        CGContextDrawRadialGradient(ctx, gradient, CGPointMake(side / 2.0, side / 2.0), 0, CGPointMake(side / 2.0, side / 2.0), side / 2.0, 0);
        dot = CGBitmapContextCreateImage(ctx);
        CGGradientRelease(gradient); CGContextRelease(ctx); CGColorSpaceRelease(space);
    });
    return dot;
}

static NSColor *CDGrainColor(void) {
    static NSColor *grain;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const size_t side = 160;
        uint8_t *bytes = malloc(side * side * 4);
        uint32_t seed = 0x2545F491;
        for (size_t i = 0; i < side * side; i++) {
            seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5;
            uint8_t v = seed & 0xff;
            bytes[i * 4] = v; bytes[i * 4 + 1] = v; bytes[i * 4 + 2] = v; bytes[i * 4 + 3] = 255;
        }
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(bytes, side, side, 8, side * 4, space, (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
        CGImageRef image = CGBitmapContextCreateImage(ctx);
        grain = [NSColor colorWithPatternImage:[[NSImage alloc] initWithCGImage:image size:NSMakeSize(side / 2.0, side / 2.0)]];
        CGImageRelease(image); CGContextRelease(ctx); CGColorSpaceRelease(space); free(bytes);
    });
    return grain;
}

@interface CDBackdropView ()
@property (nonatomic, strong) CALayer *baseLayer, *imageLayer, *veilLayer, *grainLayer, *blobHost;
@property (nonatomic, strong) CAGradientLayer *vignette, *scrim;
@property (nonatomic, strong, nullable) CIImage *coverInput;
@property (nonatomic, strong) NSArray<CAGradientLayer *> *blobs;
@property (nonatomic, strong) CAEmitterLayer *emitter;
@property (nonatomic, strong) CDPalette *palette;
@property (nonatomic, strong, nullable) NSImage *blurredImage;
@property (nonatomic, readwrite, strong, nullable) NSColor *sampleColor;
@property (nonatomic, readwrite, copy) NSArray<NSColor *> *coverColors;
@property (nonatomic) CGSize laidOut;
@end

@implementation CDBackdropView

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        self.layer.masksToBounds = YES;
        self.coverColors = @[];
        self.baseLayer = [CALayer layer];
        self.imageLayer = [CALayer layer];
        self.imageLayer.contentsGravity = kCAGravityResizeAspectFill;
        self.imageLayer.masksToBounds = YES;
        self.veilLayer = [CALayer layer];
        self.blobHost = [CALayer layer];
        NSMutableArray *blobs = [NSMutableArray new];
        for (int i = 0; i < 4; i++) {
            CAGradientLayer *blob = [CAGradientLayer layer];
            blob.type = kCAGradientLayerRadial;
            blob.startPoint = CGPointMake(.5, .5);
            blob.endPoint = CGPointMake(1, 1);
            blob.locations = @[@0, @.42, @1];
            [self.blobHost addSublayer:blob];
            [blobs addObject:blob];
        }
        self.blobs = blobs;
        self.vignette = [CAGradientLayer layer];
        self.vignette.type = kCAGradientLayerRadial;
        self.vignette.startPoint = CGPointMake(.5, .5);
        self.vignette.endPoint = CGPointMake(1.08, 1.12);
        self.vignette.locations = @[@0, @.5, @1];
        self.scrim = [CAGradientLayer layer];
        self.scrim.startPoint = CGPointMake(.5, 0); self.scrim.endPoint = CGPointMake(.5, 1);
        self.scrim.locations = @[@0, @.14, @.62, @1];
        self.grainLayer = [CALayer layer];
        self.grainLayer.backgroundColor = CDGrainColor().CGColor;
        self.emitter = [CAEmitterLayer layer];
        self.emitter.emitterShape = kCAEmitterLayerLine;
        self.emitter.renderMode = kCAEmitterLayerAdditive;
        for (CALayer *layer in @[self.baseLayer, self.imageLayer, self.veilLayer, self.blobHost, self.vignette, self.scrim, self.grainLayer, self.emitter]) [self.layer addSublayer:layer];
        self.particles = YES;
    }
    return self;
}

- (BOOL)isOpaque { return YES; }

- (void)layout {
    [super layout];
    CGSize size = self.bounds.size;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (CALayer *layer in @[self.baseLayer, self.imageLayer, self.veilLayer, self.blobHost, self.vignette, self.scrim, self.grainLayer, self.emitter]) layer.frame = self.bounds;
    [CATransaction commit];
    if (CGSizeEqualToSize(size, self.laidOut) || size.width < 1) return;
    self.laidOut = size;
    [self layoutBlobs];
    [self configureEmitter];
}

- (void)layoutBlobs {
    CGSize size = self.bounds.size;
    CGFloat big = MAX(size.width, size.height);
    // centre (fractions), drift radius, diameter, period
    CGFloat spec[4][6] = {{.22, .70, .10, .07, .95, 46}, {.80, .66, .08, .10, .85, 58}, {.36, .20, .12, .06, .90, 67}, {.78, .18, .07, .09, .75, 53}};
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (NSUInteger i = 0; i < self.blobs.count; i++) {
        CAGradientLayer *blob = self.blobs[i];
        [blob removeAllAnimations];
        CGFloat d = big * spec[i][4];
        blob.bounds = CGRectMake(0, 0, d, d);
        CGPoint c = CGPointMake(size.width * spec[i][0], size.height * spec[i][1]);
        CGFloat rx = size.width * spec[i][2], ry = size.height * spec[i][3];
        blob.position = CGPointMake(c.x + rx, c.y);
        CAKeyframeAnimation *drift = [CAKeyframeAnimation animationWithKeyPath:@"position"];
        CGPathRef path = CGPathCreateWithEllipseInRect(CGRectMake(c.x - rx, c.y - ry, rx * 2, ry * 2), NULL);
        drift.path = path; CGPathRelease(path);
        drift.duration = spec[i][5];
        drift.repeatCount = HUGE_VALF;
        drift.calculationMode = kCAAnimationPaced;
        drift.beginTime = CACurrentMediaTime() - spec[i][5] * (i * .27);
        drift.removedOnCompletion = NO;
        [blob addAnimation:drift forKey:@"drift"];
        CABasicAnimation *breathe = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
        breathe.fromValue = @.86; breathe.toValue = @1.12;
        breathe.duration = 19 + i * 4; breathe.autoreverses = YES; breathe.repeatCount = HUGE_VALF;
        breathe.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        breathe.removedOnCompletion = NO;
        [blob addAnimation:breathe forKey:@"breathe"];
    }
    [CATransaction commit];
}

- (void)configureEmitter {
    CGSize size = self.bounds.size;
    self.emitter.emitterPosition = CGPointMake(size.width / 2, -12);
    self.emitter.emitterSize = CGSizeMake(size.width * 1.1, 1);
    [self refreshMotes];
    self.emitter.beginTime = CACurrentMediaTime() - 70;   // start with the air already full of motes
}

- (void)refreshMotes {
    if (!self.palette) return;
    CGSize size = self.bounds.size;
    CAEmitterCell *mote = [CAEmitterCell emitterCell];
    mote.contents = (__bridge id)CDSoftDotImage();
    mote.birthRate = self.particles ? MAX(.15, size.width / 1920.0 * .55) : 0;
    mote.lifetime = 95; mote.lifetimeRange = 25;
    mote.velocity = 13; mote.velocityRange = 7;
    mote.emissionLongitude = M_PI_2; mote.emissionRange = M_PI / 9;
    mote.xAcceleration = .35;
    mote.scale = .085; mote.scaleRange = .06; mote.scaleSpeed = -.0004;
    NSColor *tint = self.palette.light ? CDMix(self.palette.accent, NSColor.whiteColor, .25) : [NSColor colorWithWhite:1 alpha:1];
    mote.color = [tint colorWithAlphaComponent:self.palette.light ? .55 : .42].CGColor;
    mote.alphaRange = .2; mote.alphaSpeed = -.0045;
    self.emitter.renderMode = self.palette.light ? kCAEmitterLayerUnordered : kCAEmitterLayerAdditive;
    self.emitter.emitterCells = @[mote];
}

- (void)setParticles:(BOOL)particles { _particles = particles; [self refreshMotes]; }
- (void)setMode:(NSInteger)mode { _mode = MAX(0, MIN(2, mode)); [self applyColours:YES]; }
- (void)setBlurLevel:(NSInteger)blurLevel {
    blurLevel = MAX(0, MIN(2, blurLevel));
    if (blurLevel == _blurLevel) return;
    _blurLevel = blurLevel;
    [self renderBlur:YES];
    [self applyColours:YES];
}
- (void)renderBlur:(BOOL)fadeIn {
    self.blurredImage = nil;
    CIImage *input = self.coverInput;
    if (input) {
        // 朦胧 / 柔和 / 清晰: the clearer levels keep the artwork recognisable behind the stage.
        CGFloat sigma[3] = {.045, .016, .005};
        CIImage *blurred = [[input imageByClampingToExtent] imageByApplyingGaussianBlurWithSigma:input.extent.size.width * sigma[self.blurLevel]];
        CGImageRef output = [[CIContext contextWithOptions:nil] createCGImage:[blurred imageByCroppingToRect:input.extent] fromRect:input.extent];
        if (output) { self.blurredImage = [[NSImage alloc] initWithCGImage:output size:NSZeroSize]; CGImageRelease(output); }
    }
    if (fadeIn) {
        CATransition *fade = [CATransition animation];
        fade.type = kCATransitionFade; fade.duration = .9;
        [self.imageLayer addAnimation:fade forKey:@"contents"];
    }
    self.imageLayer.contents = (__bridge id)CDCGImage(self.blurredImage);
}

- (void)setCoverImage:(NSImage *)image {
    self.blurredImage = nil; self.sampleColor = nil; self.coverColors = @[]; self.coverInput = nil;
    CGImageRef source = CDCGImage(image);
    if (source) {
        CIImage *input = [[CIImage alloc] initWithCGImage:source];
        CGFloat scale = MIN(1, 1100.0 / MAX(1, MAX(input.extent.size.width, input.extent.size.height)));
        input = [input imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
        CIContext *context = [CIContext contextWithOptions:nil];
        CIFilter *average = [CIFilter filterWithName:@"CIAreaAverage"];
        [average setValue:input forKey:kCIInputImageKey];
        [average setValue:[CIVector vectorWithCGRect:input.extent] forKey:kCIInputExtentKey];
        unsigned char pixel[4] = {0};
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        [context render:average.outputImage toBitmap:pixel rowBytes:4 bounds:CGRectMake(0, 0, 1, 1) format:kCIFormatRGBA8 colorSpace:space];
        CGColorSpaceRelease(space);
        self.sampleColor = [NSColor colorWithSRGBRed:pixel[0] / 255.0 green:pixel[1] / 255.0 blue:pixel[2] / 255.0 alpha:1];
        self.coverInput = [input imageByApplyingTransform:CGAffineTransformMakeTranslation(-input.extent.origin.x, -input.extent.origin.y)];
        self.coverColors = CDDominantColors(image, 3);
    }
    [self renderBlur:YES];
    [self applyColours:YES];
}

- (void)applyPalette:(CDPalette *)palette {
    BOOL changed = self.palette != palette;
    self.palette = palette;
    if (changed) [self refreshMotes];
    [self applyColours:YES];
}

- (void)applyColours:(BOOL)animated {
    CDPalette *p = self.palette;
    if (!p) return;
    BOOL light = p.light;
    BOOL hasCover = self.coverColors.count > 0;
    NSColor *base = p.base;
    if (self.mode == 2 && self.sampleColor) base = CDMix(p.base, self.sampleColor, light ? .16 : .2);
    NSArray<NSColor *> *sources = (self.mode != 0 && hasCover) ? self.coverColors : p.aurora;
    CGFloat alpha = light ? .72 : .5;
    if (self.mode == 0) alpha = light ? .62 : .42;
    if (self.mode == 1) alpha *= self.blurLevel == 0 ? .3 : .12;
    [CATransaction begin];
    [CATransaction setAnimationDuration:animated ? 1.4 : 0];
    [CATransaction setAnimationTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut]];
    self.baseLayer.backgroundColor = base.CGColor;
    self.imageLayer.opacity = (self.mode == 1 && self.blurredImage) ? 1 : 0;
    CGFloat veil[3] = {light ? .56 : .5, light ? .36 : .34, light ? .2 : .2};
    self.veilLayer.backgroundColor = [base colorWithAlphaComponent:veil[self.blurLevel]].CGColor;
    self.veilLayer.opacity = (self.mode == 1 && self.blurredImage) ? 1 : 0;
    // Keep text and controls readable at the edges when the cover shows through clearly.
    CGFloat edge = (self.mode == 1 && self.blurredImage) ? (self.blurLevel == 0 ? .15 : self.blurLevel == 1 ? .45 : .62) : 0;
    self.scrim.colors = @[(id)[base colorWithAlphaComponent:edge].CGColor, (id)[base colorWithAlphaComponent:edge * .55].CGColor, (id)[base colorWithAlphaComponent:0].CGColor, (id)[base colorWithAlphaComponent:edge * .7].CGColor];
    for (NSUInteger i = 0; i < self.blobs.count; i++) {
        NSColor *c = sources.count ? sources[i % sources.count] : p.accent;
        if (sources != p.aurora) c = light ? CDMix(c, NSColor.whiteColor, .42) : CDMix(c, p.base, .38);
        CGFloat a = alpha * (i == 3 ? .7 : 1);
        self.blobs[i].colors = @[(id)[c colorWithAlphaComponent:a].CGColor, (id)[c colorWithAlphaComponent:a * .45].CGColor, (id)[c colorWithAlphaComponent:0].CGColor];
    }
    self.vignette.colors = @[(id)[base colorWithAlphaComponent:0].CGColor, (id)[base colorWithAlphaComponent:0].CGColor, (id)[base colorWithAlphaComponent:light ? .55 : .7].CGColor];
    self.grainLayer.opacity = light ? .035 : .045;
    [CATransaction commit];
}
@end

#pragma mark - Slider

@interface CDSliderView ()
@property (nonatomic) BOOL hovering;
@property (nonatomic, readwrite) BOOL scrubbing;
@end

@implementation CDSliderView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) { _step = .05; _restOpacity = 1; }
    return self;
}
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (void)setDoubleValue:(double)value {
    value = MAX(0, MIN(1, value));
    if (fabs(value - _doubleValue) < 1e-5) return;
    _doubleValue = value;
    [self setNeedsDisplay:YES];
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *area in self.trackingAreas) [self removeTrackingArea:area];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInActiveApp | NSTrackingInVisibleRect owner:self userInfo:nil]];
}
- (void)mouseEntered:(NSEvent *)event { self.hovering = YES; [self setNeedsDisplay:YES]; }
- (void)mouseExited:(NSEvent *)event { self.hovering = NO; [self setNeedsDisplay:YES]; }
- (void)resetCursorRects { [self addCursorRect:self.bounds cursor:NSCursor.pointingHandCursor]; }
- (double)valueForEvent:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    CGFloat inset = 6;
    return (p.x - inset) / MAX(1, NSWidth(self.bounds) - inset * 2);
}
- (void)mouseDown:(NSEvent *)event {
    self.scrubbing = YES;
    self.doubleValue = [self valueForEvent:event];
    if (self.onChange) self.onChange(self.doubleValue);
    [self setNeedsDisplay:YES];
}
- (void)mouseDragged:(NSEvent *)event {
    self.doubleValue = [self valueForEvent:event];
    if (self.onChange) self.onChange(self.doubleValue);
}
- (void)mouseUp:(NSEvent *)event {
    self.doubleValue = [self valueForEvent:event];
    self.scrubbing = NO;
    if (self.onCommit) self.onCommit(self.doubleValue);
    [self setNeedsDisplay:YES];
}
- (void)setRestOpacity:(CGFloat)restOpacity { _restOpacity = restOpacity; [self setNeedsDisplay:YES]; }
- (void)drawRect:(NSRect)dirtyRect {
    BOOL active = self.hovering || self.scrubbing;
    CGContextSetAlpha(NSGraphicsContext.currentContext.CGContext, active ? 1 : self.restOpacity);
    CGFloat inset = 6, thickness = active ? 5 : 3;
    NSRect line = NSMakeRect(inset, (NSHeight(self.bounds) - thickness) / 2, NSWidth(self.bounds) - inset * 2, thickness);
    [(self.trackColor ?: [NSColor colorWithWhite:1 alpha:.16]) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:line xRadius:thickness / 2 yRadius:thickness / 2] fill];
    NSRect filled = line; filled.size.width = MAX(thickness, line.size.width * self.doubleValue);
    [(self.fillColor ?: [NSColor colorWithWhite:1 alpha:.72]) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:filled xRadius:thickness / 2 yRadius:thickness / 2] fill];
    if (active) {
        CGFloat d = 12, x = NSMinX(line) + line.size.width * self.doubleValue;
        NSShadow *shadow = [NSShadow new];
        shadow.shadowBlurRadius = 4; shadow.shadowOffset = NSMakeSize(0, -1); shadow.shadowColor = [NSColor colorWithWhite:0 alpha:.25];
        [NSGraphicsContext saveGraphicsState];
        [shadow set];
        [[self.fillColor colorWithAlphaComponent:1] setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x - d / 2, NSMidY(self.bounds) - d / 2, d, d)] fill];
        [NSGraphicsContext restoreGraphicsState];
    }
}
- (BOOL)isAccessibilityElement { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilitySliderRole; }
- (id)accessibilityValue { return @(self.doubleValue); }
- (NSString *)accessibilityValueDescription { return self.valueText ? self.valueText(self.doubleValue) : [NSString stringWithFormat:@"%.0f%%", self.doubleValue * 100]; }
- (BOOL)accessibilityPerformIncrement { self.doubleValue += self.step; if (self.onCommit) self.onCommit(self.doubleValue); return YES; }
- (BOOL)accessibilityPerformDecrement { self.doubleValue -= self.step; if (self.onCommit) self.onCommit(self.doubleValue); return YES; }
@end

#pragma mark - Toast

@interface CDToastView ()
@property (nonatomic, strong) NSView *content;
@property (nonatomic, strong) CAGradientLayer *haze;
@property (nonatomic, strong) NSTextField *label;
@property (nonatomic, strong) NSProgressIndicator *spinner;
@property (nonatomic) NSUInteger token;
@property (nonatomic) BOOL busy, shown;
@property (nonatomic) CGFloat right, centerY;
@end

@implementation CDToastView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        self.layer.masksToBounds = NO;
        // The view's own alpha belongs to the chrome (it fades with the controls in full screen);
        // showing and hiding a message animates the content inside it.
        self.content = [NSView new];
        self.content.wantsLayer = YES;
        self.content.layer.masksToBounds = NO;
        self.haze = [CAGradientLayer layer];
        self.haze.type = kCAGradientLayerRadial;
        self.haze.startPoint = CGPointMake(.5, .5); self.haze.endPoint = CGPointMake(1, 1);
        self.haze.locations = @[@0, @.6, @1];
        [self.content.layer addSublayer:self.haze];
        self.label = [NSTextField labelWithString:@""];
        self.label.font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightRegular];
        self.label.alignment = NSTextAlignmentRight;
        self.label.lineBreakMode = NSLineBreakByTruncatingTail;
        self.spinner = [NSProgressIndicator new];
        self.spinner.style = NSProgressIndicatorStyleSpinning;
        self.spinner.controlSize = NSControlSizeMini;
        self.spinner.displayedWhenStopped = NO;
        [self.content addSubview:self.spinner];
        [self.content addSubview:self.label];
        [self addSubview:self.content];
        self.content.alphaValue = 0;
    }
    return self;
}
- (NSView *)hitTest:(NSPoint)point { return nil; }
- (void)applyPalette:(CDPalette *)palette {
    self.label.textColor = [palette ink:palette.secondary];
    NSColor *base = palette.base;
    self.haze.colors = @[(id)[base colorWithAlphaComponent:.55].CGColor, (id)[base colorWithAlphaComponent:.3].CGColor, (id)[base colorWithAlphaComponent:0].CGColor];
    self.appearance = [NSAppearance appearanceNamed:palette.light ? NSAppearanceNameAqua : NSAppearanceNameDarkAqua];
}
- (void)placeRight:(CGFloat)right centerY:(CGFloat)centerY { self.right = right; self.centerY = centerY; [self sizeToContent]; }
- (void)show:(NSString *)text busy:(BOOL)busy {
    NSUInteger token = ++self.token;
    self.busy = busy;
    self.label.stringValue = text ?: @"";
    if (busy) [self.spinner startAnimation:nil]; else [self.spinner stopAnimation:nil];
    [self sizeToContent];
    if (!self.shown) {
        // Arrive like a notification: a short slide in from the right.
        self.shown = YES;
        CABasicAnimation *slide = [CABasicAnimation animationWithKeyPath:@"transform.translation.x"];
        slide.fromValue = @14; slide.toValue = @0; slide.duration = .45;
        slide.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        [self.content.layer addAnimation:slide forKey:@"slide"];
    }
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) { context.duration = .35; self.content.animator.alphaValue = busy ? .8 : 1; }];
    if (!busy) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (token == self.token) [self hide];
        });
    }
}
- (void)hide {
    self.token++;
    self.shown = NO;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) { context.duration = .6; self.content.animator.alphaValue = 0; } completionHandler:^{ [self.spinner stopAnimation:nil]; }];
}
- (void)sizeToContent {
    NSView *superview = self.superview;
    if (!superview || self.right <= 0) return;
    CGFloat maxWidth = MIN(380, NSWidth(superview.bounds) * .4);
    NSSize text = self.label.intrinsicContentSize;
    CGFloat spin = self.busy ? 18 : 0, height = 28;
    CGFloat width = MIN(maxWidth, ceil(text.width) + 16 + spin);
    CGFloat y = superview.isFlipped ? self.centerY - height / 2 : NSHeight(superview.bounds) - self.centerY - height / 2;
    self.frame = NSIntegralRect(NSMakeRect(self.right - width, y, width, height));
    self.content.frame = self.bounds;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    self.haze.frame = CGRectInset(self.bounds, -24, -16);
    [CATransaction commit];
    self.spinner.frame = NSMakeRect(0, (height - 12) / 2, 12, 12);
    self.label.frame = NSMakeRect(spin, (height - text.height) / 2, width - spin - 4, text.height);
}
- (void)viewDidMoveToSuperview { [self sizeToContent]; }
@end

#pragma mark - Equalizer

@interface CDEqualizerView ()
@property (nonatomic, strong) NSArray<CALayer *> *bars;
@end

@implementation CDEqualizerView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        NSMutableArray *bars = [NSMutableArray new];
        for (int i = 0; i < 3; i++) { CALayer *bar = [CALayer layer]; bar.anchorPoint = CGPointMake(.5, 0); bar.cornerRadius = 1; [self.layer addSublayer:bar]; [bars addObject:bar]; }
        self.bars = bars;
    }
    return self;
}
- (void)layout {
    [super layout];
    CGFloat w = 3, gap = 2.5, h = NSHeight(self.bounds) * .9;
    CGFloat x0 = (NSWidth(self.bounds) - (w * 3 + gap * 2)) / 2;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (NSUInteger i = 0; i < 3; i++) {
        self.bars[i].bounds = CGRectMake(0, 0, w, h);
        self.bars[i].position = CGPointMake(x0 + i * (w + gap) + w / 2, NSHeight(self.bounds) * .05);
    }
    [CATransaction commit];
    [self refresh];
}
- (void)setColor:(NSColor *)color { _color = color; for (CALayer *bar in self.bars) bar.backgroundColor = color.CGColor; }
- (void)setAnimating:(BOOL)animating { if (_animating == animating && self.bars.firstObject.animationKeys.count == (animating ? 1 : 0)) return; _animating = animating; [self refresh]; }
- (void)refresh {
    CGFloat rest[3] = {.35, .6, .45}, durations[3] = {.43, .57, .37};
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (NSUInteger i = 0; i < 3; i++) {
        CALayer *bar = self.bars[i];
        [bar removeAllAnimations];
        bar.transform = CATransform3DMakeScale(1, rest[i], 1);
        if (self.animating) {
            CABasicAnimation *bounce = [CABasicAnimation animationWithKeyPath:@"transform.scale.y"];
            bounce.fromValue = @.22; bounce.toValue = @1;
            bounce.duration = durations[i]; bounce.autoreverses = YES; bounce.repeatCount = HUGE_VALF;
            bounce.timeOffset = i * .21;
            bounce.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
            [bar addAnimation:bounce forKey:@"bounce"];
        }
    }
    [CATransaction commit];
}
@end

#pragma mark - Track list

@interface CDTrackTable : NSTableView
@end
@implementation CDTrackTable
- (BOOL)acceptsFirstResponder { return NO; }
- (void)drawGridInClipRect:(NSRect)clipRect {}
@end

/// Row of the corner list. The playing / hovered row gets a soft, round-ish glow that spills past the row
/// edges (so it never reads as a band or a box), the same light the buttons use.
@interface CDTrackRowView : NSTableRowView
@property (nonatomic) BOOL hovering, current;
@property (nonatomic, strong) NSColor *glowColor;
@property (nonatomic, strong) CAGradientLayer *glow;
@end
@implementation CDTrackRowView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        self.clipsToBounds = NO;
        self.layer.masksToBounds = NO;
        self.glow = [CAGradientLayer layer];
        self.glow.type = kCAGradientLayerRadial;
        self.glow.startPoint = CGPointMake(.5, .5); self.glow.endPoint = CGPointMake(1, 1);
        self.glow.locations = @[@0, @.45, @1];
        self.glow.zPosition = -1;
        self.glow.opacity = 0;
        [self.layer addSublayer:self.glow];
    }
    return self;
}
- (void)setGlowColor:(NSColor *)glowColor {
    _glowColor = glowColor;
    NSColor *c = glowColor ?: NSColor.whiteColor;
    self.glow.colors = @[(id)[c colorWithAlphaComponent:.2].CGColor, (id)[c colorWithAlphaComponent:.08].CGColor, (id)[c colorWithAlphaComponent:0].CGColor];
}
- (void)setCurrent:(BOOL)current { _current = current; [self refreshGlow:NO]; }
- (void)refreshGlow:(BOOL)animated {
    [CATransaction begin];
    [CATransaction setAnimationDuration:animated ? .3 : 0];
    self.glow.opacity = self.current ? 1 : self.hovering ? .55 : 0;
    [CATransaction commit];
}
- (void)layout {
    [super layout];
    CGFloat w = NSWidth(self.bounds), h = NSHeight(self.bounds);
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    self.glow.frame = CGRectMake(0, -h * .55, w * .78, h * 2.1);
    [CATransaction commit];
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *area in self.trackingAreas) [self removeTrackingArea:area];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInActiveApp | NSTrackingInVisibleRect owner:self userInfo:nil]];
}
- (void)mouseEntered:(NSEvent *)event { self.hovering = YES; [self refreshGlow:YES]; }
- (void)mouseExited:(NSEvent *)event { self.hovering = NO; [self refreshGlow:YES]; }
- (void)resetCursorRects { [self addCursorRect:self.bounds cursor:NSCursor.pointingHandCursor]; }
- (void)drawBackgroundInRect:(NSRect)dirtyRect {}
- (void)drawSelectionInRect:(NSRect)dirtyRect {}
@end

/// A title too long for its column, scrolling slowly to the left and looping seamlessly. It rests at the start
/// (with the tail faded out) while paused.
@interface CDMarqueeView : NSView
@property (nonatomic) BOOL running;
- (void)setText:(NSAttributedString *)text scale:(CGFloat)scale;
@end
@interface CDMarqueeView ()
@property (nonatomic, strong) CALayer *strip;
@property (nonatomic, strong) CAGradientLayer *fade;
@property (nonatomic, copy) NSAttributedString *text;
@property (nonatomic) CGFloat scale, textWidth, gap, inset;
@end
@implementation CDMarqueeView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        self.layer.masksToBounds = YES;
        self.strip = [CALayer layer];
        self.strip.anchorPoint = CGPointZero;
        [self.layer addSublayer:self.strip];
        self.fade = [CAGradientLayer layer];
        self.fade.startPoint = CGPointMake(0, .5); self.fade.endPoint = CGPointMake(1, .5);
        self.layer.mask = self.fade;
    }
    return self;
}
- (void)setText:(NSAttributedString *)text scale:(CGFloat)scale {
    if ([text isEqualToAttributedString:self.text] && fabs(scale - self.scale) < .01) return;
    self.text = text; self.scale = scale;
    [self rebuild];
}
- (void)setRunning:(BOOL)running { if (_running == running) return; _running = running; [self restart]; }
- (void)setFrame:(NSRect)frame { BOOL resized = !NSEqualSizes(frame.size, self.frame.size); [super setFrame:frame]; if (resized) [self rebuild]; }
- (void)rebuild {
    NSAttributedString *text = self.text;
    if (!text.length || NSWidth(self.bounds) < 4) return;
    CGFloat s = self.scale ?: 1, h = NSHeight(self.bounds);
    self.inset = round(9 * s); self.gap = round(40 * s);
    NSSize size = text.size;
    self.textWidth = ceil(size.width);
    CGFloat w = self.inset + self.textWidth * 2 + self.gap;
    CGFloat backing = self.window.backingScaleFactor ?: 2, textY = round((h - size.height) / 2);
    CGFloat inset = self.inset, textWidth = self.textWidth, gap = self.gap;
    NSImage *image = [NSImage imageWithSize:NSMakeSize(w, h) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        [text drawAtPoint:NSMakePoint(inset, textY)];
        [text drawAtPoint:NSMakePoint(inset + textWidth + gap, textY)];
        return YES;
    }];
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    self.strip.contents = [image layerContentsForContentsScale:backing];
    self.strip.contentsScale = backing;
    self.strip.bounds = CGRectMake(0, 0, w, h);
    self.strip.position = CGPointZero;
    CGFloat edge = inset / MAX(1, NSWidth(self.bounds)), tail = MIN(.3, round(18 * s) / MAX(1, NSWidth(self.bounds)));
    CGColorRef clear = [NSColor colorWithWhite:0 alpha:0].CGColor, solid = NSColor.blackColor.CGColor;
    self.fade.frame = self.bounds;
    self.fade.colors = @[(__bridge id)clear, (__bridge id)solid, (__bridge id)solid, (__bridge id)clear];
    self.fade.locations = @[@0, @(edge), @(1 - tail), @1];
    [CATransaction commit];
    [self restart];
}
- (void)restart {
    [self.strip removeAnimationForKey:@"scroll"];
    if (!self.running || self.textWidth <= 0) return;
    CGFloat distance = self.textWidth + self.gap, speed = 24 * (self.scale ?: 1), pause = 1.6;
    CFTimeInterval travel = distance / speed, total = pause + travel;
    CAKeyframeAnimation *scroll = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.x"];
    scroll.values = @[@0, @0, @(-distance)];
    scroll.keyTimes = @[@0, @(pause / total), @1];
    scroll.duration = total;
    scroll.repeatCount = HUGE_VALF;
    [self.strip addAnimation:scroll forKey:@"scroll"];
}
- (void)viewDidMoveToWindow { [super viewDidMoveToWindow]; [self restart]; }
@end

@interface CDTrackCellView : NSView
@property (nonatomic, strong) NSTextField *number, *title;
@property (nonatomic, strong) CDMarqueeView *marquee;
@property (nonatomic, strong) CDEqualizerView *equalizer;
@property (nonatomic) CGFloat scale;
@property (nonatomic) BOOL scrolls, playing;
@end
@implementation CDTrackCellView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _scale = 1;
        self.number = [NSTextField labelWithString:@""];
        self.number.alignment = NSTextAlignmentRight;
        self.title = [NSTextField labelWithString:@""];
        self.title.lineBreakMode = NSLineBreakByTruncatingTail;
        self.title.cell.truncatesLastVisibleLine = YES;
        self.marquee = [[CDMarqueeView alloc] initWithFrame:NSZeroRect];
        self.marquee.hidden = YES;
        self.equalizer = [[CDEqualizerView alloc] initWithFrame:NSMakeRect(0, 0, 16, 13)];
        for (NSView *v in @[self.number, self.title, self.marquee, self.equalizer]) [self addSubview:v];
    }
    return self;
}
- (void)layout {
    [super layout];
    CGFloat h = NSHeight(self.bounds), s = self.scale, column = round(30 * s), gap = round(10 * s);
    NSSize n = self.number.intrinsicContentSize, t = self.title.intrinsicContentSize;
    CGFloat eq = round(12 * s);
    self.number.frame = NSMakeRect(0, round((h - n.height) / 2), column, n.height);
    self.equalizer.frame = NSMakeRect(column - round(14 * s), round((h - eq) / 2), round(14 * s), eq);
    NSRect title = NSMakeRect(column + gap, round((h - t.height) / 2), MAX(0, NSWidth(self.bounds) - column - gap - round(6 * s)), t.height);
    self.title.frame = title;
    // Only the playing row scrolls, and only when its name does not fit.
    BOOL overflow = self.scrolls && ceil(self.title.attributedStringValue.size.width) > NSWidth(title) + 1;
    self.title.hidden = overflow;
    self.marquee.hidden = !overflow;
    if (overflow) {
        CGFloat inset = round(9 * s);          // matches CDMarqueeView's inset, so text at rest lines up with the other titles
        self.marquee.frame = NSMakeRect(NSMinX(title) - inset, 0, NSWidth(title) + inset, h);
        [self.marquee setText:self.title.attributedStringValue scale:s];
    }
    self.marquee.running = overflow && self.playing;
}
@end

@interface CDTrackListView () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) NSTextField *headingLabel;
@property (nonatomic, strong) NSScrollView *scroll;
@property (nonatomic, strong) CDTrackTable *table;
@property (nonatomic, strong) CAGradientLayer *fade, *scrim, *glow;
@property (nonatomic) BOOL hovering;
@end

@implementation CDTrackListView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        self.layer.masksToBounds = NO;
        _names = @[]; _heading = @""; _scale = 1; _current = -1;
        // Behind the list: a base-coloured haze that keeps the text legible over a sharp cover, and the
        // same soft glow the buttons use, which only blooms while the pointer is over the list.
        self.scrim = [CAGradientLayer layer];
        self.glow = [CAGradientLayer layer];
        CGFloat z = -2;
        for (CAGradientLayer *l in @[self.scrim, self.glow]) {
            l.zPosition = z++;
            l.type = kCAGradientLayerRadial;
            l.startPoint = CGPointMake(.5, .5); l.endPoint = CGPointMake(1, 1);
            l.locations = @[@0, @.55, @1];
            [self.layer addSublayer:l];
        }
        self.glow.opacity = 0;
        self.headingLabel = [NSTextField labelWithString:@""];
        [self addSubview:self.headingLabel];
        self.scroll = [NSScrollView new];
        self.scroll.drawsBackground = NO;
        // No scroller: the edge fades show there is more, and a wheel / trackpad still scrolls.
        self.scroll.hasVerticalScroller = NO;
        self.scroll.hasHorizontalScroller = NO;
        self.scroll.borderType = NSNoBorder;
        self.scroll.contentView.drawsBackground = NO;
        self.scroll.wantsLayer = YES;
        self.table = [CDTrackTable new];
        self.table.headerView = nil;
        self.table.backgroundColor = NSColor.clearColor;
        self.table.style = NSTableViewStylePlain;
        self.table.selectionHighlightStyle = NSTableViewSelectionHighlightStyleNone;
        self.table.intercellSpacing = NSMakeSize(0, 0);
        self.table.gridStyleMask = NSTableViewGridNone;
        NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"track"];
        column.resizingMask = NSTableColumnAutoresizingMask;
        [self.table addTableColumn:column];
        self.table.columnAutoresizingStyle = NSTableViewFirstColumnOnlyAutoresizingStyle;
        self.table.dataSource = self; self.table.delegate = self;
        self.table.target = self; self.table.action = @selector(rowClicked:);
        self.scroll.documentView = self.table;
        [self addSubview:self.scroll];
        self.fade = [CAGradientLayer layer];
        self.scroll.contentView.postsBoundsChangedNotifications = YES;
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(scrolled:) name:NSViewBoundsDidChangeNotification object:self.scroll.contentView];
    }
    return self;
}
- (BOOL)isFlipped { return YES; }
- (CGFloat)rowHeight { return round((self.face == CDListFaceHand ? 30 : 29) * self.scale); }
- (CGFloat)headerHeight { return round(26 * self.scale); }
- (CGFloat)preferredHeightWithMax:(CGFloat)maxHeight {
    return MIN(maxHeight, self.headerHeight + self.names.count * self.rowHeight + round(4 * self.scale));
}
- (CGFloat)heightForRows:(CGFloat)rows { return self.headerHeight + rows * self.rowHeight; }
- (void)setPalette:(CDPalette *)palette { _palette = palette; [self reload]; }
- (void)setFace:(CDListFace)face { if (_face == face) return; _face = face; [self reload]; }
- (void)setScale:(CGFloat)scale { if (fabs(_scale - scale) < .005) return; _scale = scale; [self reload]; }
- (void)setHeading:(NSString *)heading { _heading = [heading copy] ?: @""; [self reload]; }
- (void)setGlowColor:(NSColor *)glowColor { _glowColor = glowColor; [self reload]; }
- (NSFont *)numberFont {
    CGFloat s = self.scale;
    switch (self.face) {
        case CDListFaceHand: return CDLabelFont(round(13 * s));
        case CDListFaceMono: return [NSFont monospacedSystemFontOfSize:round(11 * s) weight:NSFontWeightRegular];
        default: return [NSFont monospacedDigitSystemFontOfSize:round(11 * s) weight:NSFontWeightRegular];
    }
}
- (NSFont *)titleFont:(BOOL)current {
    CGFloat s = self.scale;
    switch (self.face) {
        case CDListFaceHand: return CDLabelFont(round(15 * s));
        case CDListFaceMono: return [NSFont monospacedSystemFontOfSize:round(12.5 * s) weight:current ? NSFontWeightMedium : NSFontWeightRegular];
        default: return [NSFont systemFontOfSize:round(13.5 * s) weight:current ? NSFontWeightMedium : NSFontWeightRegular];
    }
}
- (void)reload {
    CDPalette *p = self.palette;
    if (!p) return;
    self.table.rowHeight = self.rowHeight;
    NSFont *headingFont = self.face == CDListFaceMono ? [NSFont monospacedSystemFontOfSize:round(10 * self.scale) weight:NSFontWeightMedium] : [NSFont systemFontOfSize:round(10 * self.scale) weight:NSFontWeightSemibold];
    self.headingLabel.attributedStringValue = [[NSAttributedString alloc] initWithString:self.heading attributes:CDTextAttributes(headingFont, [p ink:p.tertiary], 3, NSTextAlignmentLeft)];
    NSColor *haze = p.base, *glow = self.glowColor ?: p.ink;
    self.scrim.colors = @[(id)[haze colorWithAlphaComponent:p.light ? .5 : .55].CGColor, (id)[haze colorWithAlphaComponent:p.light ? .3 : .34].CGColor, (id)[haze colorWithAlphaComponent:0].CGColor];
    self.glow.colors = @[(id)[glow colorWithAlphaComponent:.16].CGColor, (id)[glow colorWithAlphaComponent:.06].CGColor, (id)[glow colorWithAlphaComponent:0].CGColor];
    [self.table reloadData];
    self.needsLayout = YES;
}
- (void)setNames:(NSArray<NSString *> *)names { _names = [names copy] ?: @[]; [self reload]; }
- (void)setCurrent:(NSInteger)current {
    NSInteger old = _current;
    _current = current;
    NSMutableIndexSet *rows = [NSMutableIndexSet new];
    if (old >= 0 && old < (NSInteger)self.names.count) [rows addIndex:old];
    if (current >= 0 && current < (NSInteger)self.names.count) [rows addIndex:current];
    [self refreshRows:rows];
}
- (void)setPlaying:(BOOL)playing {
    if (_playing == playing) return;
    _playing = playing;
    if (self.current >= 0 && self.current < (NSInteger)self.names.count) [self refreshRows:[NSIndexSet indexSetWithIndex:self.current]];
}
- (void)refreshRows:(NSIndexSet *)rows {
    [rows enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *stop) {
        CDTrackRowView *rowView = [self.table rowViewAtRow:row makeIfNecessary:NO];
        CDTrackCellView *cell = [self.table viewAtColumn:0 row:row makeIfNecessary:NO];
        if (rowView) rowView.current = (NSInteger)row == self.current;
        if (cell) [self configure:cell row:row];
    }];
}
/// Brings the playing track to the middle of the little window. Leaves the list alone while the pointer is in it.
- (void)scrollToCurrent:(BOOL)animated {
    if (self.current < 0 || self.current >= (NSInteger)self.names.count || self.hovering) return;
    NSClipView *clip = self.scroll.contentView;
    CGFloat visible = NSHeight(clip.bounds), content = NSHeight(self.table.frame);
    if (visible < 1 || content <= visible) return;
    NSRect row = [self.table rectOfRow:self.current];
    CGFloat y = MAX(0, MIN(content - visible, NSMidY(row) - visible / 2));
    if (fabs(y - NSMinY(clip.bounds)) < 1) return;
    if (animated) {
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = .45;
            context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
            [clip.animator setBoundsOrigin:NSMakePoint(0, y)];
        } completionHandler:^{ [self.scroll reflectScrolledClipView:clip]; [self updateFade]; }];
    } else {
        [clip setBoundsOrigin:NSMakePoint(0, y)];
        [self.scroll reflectScrolledClipView:clip];
        [self updateFade];
    }
}
- (void)rowClicked:(id)sender {
    NSInteger row = self.table.clickedRow;
    if (row >= 0 && self.onSelect) self.onSelect(row);
}
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return self.names.count; }
- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row {
    CDTrackRowView *view = [CDTrackRowView new];
    view.glowColor = self.glowColor ?: self.palette.ink;
    view.current = row == self.current;
    return view;
}
- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    CDTrackCellView *cell = [tableView makeViewWithIdentifier:@"cell" owner:self];
    if (!cell) { cell = [[CDTrackCellView alloc] initWithFrame:NSMakeRect(0, 0, 200, self.rowHeight)]; cell.identifier = @"cell"; }
    [self configure:cell row:row];
    return cell;
}
- (void)configure:(CDTrackCellView *)cell row:(NSInteger)row {
    CDPalette *p = self.palette;
    BOOL current = row == self.current;
    NSString *name = row < (NSInteger)self.names.count ? self.names[row] : @"";
    cell.scale = self.scale;
    cell.number.attributedStringValue = [[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"%ld.", (long)row + 1] attributes:CDTextAttributes(self.numberFont, [p ink:p.tertiary], .2, NSTextAlignmentRight)];
    cell.title.attributedStringValue = [[NSAttributedString alloc] initWithString:name attributes:CDTextAttributes([self titleFont:current], [p ink:current ? .96 : p.secondary], 0, NSTextAlignmentLeft)];
    cell.equalizer.color = p.light ? CDMix(p.accent, p.ink, .2) : CDMix(p.ink, p.accent, .4);
    cell.number.hidden = current;
    cell.equalizer.hidden = !current;
    cell.equalizer.animating = current && self.playing;
    cell.scrolls = current;
    cell.playing = self.playing;
    cell.needsLayout = YES;
}
- (void)layout {
    [super layout];
    CGFloat s = self.scale, w = NSWidth(self.bounds), h = NSHeight(self.bounds);
    NSSize head = self.headingLabel.intrinsicContentSize;
    // The heading sits over the number column, so "LIST" lines up with "1.".
    self.headingLabel.frame = NSMakeRect(round(8 * s), round((self.headerHeight - head.height) / 2) - round(2 * s), w - round(8 * s), head.height);
    self.scroll.frame = NSMakeRect(0, self.headerHeight, w, MAX(0, h - self.headerHeight));
    [self.table sizeLastColumnToFit];
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    self.scrim.frame = CGRectInset(self.bounds, -w * .3, -h * .45);
    self.glow.frame = CGRectInset(self.bounds, -w * .18, -h * .28);
    [CATransaction commit];
    [self updateFade];
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *area in self.trackingAreas) [self removeTrackingArea:area];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInActiveApp | NSTrackingInVisibleRect owner:self userInfo:nil]];
}
- (void)mouseEntered:(NSEvent *)event { self.hovering = YES; [self refreshGlow]; }
- (void)mouseExited:(NSEvent *)event { self.hovering = NO; [self refreshGlow]; }
- (void)refreshGlow {
    [CATransaction begin];
    [CATransaction setAnimationDuration:.35];
    self.glow.opacity = self.hovering ? 1 : 0;
    [CATransaction commit];
}
- (void)scrolled:(NSNotification *)note { [self updateFade]; }
- (void)updateFade {
    NSRect visible = self.scroll.contentView.bounds;
    CGFloat content = NSHeight(self.table.frame);
    BOOL scrollable = content > NSHeight(visible) + 1;
    if (!scrollable) { self.scroll.layer.mask = nil; return; }
    CGFloat h = MAX(1, NSHeight(self.scroll.bounds));
    BOOL atTop = NSMinY(visible) <= 1, atBottom = NSMaxY(visible) >= content - 1;
    // Eased (smoothstep) fades: a row and a half at the cut-off bottom, one row at the top once scrolled.
    CGFloat bottom = atBottom ? 0 : MIN(.45, self.rowHeight * 1.5 / h), top = atTop ? 0 : MIN(.3, self.rowHeight / h);
    NSMutableArray *colors = [NSMutableArray new], *locations = [NSMutableArray new];
    void (^stop)(CGFloat, CGFloat) = ^(CGFloat location, CGFloat alpha) {
        [colors addObject:(__bridge id)[NSColor colorWithWhite:0 alpha:alpha].CGColor];
        [locations addObject:@(location)];
    };
    const int steps = 6;
    for (int k = 0; k <= steps; k++) { CGFloat t = (CGFloat)k / steps; stop(top * t, top > 0 ? t * t * (3 - 2 * t) : 1); }
    for (int k = 0; k <= steps; k++) { CGFloat t = (CGFloat)k / steps; stop(1 - bottom * (1 - t), bottom > 0 ? 1 - t * t * (3 - 2 * t) : 1); }
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    self.fade.frame = self.scroll.bounds;
    self.fade.colors = colors;
    // The scroll view is flipped: location 0 is its top edge.
    self.fade.locations = locations;
    self.fade.startPoint = CGPointMake(.5, 0); self.fade.endPoint = CGPointMake(.5, 1);
    self.scroll.layer.mask = self.fade;
    [CATransaction commit];
}
@end

#pragma mark - Candidate tile

@interface CDCandidateTile ()
@property (nonatomic, strong) CALayer *imageLayer;
@property (nonatomic, strong) NSArray<CALayer *> *stackLayers;
@property (nonatomic, strong) NSView *imageHost;
@property (nonatomic, strong) NSTextField *badge, *titleLabel, *detailLabel, *stackLabel;
@property (nonatomic, strong) NSButton *link, *previous, *next;
@property (nonatomic) BOOL hovering;
@end

@implementation CDCandidateTile
+ (CGFloat)heightForWidth:(CGFloat)width { return width + 94; }
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        CALayer *back = [CALayer layer], *middle = [CALayer layer];
        self.stackLayers = @[back, middle];
        for (CALayer *layer in self.stackLayers) {
            layer.cornerRadius = 10;
            layer.borderWidth = 1;
            layer.borderColor = [NSColor colorWithWhite:1 alpha:.7].CGColor;
            layer.contentsGravity = kCAGravityResizeAspectFill;
            layer.masksToBounds = YES;
            [self.layer addSublayer:layer];
        }
        self.imageHost = [NSView new];
        self.imageHost.wantsLayer = YES;
        self.imageHost.layer.cornerRadius = 10;
        self.imageHost.layer.masksToBounds = YES;
        self.imageHost.layer.backgroundColor = [NSColor colorWithWhite:.5 alpha:.08].CGColor;
        self.imageHost.layer.borderColor = [NSColor colorWithWhite:.5 alpha:.2].CGColor;
        self.imageHost.layer.borderWidth = 1;
        self.imageLayer = [CALayer layer];
        self.imageLayer.contentsGravity = kCAGravityResizeAspect;
        [self.imageHost.layer addSublayer:self.imageLayer];
        [self addSubview:self.imageHost];
        self.stackLabel = [NSTextField labelWithString:@""];
        self.stackLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
        self.stackLabel.alignment = NSTextAlignmentCenter;
        self.stackLabel.textColor = NSColor.whiteColor;
        self.stackLabel.wantsLayer = YES;
        self.stackLabel.layer.cornerRadius = 10;
        self.stackLabel.layer.backgroundColor = [NSColor colorWithWhite:0 alpha:.55].CGColor;
        self.previous = [NSButton buttonWithTitle:@"‹" target:self action:@selector(previousImage:)];
        self.next = [NSButton buttonWithTitle:@"›" target:self action:@selector(nextImage:)];
        for (NSButton *button in @[self.previous, self.next]) {
            button.bordered = NO;
            button.font = [NSFont systemFontOfSize:27 weight:NSFontWeightLight];
            button.contentTintColor = NSColor.whiteColor;
            button.wantsLayer = YES;
            button.layer.cornerRadius = 17;
            button.layer.backgroundColor = [NSColor colorWithWhite:0 alpha:.5].CGColor;
            [self addSubview:button];
        }
        [self addSubview:self.stackLabel];
        self.badge = [NSTextField labelWithString:@"使用中"];
        self.badge.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
        self.badge.textColor = NSColor.whiteColor;
        self.badge.alignment = NSTextAlignmentCenter;
        self.badge.wantsLayer = YES;
        self.badge.layer.backgroundColor = NSColor.controlAccentColor.CGColor;
        self.badge.layer.cornerRadius = 9;
        [self addSubview:self.badge];
        self.titleLabel = [NSTextField wrappingLabelWithString:@""];
        self.titleLabel.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
        self.titleLabel.maximumNumberOfLines = 2;
        self.titleLabel.cell.truncatesLastVisibleLine = YES;
        self.titleLabel.lineBreakMode = NSLineBreakByWordWrapping;
        self.detailLabel = [NSTextField labelWithString:@""];
        self.detailLabel.font = [NSFont systemFontOfSize:11];
        self.detailLabel.textColor = NSColor.secondaryLabelColor;
        self.detailLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        self.link = [NSButton buttonWithTitle:@"查看来源 ↗" target:self action:@selector(openSource:)];
        self.link.bordered = NO;
        self.link.alignment = NSTextAlignmentLeft;
        self.link.font = [NSFont systemFontOfSize:11];
        self.link.contentTintColor = NSColor.linkColor;
        self.link.attributedTitle = [[NSAttributedString alloc] initWithString:@"查看来源 ↗" attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:11], NSForegroundColorAttributeName: NSColor.linkColor}];
        for (NSView *v in @[self.titleLabel, self.detailLabel, self.link]) [self addSubview:v];
    }
    return self;
}
- (BOOL)isFlipped { return YES; }
- (void)setImage:(NSImage *)image { _image = image; self.imageLayer.contents = (__bridge id)CDCGImage(image); }
- (void)setTitle:(NSString *)title { _title = [title copy]; self.titleLabel.stringValue = title ?: @""; }
- (void)setDetail:(NSString *)detail { _detail = [detail copy]; self.detailLabel.stringValue = detail ?: @""; }
- (void)setCurrent:(BOOL)current { _current = current; self.badge.hidden = !current; [self refreshBorder]; }
- (void)setHasSource:(BOOL)hasSource { _hasSource = hasSource; self.link.hidden = !hasSource; }
- (void)setStackCount:(NSUInteger)stackCount { _stackCount = stackCount; [self refreshStack]; [self setNeedsLayout:YES]; }
- (void)setStackIndex:(NSUInteger)stackIndex { _stackIndex = stackIndex; [self refreshStack]; }
- (void)setStackPreviewImages:(NSArray<NSImage *> *)stackPreviewImages {
    _stackPreviewImages = [stackPreviewImages copy];
    for (NSUInteger i = 0; i < self.stackLayers.count; i++) self.stackLayers[i].contents = i < _stackPreviewImages.count ? (__bridge id)CDCGImage(_stackPreviewImages[i]) : nil;
}
- (void)refreshStack {
    BOOL multi = self.stackCount > 1;
    self.stackLabel.hidden = self.previous.hidden = self.next.hidden = !multi;
    for (CALayer *layer in self.stackLayers) layer.hidden = !multi;
    self.stackLabel.stringValue = multi ? [NSString stringWithFormat:@"%lu / %lu", (unsigned long)(self.stackIndex + 1), (unsigned long)self.stackCount] : @"";
}
- (void)previousImage:(id)sender { if (self.onPrevious) self.onPrevious(); }
- (void)nextImage:(id)sender { if (self.onNext) self.onNext(); }
- (void)refreshBorder {
    BOOL strong = self.current || self.hovering;
    self.imageHost.layer.borderWidth = self.current ? 2.5 : (self.hovering ? 2 : 1);
    self.imageHost.layer.borderColor = strong ? NSColor.controlAccentColor.CGColor : [NSColor colorWithWhite:.5 alpha:.2].CGColor;
}
- (void)layout {
    [super layout];
    CGFloat w = NSWidth(self.bounds);
    CGFloat side = self.stackCount > 1 ? w - 13 : w;
    self.imageHost.frame = NSMakeRect(0, 0, side, side);
    self.imageLayer.frame = NSInsetRect(self.imageHost.bounds, 6, 6);
    self.stackLayers[0].frame = NSMakeRect(12, 12, side, side);
    self.stackLayers[1].frame = NSMakeRect(6, 6, side, side);
    self.previous.frame = NSMakeRect(7, side / 2 - 17, 34, 34);
    self.next.frame = NSMakeRect(side - 41, side / 2 - 17, 34, 34);
    self.stackLabel.frame = NSMakeRect(w - 66, 10, 56, 21);
    NSSize badge = self.badge.intrinsicContentSize;
    self.badge.frame = NSMakeRect(10, 10, badge.width + 16, 18);
    self.titleLabel.preferredMaxLayoutWidth = w;
    self.titleLabel.frame = NSMakeRect(0, w + 8, w, 32);
    self.detailLabel.frame = NSMakeRect(0, w + 42, w, 16);
    NSSize link = self.link.intrinsicContentSize;
    self.link.frame = NSMakeRect(-2, w + 62, link.width + 4, 20);
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *area in self.trackingAreas) [self removeTrackingArea:area];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect owner:self userInfo:nil]];
}
- (void)mouseEntered:(NSEvent *)event { self.hovering = YES; [self refreshBorder]; }
- (void)mouseExited:(NSEvent *)event { self.hovering = NO; [self refreshBorder]; }
- (void)resetCursorRects { [self addCursorRect:self.imageHost.frame cursor:NSCursor.pointingHandCursor]; }
- (void)mouseDown:(NSEvent *)event {}
- (void)mouseUp:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    if (NSPointInRect(p, self.imageHost.frame) && self.onChoose) self.onChoose();
}
- (void)openSource:(id)sender { if (self.onOpenSource) self.onOpenSource(); }
- (BOOL)isAccessibilityElement { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityButtonRole; }
- (NSString *)accessibilityLabel { return [NSString stringWithFormat:@"%@使用封面：%@，%@%@", self.current ? @"正在" : @"", self.title, self.detail, self.stackCount > 1 ? [NSString stringWithFormat:@"，第 %lu 张，共 %lu 张",(unsigned long)(self.stackIndex+1),(unsigned long)self.stackCount] : @""]; }
- (BOOL)accessibilityPerformPress { if (self.onChoose) self.onChoose(); return YES; }
@end

#pragma mark - Drop overlay

@interface CDDropOverlay ()
@property (nonatomic, strong) CDPalette *palette;
@end
@implementation CDDropOverlay
- (NSView *)hitTest:(NSPoint)point { return nil; }
- (void)applyPalette:(CDPalette *)palette { self.palette = palette; [self setNeedsDisplay:YES]; }
- (void)setMessage:(NSString *)message { _message = [message copy]; [self setNeedsDisplay:YES]; }
- (void)drawRect:(NSRect)dirtyRect {
    CDPalette *p = self.palette;
    NSRect r = NSInsetRect(self.bounds, 22, 22);
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:r xRadius:26 yRadius:26];
    [[p ink:.05] setFill]; [path fill];
    CGFloat dash[] = {10, 8};
    [path setLineDash:dash count:2 phase:0];
    path.lineWidth = 2;
    [[p.accent colorWithAlphaComponent:.8] setStroke]; [path stroke];
    NSAttributedString *text = [[NSAttributedString alloc] initWithString:self.message ?: @"" attributes:CDTextAttributes([NSFont systemFontOfSize:22 weight:NSFontWeightLight], [p ink:.85], .5, NSTextAlignmentCenter)];
    NSSize size = text.size;
    [text drawInRect:NSMakeRect(NSMinX(r), NSMidY(r) - size.height / 2, NSWidth(r), size.height)];
}
@end
