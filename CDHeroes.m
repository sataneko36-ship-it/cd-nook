#import "CDHeroes.h"
#import "CDPixelArt.h"
#import <QuartzCore/QuartzCore.h>
#import <CoreImage/CoreImage.h>

@implementation CDNowPlaying
- (instancetype)init {
    if ((self = [super init])) { _album = @""; _artist = @""; _track = @""; _trackNames = @[]; _volume = 75; }
    return self;
}
@end

#pragma mark - Helpers

static void CDSetContents(CALayer *layer, id contents, CFTimeInterval fade) {
    if (fade > 0) {
        CATransition *transition = [CATransition animation];
        transition.type = kCATransitionFade;
        transition.duration = fade;
        [layer addAnimation:transition forKey:@"contents"];
    }
    layer.contents = contents;
}

static CGPathRef CDCirclePath(CGPoint c, CGFloat r) {
    return CGPathCreateWithEllipseInRect(CGRectMake(c.x - r, c.y - r, r * 2, r * 2), NULL);
}

static CGPathRef CDAnnulusPath(CGPoint c, CGFloat outer, CGFloat inner) {
    CGMutablePathRef path = CGPathCreateMutable();
    CGPathAddEllipseInRect(path, NULL, CGRectMake(c.x - outer, c.y - outer, outer * 2, outer * 2));
    CGPathAddEllipseInRect(path, NULL, CGRectMake(c.x - inner, c.y - inner, inner * 2, inner * 2));
    return path;
}

static CAShapeLayer *CDAnnulusMask(CGRect bounds, CGFloat outer, CGFloat inner) {
    CAShapeLayer *mask = [CAShapeLayer layer];
    mask.frame = bounds;
    CGPathRef path = CDAnnulusPath(CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds)), outer, inner);
    mask.path = path; CGPathRelease(path);
    mask.fillRule = kCAFillRuleEvenOdd;
    return mask;
}

static CGFloat CDBackingScale(NSView *view) { return view.window.backingScaleFactor ?: NSScreen.mainScreen.backingScaleFactor ?: 2; }

/// Draw into a bitmap of `size` points at the view's backing scale.
CGImageRef _Nullable CDRenderImage(CGSize size, CGFloat scale, void (^draw)(CGContextRef ctx, CGSize size)) {
    size_t w = MAX(1, (size_t)ceil(size.width * scale)), h = MAX(1, (size_t)ceil(size.height * scale));
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, w * 4, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    if (!ctx) return NULL;
    CGContextScaleCTM(ctx, scale, scale);
    NSGraphicsContext *previous = NSGraphicsContext.currentContext;
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:NO];
    draw(ctx, size);
    NSGraphicsContext.currentContext = previous;
    CGImageRef image = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return image;
}

static double CDApproach(double value, double target, double rate, double dt) {
    return value + (target - value) * MIN(1.0, rate * dt);
}

NSImage *CDPlaceholderCover(CDPalette *palette, NSString *caption) {
    return [NSImage imageWithSize:NSMakeSize(600, 600) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        NSGradient *gradient = [[NSGradient alloc] initWithStartingColor:CDMix(palette.surface, palette.accent, palette.light ? .10 : .08) endingColor:palette.surface];
        [gradient drawInRect:rect angle:-60];
        NSColor *line = [palette ink:palette.light ? .16 : .2];
        [line setStroke];
        for (NSNumber *r in @[@176, @72, @22]) {
            NSBezierPath *ring = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(300 - r.doubleValue, 318 - r.doubleValue, r.doubleValue * 2, r.doubleValue * 2)];
            ring.lineWidth = r.doubleValue > 100 ? 1.6 : 1.1;
            [ring stroke];
        }
        NSAttributedString *text = [[NSAttributedString alloc] initWithString:caption ?: @"CD NOOK" attributes:CDTextAttributes([NSFont systemFontOfSize:17 weight:NSFontWeightMedium], [palette ink:.38], 6, NSTextAlignmentCenter)];
        [text drawInRect:NSMakeRect(40, 70, 520, 26)];
        return YES;
    }];
}

/// The window with no CD in shows a sleeve of its own, edge to edge like any cover: IdleCover.jpg (the 甲鉄城のカバネリ
/// soundtrack cover, 4× through the app's own upscaler, 1800 × 1608 — filled into the square like any other).
NSImage *CDIdleCover(void) {
    static NSImage *art;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = [NSBundle.mainBundle pathForResource:@"IdleCover" ofType:@"jpg"];
        NSBitmapImageRep *rep = path ? [[NSBitmapImageRep alloc] initWithData:[NSData dataWithContentsOfFile:path]] : nil;
        if (rep.CGImage) art = [[NSImage alloc] initWithCGImage:rep.CGImage size:NSMakeSize(rep.pixelsWide, rep.pixelsHigh)];
    });
    return art;
}

#pragma mark - Base

@interface CDHeroView ()
@property (nonatomic) CGSize laidOut;
@end

@implementation CDHeroView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        self.layer.masksToBounds = NO;
        _coverColors = @[];
        _np = [CDNowPlaying new];
    }
    return self;
}
- (CGFloat)aspect { return 1; }
- (NSRect)objectRect {
    NSRect b = self.bounds;
    CGFloat w = NSWidth(b), h = NSHeight(b);
    if (w / MAX(1, h) > self.aspect) w = h * self.aspect; else h = w / self.aspect;
    return NSMakeRect(round(NSMidX(b) - w / 2), round(NSMidY(b) - h / 2), round(w), round(h));
}
- (void)setCover:(NSImage *)cover { _cover = cover; [self coverChanged]; }
- (void)setPalette:(CDPalette *)palette { _palette = palette; [self paletteChanged]; if (!_cover) [self coverChanged]; }
- (void)setCoverColors:(NSArray<NSColor *> *)coverColors { _coverColors = [coverColors copy] ?: @[]; [self paletteChanged]; }
- (void)coverChanged {}
- (void)paletteChanged {}
- (void)nowPlayingChanged {}
- (void)progressChanged {}
- (void)step:(CFTimeInterval)dt {}
- (void)rebuild {}
- (void)layout {
    [super layout];
    if (CGSizeEqualToSize(self.bounds.size, self.laidOut) || NSWidth(self.bounds) < 2 || !self.palette) return;
    self.laidOut = self.bounds.size;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [self rebuild];
    [CATransaction commit];
}
- (void)forceRebuild { self.laidOut = CGSizeZero; self.needsLayout = YES; }
- (NSImage *)displayCover { return self.cover ?: (!self.np.hasSession && CDIdleCover() ? CDIdleCover() : CDPlaceholderCover(self.palette, nil)); }
- (NSColor *)glowColor {
    NSColor *c = self.coverColors.firstObject ?: self.palette.accent;
    return self.palette.light ? CDMix(c, NSColor.whiteColor, .1) : c;
}
@end

#pragma mark - Ethereal: the floating cover

@interface CDEtherealHero ()
@property (nonatomic, strong) CALayer *host, *glow, *contact, *image, *sheen;
@property (nonatomic) BOOL wasPlaying;
@end

@implementation CDEtherealHero
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.host = [CALayer layer];
        self.glow = [CALayer layer];
        self.contact = [CALayer layer];
        self.image = [CALayer layer];
        self.image.contentsGravity = kCAGravityResizeAspectFill;
        self.image.masksToBounds = YES;
        self.sheen = [CAGradientLayer layer];
        [self.image addSublayer:self.sheen];
        for (CALayer *l in @[self.glow, self.contact, self.image]) [self.host addSublayer:l];
        [self.layer addSublayer:self.host];
    }
    return self;
}
- (void)rebuild {
    NSRect r = self.objectRect;
    CGFloat s = NSWidth(r), radius = s * .028;
    CATransform3D keep = self.host.transform;
    self.host.transform = CATransform3DIdentity;
    self.host.bounds = CGRectMake(0, 0, s, s);
    self.host.position = CGPointMake(NSMidX(r), NSMidY(r));
    CGRect box = self.host.bounds;
    CGPathRef shape = CGPathCreateWithRoundedRect(box, radius, radius, NULL);
    for (CALayer *l in @[self.glow, self.contact]) { l.frame = box; l.shadowPath = shape; }
    CGPathRelease(shape);
    self.glow.shadowRadius = s * .11; self.glow.shadowOffset = CGSizeMake(0, -s * .045);
    self.contact.shadowRadius = s * .025; self.contact.shadowOffset = CGSizeMake(0, -s * .012);
    self.image.frame = box; self.image.cornerRadius = radius;
    self.sheen.frame = box;
    CAGradientLayer *sheen = (CAGradientLayer *)self.sheen;
    sheen.startPoint = CGPointMake(0, 1); sheen.endPoint = CGPointMake(1, 0);
    sheen.colors = @[(id)[NSColor colorWithWhite:1 alpha:.16].CGColor, (id)[NSColor colorWithWhite:1 alpha:0].CGColor, (id)[NSColor colorWithWhite:1 alpha:0].CGColor, (id)[NSColor colorWithWhite:1 alpha:.05].CGColor];
    sheen.locations = @[@0, @.38, @.8, @1];
    self.host.transform = keep;
    [self paletteChanged];
    [self coverChanged];
}
- (void)paletteChanged {
    if (!self.palette) return;
    self.glow.shadowColor = self.glowColor.CGColor;
    self.glow.shadowOpacity = self.palette.light ? .55 : .6;
    self.contact.shadowColor = NSColor.blackColor.CGColor;
    self.contact.shadowOpacity = self.palette.light ? .14 : .45;
    self.image.borderWidth = 1;
    self.image.borderColor = (self.palette.light ? [NSColor colorWithWhite:0 alpha:.07] : [NSColor colorWithWhite:1 alpha:.14]).CGColor;
}
- (void)coverChanged {
    if (!self.palette) return;
    CDSetContents(self.image, (__bridge id)CDCGImage(self.displayCover), .7);
}
- (void)step:(CFTimeInterval)dt {
    BOOL playing = self.np.playing;
    if (playing == self.wasPlaying) return;
    self.wasPlaying = playing;
    [CATransaction begin];
    [CATransaction setAnimationDuration:.7];
    [CATransaction setAnimationTimingFunction:[CAMediaTimingFunction functionWithControlPoints:.2 :.9 :.25 :1]];
    self.host.transform = playing || !self.np.hasSession ? CATransform3DIdentity : CATransform3DMakeScale(.955, .955, 1);
    [CATransaction commit];
    [self.glow removeAnimationForKey:@"breathe"];
    if (playing) {
        CABasicAnimation *breathe = [CABasicAnimation animationWithKeyPath:@"shadowOpacity"];
        breathe.fromValue = @(self.glow.shadowOpacity * .7); breathe.toValue = @(MIN(1, self.glow.shadowOpacity * 1.25));
        breathe.duration = 4.5; breathe.autoreverses = YES; breathe.repeatCount = HUGE_VALF;
        breathe.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [self.glow addAnimation:breathe forKey:@"breathe"];
    }
}
@end

#pragma mark - CD: jewel case with a spinning disc

@interface CDDiscHero ()
@property (nonatomic, strong) CALayer *caseHost, *caseBack, *insert, *discShadow, *discHost, *rotor, *print;
@property (nonatomic, strong) CAGradientLayer *hinge, *plastic, *glare, *discBase, *sheen, *highlight;
@property (nonatomic, strong) CAShapeLayer *hub, *rim, *edge, *ridges;
@property (nonatomic) double angle, omega, slide;
@property (nonatomic, copy) NSString *printedText;
@end

@implementation CDDiscHero
- (CGFloat)aspect { return 1.66; }
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.discShadow = [CALayer layer];
        self.discHost = [CALayer layer];
        self.rotor = [CALayer layer];
        self.discBase = [CAGradientLayer layer];
        self.print = [CALayer layer];
        self.sheen = [CAGradientLayer layer];
        self.highlight = [CAGradientLayer layer];
        self.hub = [CAShapeLayer layer];
        self.rim = [CAShapeLayer layer];
        [self.rotor addSublayer:self.discBase];
        [self.rotor addSublayer:self.print];
        for (CALayer *l in @[self.rotor, self.sheen, self.highlight, self.hub, self.rim]) [self.discHost addSublayer:l];
        self.caseHost = [CALayer layer];
        self.caseBack = [CALayer layer];
        self.insert = [CALayer layer];
        self.insert.contentsGravity = kCAGravityResizeAspectFill;
        self.insert.masksToBounds = YES;
        self.hinge = [CAGradientLayer layer];
        self.ridges = [CAShapeLayer layer];
        self.plastic = [CAGradientLayer layer];
        self.glare = [CAGradientLayer layer];
        self.edge = [CAShapeLayer layer];
        for (CALayer *l in @[self.caseBack, self.insert, self.hinge, self.ridges, self.plastic, self.glare, self.edge]) [self.caseHost addSublayer:l];
        for (CALayer *l in @[self.discShadow, self.discHost, self.caseHost]) [self.layer addSublayer:l];
        self.slide = .55;
    }
    return self;
}
- (CGFloat)unit { return NSHeight(self.objectRect); }
- (CGPoint)discCenterForSlide:(double)slide {
    NSRect r = self.objectRect; CGFloat H = NSHeight(r), D = H * .94;
    CGFloat tucked = NSMinX(r) + H * .62, out = NSMinX(r) + H * 1.66 - D / 2;
    return CGPointMake(tucked + (out - tucked) * slide, NSMidY(r));
}
- (void)rebuild {
    NSRect r = self.objectRect;
    CGFloat H = NSHeight(r), W = H * 1.13, D = H * .94, radius = H * .012;
    // Disc
    CGRect disc = CGRectMake(0, 0, D, D);
    CGPoint c = CGPointMake(D / 2, D / 2);
    self.discHost.bounds = disc;
    self.discHost.position = [self discCenterForSlide:self.slide];
    self.discShadow.bounds = disc;
    self.discShadow.position = self.discHost.position;
    CGPathRef circle = CDCirclePath(c, D / 2);
    self.discShadow.shadowPath = circle;
    self.discShadow.shadowColor = NSColor.blackColor.CGColor;
    self.discShadow.shadowRadius = H * .035; self.discShadow.shadowOffset = CGSizeMake(0, -H * .015);
    self.rotor.bounds = disc; self.rotor.position = c;
    self.discBase.frame = disc;
    self.discBase.type = kCAGradientLayerRadial;
    self.discBase.startPoint = CGPointMake(.5, .5); self.discBase.endPoint = CGPointMake(1, 1);
    self.discBase.colors = @[(id)CDHex(0xF2F3F4).CGColor, (id)CDHex(0xD9DBDE).CGColor, (id)CDHex(0xBFC2C6).CGColor, (id)CDHex(0xE2E3E5).CGColor];
    self.discBase.locations = @[@0, @.5, @.86, @1];
    self.print.frame = disc;
    self.printedText = nil;
    [self nowPlayingChanged];
    self.sheen.frame = disc;
    self.sheen.type = kCAGradientLayerConic;
    self.sheen.startPoint = CGPointMake(.5, .5); self.sheen.endPoint = CGPointMake(.5, 1);
    // Brushed-silver anisotropy: alternating light and shade sectors, no hue.
    NSArray *metal = @[@[@1, @.42], @[@.35, @.16], @[@1, @.3], @[@.5, @.1], @[@1, @.46], @[@.3, @.18], @[@1, @.28], @[@.55, @.1], @[@1, @.42]];
    NSMutableArray *sheenColors = [NSMutableArray new];
    for (NSArray *m in metal) [sheenColors addObject:(id)[NSColor colorWithWhite:[m[0] doubleValue] alpha:[m[1] doubleValue]].CGColor];
    self.sheen.colors = sheenColors;
    self.sheen.mask = CDAnnulusMask(disc, D * .492, D * .172);
    self.highlight.transform = CATransform3DIdentity;
    self.highlight.bounds = disc; self.highlight.position = c;
    self.highlight.type = kCAGradientLayerConic;
    self.highlight.startPoint = CGPointMake(.5, .5); self.highlight.endPoint = CGPointMake(.5, 1);
    CGColorRef clear = [NSColor colorWithWhite:1 alpha:0].CGColor;
    self.highlight.colors = @[(__bridge id)clear, (id)[NSColor colorWithWhite:1 alpha:.7].CGColor, (__bridge id)clear, (__bridge id)clear, (id)[NSColor colorWithWhite:1 alpha:.5].CGColor, (__bridge id)clear, (__bridge id)clear];
    self.highlight.locations = @[@0, @.07, @.15, @.5, @.57, @.65, @1];
    self.highlight.transform = CATransform3DMakeRotation(-.7, 0, 0, 1);
    self.highlight.mask = CDAnnulusMask(disc, D * .492, D * .172);
    CGPathRef hub = CDAnnulusPath(c, D * .168, D * .0375);
    self.hub.frame = disc; self.hub.path = hub; CGPathRelease(hub);
    self.hub.fillRule = kCAFillRuleEvenOdd;
    self.rim.frame = disc; self.rim.path = circle;
    self.rim.fillColor = NULL; self.rim.lineWidth = 1;
    CAShapeLayer *mask = CDAnnulusMask(disc, D / 2, D * .0375);
    self.discHost.mask = mask;
    CGPathRelease(circle);
    // Case
    self.caseHost.frame = CGRectMake(NSMinX(r), NSMinY(r), W, H);
    CGRect box = CGRectMake(0, 0, W, H);
    CGPathRef rounded = CGPathCreateWithRoundedRect(box, radius, radius, NULL);
    self.caseHost.shadowPath = rounded;
    self.caseHost.shadowColor = NSColor.blackColor.CGColor;
    self.caseHost.shadowRadius = H * .05; self.caseHost.shadowOffset = CGSizeMake(0, -H * .022);
    self.caseBack.frame = box; self.caseBack.cornerRadius = radius;
    CGFloat hinge = W * .078;
    self.insert.frame = CGRectMake(hinge + W * .006, H * .022, W - hinge - W * .026, H * .956);
    self.hinge.frame = CGRectMake(0, 0, hinge, H);
    self.hinge.startPoint = CGPointMake(0, .5); self.hinge.endPoint = CGPointMake(1, .5);
    CGMutablePathRef ridges = CGPathCreateMutable();
    for (int i = 1; i <= 3; i++) { CGFloat x = hinge * (.25 * i); CGPathMoveToPoint(ridges, NULL, x, H * .03); CGPathAddLineToPoint(ridges, NULL, x, H * .97); }
    self.ridges.frame = box; self.ridges.path = ridges; CGPathRelease(ridges);
    self.ridges.lineWidth = 1;
    self.plastic.frame = box; self.plastic.cornerRadius = radius; self.plastic.masksToBounds = YES;
    self.plastic.startPoint = CGPointMake(0, 1); self.plastic.endPoint = CGPointMake(1, 0);
    self.plastic.colors = @[(id)[NSColor colorWithWhite:1 alpha:.24].CGColor, (id)[NSColor colorWithWhite:1 alpha:.06].CGColor, (__bridge id)clear, (id)[NSColor colorWithWhite:1 alpha:.08].CGColor];
    self.plastic.locations = @[@0, @.22, @.55, @1];
    self.glare.frame = box;
    self.glare.startPoint = CGPointMake(.1, 1); self.glare.endPoint = CGPointMake(.9, 0);
    self.glare.colors = @[(__bridge id)clear, (__bridge id)clear, (id)[NSColor colorWithWhite:1 alpha:.2].CGColor, (__bridge id)clear, (__bridge id)clear];
    self.glare.locations = @[@0, @.52, @.56, @.62, @1];
    self.edge.frame = box;
    CGPathRef inner = CGPathCreateWithRoundedRect(CGRectInset(box, .75, .75), radius, radius, NULL);
    self.edge.path = inner; CGPathRelease(inner);
    self.edge.fillColor = NULL; self.edge.lineWidth = 1.5;
    self.edge.strokeColor = [NSColor colorWithWhite:1 alpha:.5].CGColor;
    CGPathRelease(rounded);
    [self paletteChanged];
    [self coverChanged];
}
- (void)paletteChanged {
    if (!self.palette) return;
    BOOL light = self.palette.light;
    self.discShadow.shadowOpacity = light ? .22 : .5;
    self.caseHost.shadowOpacity = light ? .22 : .55;
    self.caseBack.backgroundColor = (light ? CDHex(0xD9DCE1) : [NSColor colorWithWhite:.06 alpha:.92]).CGColor;
    self.hinge.colors = light ? @[(id)[NSColor colorWithWhite:.72 alpha:.92].CGColor, (id)[NSColor colorWithWhite:.93 alpha:.8].CGColor, (id)[NSColor colorWithWhite:.78 alpha:.92].CGColor]
                              : @[(id)[NSColor colorWithWhite:.05 alpha:.9].CGColor, (id)[NSColor colorWithWhite:.25 alpha:.75].CGColor, (id)[NSColor colorWithWhite:.08 alpha:.9].CGColor];
    self.ridges.strokeColor = [NSColor colorWithWhite:light ? 1 : 1 alpha:light ? .55 : .12].CGColor;
    self.hub.fillColor = [NSColor colorWithWhite:light ? .9 : .75 alpha:.28].CGColor;
    self.hub.strokeColor = [NSColor colorWithWhite:1 alpha:.45].CGColor; self.hub.lineWidth = 1;
    self.rim.strokeColor = [NSColor colorWithWhite:.35 alpha:.45].CGColor;
}
- (void)coverChanged {
    if (!self.palette) return;
    CDSetContents(self.insert, (__bridge id)CDCGImage(self.displayCover), .7);
}
- (void)nowPlayingChanged {
    NSString *text = self.np.hasSession ? [NSString stringWithFormat:@"%@  ·  %@  ·  %ld TRACKS  ·  ", self.np.album.length ? self.np.album : @"AUDIO CD", self.np.artist.length ? self.np.artist : @"CD NOOK", (long)self.np.count] : @"CD NOOK  ·  COMPACT  ·  DIGITAL  ·  ";
    if ([text isEqualToString:self.printedText] || NSWidth(self.discHost.bounds) < 2) return;
    self.printedText = text;
    CGFloat D = NSWidth(self.discHost.bounds);
    CGImageRef image = CDRenderImage(CGSizeMake(D, D), CDBackingScale(self), ^(CGContextRef ctx, CGSize size) {
        CGPoint c = CGPointMake(size.width / 2, size.height / 2);
        CGContextSetLineWidth(ctx, .6);
        for (CGFloat rr = D * .18; rr < D * .49; rr += D * .0045) {
            CGFloat a = fmod(rr * 7.3, 1) * .05 + .015;
            CGContextSetStrokeColorWithColor(ctx, [NSColor colorWithWhite:.2 alpha:a].CGColor);
            CGContextStrokeEllipseInRect(ctx, CGRectMake(c.x - rr, c.y - rr, rr * 2, rr * 2));
        }
        CGContextSetStrokeColorWithColor(ctx, [NSColor colorWithWhite:.25 alpha:.25].CGColor);
        CGContextSetLineWidth(ctx, 1);
        for (NSNumber *f in @[@.172, @.178, @.44]) { CGFloat rr = D * f.doubleValue; CGContextStrokeEllipseInRect(ctx, CGRectMake(c.x - rr, c.y - rr, rr * 2, rr * 2)); }
        // Text engraved along the inner mirror band, laid out clockwise from the top.
        NSFont *font = [NSFont systemFontOfSize:D * .021 weight:NSFontWeightMedium];
        NSDictionary *attrs = @{NSFontAttributeName: font, NSForegroundColorAttributeName: [NSColor colorWithWhite:.22 alpha:.6], NSKernAttributeName: @(D * .003)};
        CGFloat radius = D * .196, angle = M_PI_2;
        NSString *full = text;
        CGFloat circumference = 2 * M_PI * radius, used = 0;
        for (NSUInteger i = 0; i < full.length && used < circumference * .96; ) {
            NSRange range = [full rangeOfComposedCharacterSequenceAtIndex:i];
            NSString *ch = [full substringWithRange:range];
            i = NSMaxRange(range);
            CGFloat w = [ch sizeWithAttributes:attrs].width + D * .003;
            CGFloat mid = angle - (w / 2) / radius;
            CGContextSaveGState(ctx);
            CGContextTranslateCTM(ctx, c.x + radius * cos(mid), c.y + radius * sin(mid));
            CGContextRotateCTM(ctx, mid - M_PI_2);
            [ch drawAtPoint:NSMakePoint(-w / 2, 0) withAttributes:attrs];
            CGContextRestoreGState(ctx);
            angle -= w / radius; used += w;
        }
        NSDictionary *tiny = @{NSFontAttributeName: [NSFont monospacedSystemFontOfSize:D * .014 weight:NSFontWeightRegular], NSForegroundColorAttributeName: [NSColor colorWithWhite:.3 alpha:.5]};
        [@"CDG-0601  1A1" drawAtPoint:NSMakePoint(c.x + D * .05, c.y - D * .12) withAttributes:tiny];
    });
    self.print.contents = (__bridge id)image;
    CGImageRelease(image);
}
- (void)step:(CFTimeInterval)dt {
    double targetOmega = self.np.playing ? 2 * M_PI * .42 : 0;
    self.omega = CDApproach(self.omega, targetOmega, self.np.playing ? 1.6 : .9, dt);
    self.angle = fmod(self.angle + self.omega * dt, 2 * M_PI);
    double targetSlide = self.np.hasSession ? 1 : .55;
    double slide = CDApproach(self.slide, targetSlide, 2.4, dt);
    BOOL moved = fabs(slide - self.slide) > .0005;
    self.slide = slide;
    if (self.omega < .0005 && !moved) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.rotor.transform = CATransform3DMakeRotation(-self.angle, 0, 0, 1);
    if (moved) { self.discHost.position = [self discCenterForSlide:slide]; self.discShadow.position = self.discHost.position; }
    [CATransaction commit];
}
@end

#pragma mark - Cassette

// All cassette geometry is in millimetres of a real Compact Cassette (100 × 63.8), y measured from the bottom edge.
static const CGFloat CDCassetteW = 100, CDCassetteH = 63.8;
static const CGFloat CDHubY = 38.5, CDHubLX = 28.7, CDHubRX = 71.3, CDHoleR = 12.2, CDHubR = 10.6, CDPackMin = 11.3, CDPackMax = 22.5;
static const CGFloat CDRollerX = 10.8, CDRollerY = 6.4, CDRollerR = 1.9, CDPinX = 17.6, CDTapeY = 2.0;

#pragma mark Materials

/// Deterministic noise tiles, made once: fine grain for moulded plastic, and a fibrous tile for paper.
CGImageRef CDGrainTile(void) {
    static CGImageRef tile;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const int n = 128;
        uint8_t *px = malloc(n * n);
        uint32_t seed = 0x9E3779B9u;
        for (int i = 0; i < n * n; i++) { seed = seed * 1664525u + 1013904223u; px[i] = (uint8_t)(96 + ((seed >> 24) & 63)); }
        CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
        CGContextRef ctx = CGBitmapContextCreate(px, n, n, 8, n, gray, (CGBitmapInfo)kCGImageAlphaNone);
        tile = CGBitmapContextCreateImage(ctx);
        CGContextRelease(ctx); CGColorSpaceRelease(gray); free(px);
    });
    return tile;
}

static CGImageRef CDPaperTile(void) {
    static CGImageRef tile;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const int n = 256;
        CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
        CGContextRef ctx = CGBitmapContextCreate(NULL, n, n, 8, n, gray, (CGBitmapInfo)kCGImageAlphaNone);
        CGColorSpaceRelease(gray);
        CGContextSetGrayFillColor(ctx, 1, 1);
        CGContextFillRect(ctx, CGRectMake(0, 0, n, n));
        __block uint32_t seed = 0x2545F491u;
        float (^rnd)(void) = ^float { seed = seed * 1664525u + 1013904223u; return (seed >> 8) / 16777216.f; };
        // Soft mottling, then short fibres.
        for (int i = 0; i < 900; i++) {
            CGFloat x = rnd() * n, y = rnd() * n, r = 2 + rnd() * 6;
            CGContextSetGrayFillColor(ctx, .9 + rnd() * .1, .08);
            CGContextFillEllipseInRect(ctx, CGRectMake(x - r, y - r, r * 2, r * 2));
        }
        CGContextSetLineCap(ctx, kCGLineCapRound);
        for (int i = 0; i < 260; i++) {
            CGFloat x = rnd() * n, y = rnd() * n, a = rnd() * M_PI * 2, len = 4 + rnd() * 14;
            CGContextSetGrayStrokeColor(ctx, .55 + rnd() * .3, .18 + rnd() * .2);
            CGContextSetLineWidth(ctx, .4 + rnd() * .5);
            CGContextMoveToPoint(ctx, x, y);
            CGContextAddQuadCurveToPoint(ctx, x + cos(a + .6) * len * .5, y + sin(a + .6) * len * .5, x + cos(a) * len, y + sin(a) * len);
            CGContextStrokePath(ctx);
        }
        tile = CGBitmapContextCreateImage(ctx);
        CGContextRelease(ctx);
    });
    return tile;
}

void CDDrawTile(CGContextRef ctx, CGImageRef tile, CGRect rect, CGFloat scale, CGFloat alpha, CGBlendMode mode) {
    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, rect);
    CGContextSetAlpha(ctx, alpha);
    CGContextSetBlendMode(ctx, mode);
    CGContextDrawTiledImage(ctx, CGRectMake(0, 0, CGImageGetWidth(tile) / scale, CGImageGetHeight(tile) / scale), tile);
    CGContextRestoreGState(ctx);
}

/// Inner shadow (or inner light) along the inside of `path`: light from above casts it along the top edge when
/// `dy` is negative, along the bottom edge when positive.
void CDInnerShadow(CGContextRef ctx, CGPathRef path, CGFloat dy, CGFloat blur, NSColor *color) {
    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, path);
    CGContextClip(ctx);
    CGContextSetShadowWithColor(ctx, CGSizeMake(0, dy), blur, color.CGColor);
    // Everything outside the path casts the shadow inward (built in a layer, so overlapping sub-paths are fine).
    CGContextBeginTransparencyLayer(ctx, NULL);
    CGContextSetFillColorWithColor(ctx, [color colorWithAlphaComponent:1].CGColor);
    CGContextFillRect(ctx, CGRectInset(CGPathGetBoundingBox(path), -blur * 4 - fabs(dy) * 2, -blur * 4 - fabs(dy) * 2));
    CGContextSetBlendMode(ctx, kCGBlendModeClear);
    CGContextAddPath(ctx, path);
    CGContextFillPath(ctx);
    CGContextEndTransparencyLayer(ctx);
    CGContextRestoreGState(ctx);
}

/// Large, soft blotches for the slight unevenness of real moulded plastic (drawn scaled up, so it stays smooth).
CGImageRef CDMottleTile(void) {
    static CGImageRef tile;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const int n = 24;
        uint8_t px[24 * 24];
        uint32_t seed = 0x51ED270Bu;
        for (int i = 0; i < n * n; i++) { seed = seed * 1664525u + 1013904223u; px[i] = (uint8_t)(112 + ((seed >> 24) & 31)); }
        CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
        CGContextRef ctx = CGBitmapContextCreate(px, n, n, 8, n, gray, (CGBitmapInfo)kCGImageAlphaNone);
        tile = CGBitmapContextCreateImage(ctx);
        CGContextRelease(ctx); CGColorSpaceRelease(gray);
    });
    return tile;
}

/// Fills `path` as a soft, blurred shape — used for reflections of the light source.
/// (Quartz shadow sizes are in device pixels, hence `scale`.)
void CDSoftFill(CGContextRef ctx, CGPathRef path, CGFloat blur, NSColor *color, CGFloat scale) {
    CGContextSaveGState(ctx);
    const CGFloat away = 30000;
    CGAffineTransform off = CGAffineTransformMakeTranslation(-away, 0);
    CGPathRef moved = CGPathCreateCopyByTransformingPath(path, &off);
    CGContextSetShadowWithColor(ctx, CGSizeMake(away * scale, 0), blur * scale, color.CGColor);
    CGContextAddPath(ctx, moved);
    CGContextSetFillColorWithColor(ctx, NSColor.blackColor.CGColor);
    CGContextFillPath(ctx);
    CGPathRelease(moved);
    CGContextRestoreGState(ctx);
}

/// Faint hairline scratches from handling: short, mostly horizontal arcs that catch the light.
static void CDDrawScratches(CGContextRef ctx, CGRect area, CGFloat k, uint32_t seed, int count, CGFloat alpha) {
    __block uint32_t state = seed | 1;
    CGFloat (^rnd)(void) = ^CGFloat { state = state * 1664525u + 1013904223u; return (state >> 8) / 16777216.0; };
    CGContextSaveGState(ctx);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    for (int i = 0; i < count; i++) {
        CGFloat x = area.origin.x + rnd() * area.size.width, y = area.origin.y + rnd() * area.size.height;
        CGFloat len = (1 + rnd() * 3.5) * k, ang = (rnd() - .5) * .9 + (rnd() < .3 ? M_PI / 4 : 0), bend = (rnd() - .5) * .3 * k;
        BOOL glint = rnd() < .75;
        CGContextSetStrokeColorWithColor(ctx, [NSColor colorWithWhite:glint ? 1 : 0 alpha:alpha * (.35 + rnd() * .65) * (glint ? 1 : .5)].CGColor);
        CGContextSetLineWidth(ctx, MAX(.35, (.05 + rnd() * .06) * k));
        CGPoint a = CGPointMake(x, y), b = CGPointMake(x + cos(ang) * len, y + sin(ang) * len);
        CGContextMoveToPoint(ctx, a.x, a.y);
        CGContextAddQuadCurveToPoint(ctx, (a.x + b.x) / 2 - sin(ang) * bend, (a.y + b.y) / 2 + cos(ang) * bend, b.x, b.y);
        CGContextStrokePath(ctx);
    }
    CGContextRestoreGState(ctx);
}

/// A thin clear film over printed art (like the wrap or laminate on a new tape): a fine orange-peel surface,
/// a broad sheen, a few soft wrinkles with crisp glints where they catch the light, and specks of sparkle.
/// Draw inside a clip of the art's shape.
static void CDDrawFilm(CGContextRef ctx, CGRect area, CGFloat k, CGFloat scale, uint32_t seed, BOOL dark) {
    __block uint32_t state = seed | 1;
    CGFloat (^rnd)(void) = ^CGFloat { state = state * 1664525u + 1013904223u; return (state >> 8) / 16777216.0; };
    CDDrawTile(ctx, CDGrainTile(), area, scale, .09, kCGBlendModeSoftLight);
    NSGradient *sheen = [[NSGradient alloc] initWithColors:@[[NSColor colorWithWhite:1 alpha:0], [NSColor colorWithWhite:1 alpha:dark ? .09 : .13], [NSColor colorWithWhite:1 alpha:.03], [NSColor colorWithWhite:1 alpha:0], [NSColor colorWithWhite:1 alpha:dark ? .04 : .06], [NSColor colorWithWhite:1 alpha:0]] atLocations:(CGFloat[]){.12, .27, .36, .5, .7, .8} colorSpace:NSColorSpace.sRGBColorSpace];
    [sheen drawInRect:area angle:-28];
    CGContextSaveGState(ctx);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGFloat W = area.size.width, H = area.size.height;
    for (int i = 0; i < 6; i++) {
        // A wrinkle: a long gentle curve, mostly diagonal.
        CGFloat x0 = area.origin.x + (rnd() * 1.2 - .1) * W, y0 = area.origin.y + (rnd() < .5 ? H * (1.05 - rnd() * .2) : H * rnd());
        CGFloat ang = -.35 - rnd() * .8, len = (18 + rnd() * 30) * k, bend = (rnd() - .5) * 8 * k;
        CGPoint a = CGPointMake(x0, y0), b = CGPointMake(x0 + cos(ang) * len, y0 + sin(ang) * len);
        CGPoint c = CGPointMake((a.x + b.x) / 2 - sin(ang) * bend, (a.y + b.y) / 2 + cos(ang) * bend);
        CGMutablePathRef crease = CGPathCreateMutable();
        CGPathMoveToPoint(crease, NULL, a.x, a.y); CGPathAddQuadCurveToPoint(crease, NULL, c.x, c.y, b.x, b.y);
        CGContextSetStrokeColorWithColor(ctx, [NSColor colorWithWhite:1 alpha:.05].CGColor);
        CGContextSetLineWidth(ctx, 1.6 * k);
        CGContextAddPath(ctx, crease); CGContextStrokePath(ctx);
        CGContextSaveGState(ctx);
        CGContextTranslateCTM(ctx, sin(ang) * .55 * k, -cos(ang) * .55 * k);
        CGContextSetStrokeColorWithColor(ctx, [NSColor colorWithWhite:0 alpha:.035].CGColor);
        CGContextSetLineWidth(ctx, 1.1 * k);
        CGContextAddPath(ctx, crease); CGContextStrokePath(ctx);
        CGContextRestoreGState(ctx);
        // The crisp glint along part of the crease.
        CGFloat t0 = rnd() * .6, t1 = t0 + .08 + rnd() * .14;
        CGContextSaveGState(ctx);
        CGContextSetShadowWithColor(ctx, CGSizeZero, .6 * k * scale, [NSColor colorWithWhite:1 alpha:.5].CGColor);
        CGContextSetStrokeColorWithColor(ctx, [NSColor colorWithWhite:1 alpha:dark ? .16 : .22].CGColor);
        CGContextSetLineWidth(ctx, MAX(.4, .1 * k));
        for (int j = 0; j <= 12; j++) {
            CGFloat t = t0 + (t1 - t0) * j / 12.0, u = 1 - t;
            CGPoint q = CGPointMake(u * u * a.x + 2 * u * t * c.x + t * t * b.x, u * u * a.y + 2 * u * t * c.y + t * t * b.y);
            if (j == 0) CGContextMoveToPoint(ctx, q.x, q.y); else CGContextAddLineToPoint(ctx, q.x, q.y);
        }
        CGContextStrokePath(ctx);
        CGContextRestoreGState(ctx);
        CGPathRelease(crease);
    }
    for (int i = 0; i < 26; i++) {
        CGFloat r = (.08 + rnd() * .12) * k;
        CGContextSetFillColorWithColor(ctx, [NSColor colorWithWhite:1 alpha:.18 + rnd() * .3].CGColor);
        CGContextFillEllipseInRect(ctx, CGRectMake(area.origin.x + rnd() * W - r, area.origin.y + rnd() * H - r, r * 2, r * 2));
    }
    CGContextRestoreGState(ctx);
}

/// Cover art cropped to fill `dest`, placing `focus` (0…1 of the cover, y from the top) as near to `anchor`
/// (0…1 of `dest`, y from the top) as the crop allows — so faces land where the label is not punched out.
static void CDDrawCoverCrop(CGContextRef ctx, CGImageRef cover, CGRect dest, CGPoint focus, CGPoint anchor) {
    CGFloat W = CGImageGetWidth(cover), H = CGImageGetHeight(cover), aspect = dest.size.width / MAX(1, dest.size.height);
    CGRect crop;
    if (W / H > aspect) { CGFloat w = H * aspect; crop = CGRectMake(MAX(0, MIN(W - w, focus.x * W - w * anchor.x)), 0, w, H); }
    else { CGFloat h = W / aspect; crop = CGRectMake(0, MAX(0, MIN(H - h, focus.y * H - h * anchor.y)), W, h); }
    CGImageRef part = CGImageCreateWithImageInRect(cover, CGRectIntegral(crop));
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextDrawImage(ctx, dest, part ?: cover);
    if (part) CGImageRelease(part);
}

static CGPoint CDSubjectFocus(CGImageRef mask) {
    const int n = 64;
    uint8_t *px = calloc(n * n, 1);
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGContextRef ctx = CGBitmapContextCreate(px, n, n, 8, n, gray, (CGBitmapInfo)kCGImageAlphaNone);
    CGColorSpaceRelease(gray);
    CGContextDrawImage(ctx, CGRectMake(0, 0, n, n), mask);
    CGContextRelease(ctx);
    int top = n, bottom = -1; double sx = 0, count = 0;
    for (int y = 0; y < n; y++) for (int x = 0; x < n; x++) if (px[y * n + x] > 127) { top = MIN(top, y); bottom = MAX(bottom, y); sx += x; count++; }
    free(px);
    if (count < n * n * .02) return CGPointMake(.5, .42);
    // Bitmap rows run top to bottom here (CGBitmapContext memory starts at the top row).
    return CGPointMake((sx / count + .5) / n, (top + (bottom - top) * .16 + .5) / n);
}

/// A strip of masking tape with a handwritten title: slightly rotated, torn ends, a soft shadow.
static void CDDrawTitleTape(CGContextRef ctx, NSString *title, CGPoint center, CGFloat maxWidth, CGFloat k, CGFloat scale) {
    NSAttributedString *text = [[NSAttributedString alloc] initWithString:title attributes:CDTextAttributes(CDLabelFont(3.7 * k), [CDHex(0x22346B) colorWithAlphaComponent:.92], 0, NSTextAlignmentCenter)];
    CGFloat w = MIN(maxWidth, text.size.width + 11 * k), h = 5.8 * k;
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, center.x, center.y);
    CGContextRotateCTM(ctx, -1.1 * M_PI / 180);
    CGMutablePathRef strip = CGPathCreateMutable();
    __block uint32_t seed = (uint32_t)title.hash | 1;
    CGFloat (^jag)(void) = ^CGFloat { seed = seed * 1664525u + 1013904223u; return ((seed >> 16) & 255) / 255.0 * .7 * k; };
    CGPathMoveToPoint(strip, NULL, -w / 2, -h / 2);
    CGPathAddLineToPoint(strip, NULL, w / 2, -h / 2);
    for (int i = 1; i <= 6; i++) CGPathAddLineToPoint(strip, NULL, w / 2 + (i % 2 ? jag() : -jag() * .4), -h / 2 + h * i / 6);
    CGPathAddLineToPoint(strip, NULL, -w / 2, h / 2);
    for (int i = 5; i >= 0; i--) CGPathAddLineToPoint(strip, NULL, -w / 2 - (i % 2 ? jag() : -jag() * .4), -h / 2 + h * i / 6);
    CGPathCloseSubpath(strip);
    CGContextSaveGState(ctx);
    CGContextSetShadowWithColor(ctx, CGSizeMake(0, -.35 * k), 1.1 * k, [NSColor colorWithWhite:0 alpha:.22].CGColor);
    CGContextAddPath(ctx, strip);
    CGContextSetFillColorWithColor(ctx, [CDHex(0xF3ECD8) colorWithAlphaComponent:.95].CGColor);
    CGContextFillPath(ctx);
    CGContextRestoreGState(ctx);
    CGContextAddPath(ctx, strip);
    CGContextClip(ctx);
    CDDrawTile(ctx, CDPaperTile(), CGRectMake(-w, -h, w * 2, h * 2), scale, .5, kCGBlendModeMultiply);
    // Faint crepe lines along the tape.
    CGContextSetStrokeColorWithColor(ctx, [NSColor colorWithWhite:0 alpha:.035].CGColor);
    CGContextSetLineWidth(ctx, .5);
    for (CGFloat x = -w / 2; x < w / 2; x += .9 * k) { CGContextMoveToPoint(ctx, x, -h / 2); CGContextAddLineToPoint(ctx, x + .3 * k, h / 2); }
    CGContextStrokePath(ctx);
    [text drawWithRect:CGRectMake(-w / 2 + 3 * k, -text.size.height / 2 + .3 * k, w - 6 * k, text.size.height) options:NSStringDrawingTruncatesLastVisibleLine | NSStringDrawingUsesLineFragmentOrigin];
    CGPathRelease(strip);
    CGContextRestoreGState(ctx);
}

/// The printed "A" side mark: a paper disc with a pen letter.
static void CDDrawSideMark(CGContextRef ctx, CGPoint c, CGFloat k, BOOL disc) {
    CGRect r = CGRectMake(c.x - 3.3 * k, c.y - 3.3 * k, 6.6 * k, 6.6 * k);
    NSColor *pen = [CDHex(0x22346B) colorWithAlphaComponent:.85];
    if (disc) {
        CGContextSaveGState(ctx);
        CGContextSetShadowWithColor(ctx, CGSizeMake(0, -.25 * k), .8 * k, [NSColor colorWithWhite:0 alpha:.25].CGColor);
        CGContextSetFillColorWithColor(ctx, CDHex(0xFBF8F0).CGColor);
        CGContextFillEllipseInRect(ctx, r);
        CGContextRestoreGState(ctx);
    }
    CGContextSetStrokeColorWithColor(ctx, [pen colorWithAlphaComponent:.55].CGColor);
    CGContextSetLineWidth(ctx, MAX(1, .28 * k));
    CGContextStrokeEllipseInRect(ctx, CGRectInset(r, .6 * k, .6 * k));
    NSAttributedString *letter = [[NSAttributedString alloc] initWithString:@"A" attributes:CDTextAttributes(CDRoundedFont(3.9 * k, NSFontWeightBold), pen, 0, NSTextAlignmentCenter)];
    CGFloat lh = letter.size.height;
    [letter drawInRect:CGRectMake(r.origin.x, CGRectGetMidY(r) - lh / 2, r.size.width, lh)];
}

@interface CDCassetteHero ()
@property (nonatomic, strong) CALayer *contact, *shellHost, *interior, *reelHost, *reelLight, *skin, *label, *glass, *leftPack, *rightPack, *leftHub, *rightHub;
@property (nonatomic, strong) CAShapeLayer *tapeRun;
@property (nonatomic) double leftAngle, rightAngle, speed, wound;
@property (nonatomic, copy) NSString *skinKey, *labelKey;
@property (nonatomic) CGPoint artFocus;
@property (nonatomic) NSUInteger focusToken;
@property (nonatomic) BOOL rebuilding;
@property (nonatomic) NSPoint downPoint;
@property (nonatomic) BOOL pressedOnCassette;
@end

@implementation CDCassetteHero
- (CGFloat)aspect { return CDCassetteW / CDCassetteH; }
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _artFocus = CGPointMake(.5, .42);
        self.contact = [CALayer layer];
        self.shellHost = [CALayer layer];
        self.interior = [CALayer layer];
        self.reelLight = [CALayer layer];
        self.reelHost = [CALayer layer];
        self.skin = [CALayer layer];
        self.label = [CALayer layer];
        self.glass = [CALayer layer];
        self.leftPack = [CALayer layer]; self.rightPack = [CALayer layer];
        self.leftHub = [CALayer layer]; self.rightHub = [CALayer layer];
        self.tapeRun = [CAShapeLayer layer];
        [self.shellHost addSublayer:self.interior];
        for (CALayer *l in @[self.tapeRun, self.leftPack, self.rightPack, self.leftHub, self.rightHub, self.reelLight]) [self.reelHost addSublayer:l];
        for (CALayer *l in @[self.contact, self.shellHost, self.reelHost, self.skin, self.label, self.glass]) [self.layer addSublayer:l];
        for (CALayer *pack in @[self.leftPack, self.rightPack]) { pack.masksToBounds = YES; pack.contentsGravity = kCAGravityCenter; }
        for (CALayer *hub in @[self.leftHub, self.rightHub]) {
            hub.shadowColor = NSColor.blackColor.CGColor; hub.shadowOpacity = .5; hub.shadowOffset = CGSizeZero;
        }
        self.tapeRun.fillColor = NULL;
        self.tapeRun.strokeColor = CDHex(0x3A2A20).CGColor;
    }
    return self;
}
- (void)setLook:(CDCassetteLook)look { if (_look == look) return; _look = look; self.skinKey = nil; self.labelKey = nil; [self rebuild]; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (void)resetCursorRects {
    [super resetCursorRects];
    [self addCursorRect:self.objectRect cursor:NSCursor.pointingHandCursor];
}
- (void)mouseDown:(NSEvent *)event {
    self.downPoint = [self convertPoint:event.locationInWindow fromView:nil];
    self.pressedOnCassette = NSPointInRect(self.downPoint, self.objectRect);
}
- (void)mouseUp:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    BOOL clicked = self.pressedOnCassette && NSPointInRect(point, self.objectRect)
        && hypot(point.x - self.downPoint.x, point.y - self.downPoint.y) <= 6;
    self.pressedOnCassette = NO;
    if (clicked && self.onCycleLook) self.onCycleLook();
}
- (CGFloat)k { return NSHeight(self.objectRect) / CDCassetteH; }
/// Millimetres → points in the cassette's own box (origin at its bottom-left corner).
- (CGPoint)at:(CGFloat)x :(CGFloat)y { CGFloat k = self.k; return CGPointMake(x * k, y * k); }
- (CGRect)box:(CGFloat)x :(CGFloat)y :(CGFloat)w :(CGFloat)h { CGFloat k = self.k; return CGRectMake(x * k, y * k, w * k, h * k); }
- (CGPathRef)shellPath CF_RETURNS_RETAINED { CGFloat k = self.k; return CGPathCreateWithRoundedRect([self box:0 :0 :CDCassetteW :CDCassetteH], 3.2 * k, 3.2 * k, NULL); }
/// The two reel holes and the window between them, as one outline (so it can be stroked and shaded cleanly).
- (CGPathRef)windowPath CF_RETURNS_RETAINED {
    CGFloat k = self.k;
    CGPoint l = [self at:CDHubLX :CDHubY], r = [self at:CDHubRX :CDHubY];
    CGPathRef left = CGPathCreateWithEllipseInRect(CGRectMake(l.x - CDHoleR * k, l.y - CDHoleR * k, CDHoleR * 2 * k, CDHoleR * 2 * k), NULL);
    CGPathRef right = CGPathCreateWithEllipseInRect(CGRectMake(r.x - CDHoleR * k, r.y - CDHoleR * k, CDHoleR * 2 * k, CDHoleR * 2 * k), NULL);
    CGPathRef middle = CGPathCreateWithRoundedRect([self box:CDHubLX :CDHubY - 6 :CDHubRX - CDHubLX :12], 1.2 * k, 1.2 * k, NULL);
    CGPathRef pair = CGPathCreateCopyByUnioningPath(left, right, false);
    CGPathRef window = CGPathCreateCopyByUnioningPath(pair, middle, false);
    CGPathRelease(left); CGPathRelease(right); CGPathRelease(middle); CGPathRelease(pair);
    return window;
}
- (CGPathRef)headPath CF_RETURNS_RETAINED {
    CGMutablePathRef head = CGPathCreateMutable();
    CGPoint a = [self at:16.5 :-.5], b = [self at:20.5 :12.2], c = [self at:79.5 :12.2], d = [self at:83.5 :-.5];
    CGPathMoveToPoint(head, NULL, a.x, a.y); CGPathAddLineToPoint(head, NULL, b.x, b.y); CGPathAddLineToPoint(head, NULL, c.x, c.y); CGPathAddLineToPoint(head, NULL, d.x, d.y); CGPathCloseSubpath(head);
    return head;
}
- (CGPathRef)openingsPath CF_RETURNS_RETAINED {
    CGMutablePathRef openings = CGPathCreateMutable();
    CGFloat k = self.k;
    for (NSNumber *x in @[@27.3, @72.7]) { CGPoint o = [self at:x.doubleValue :5.2]; CGPathAddEllipseInRect(openings, NULL, CGRectMake(o.x - 1.7 * k, o.y - 1.7 * k, 3.4 * k, 3.4 * k)); }
    for (NSNumber *x in @[@35.2, @61.6]) CGPathAddRoundedRect(openings, NULL, [self box:x.doubleValue :3.2 :3.2 :3.6], .4 * k, .4 * k);
    CGPathAddRoundedRect(openings, NULL, [self box:43 :.8 :14 :5.6], .6 * k, .6 * k);
    return openings;
}
- (CGRect)labelRect { return [self box:5 :20.4 :90 :40.2]; }
/// The light box whose reflection lies across the upper half of the cassette (shell, window and film alike).
- (CGPathRef)lightBoxPath CF_RETURNS_RETAINED {
    NSRect r = self.objectRect;
    CGFloat k = self.k, w = NSWidth(r), h = NSHeight(r);
    CGMutablePathRef path = CGPathCreateMutable();
    CGAffineTransform tilt = CGAffineTransformRotate(CGAffineTransformMakeTranslation(w * .5, h * .8), -.07);
    CGPathAddRoundedRect(path, &tilt, CGRectMake(-w * .38, -h * .11, w * .76, h * .22), 6 * k, 6 * k);
    return path;
}

/// The shell colour: the theme's body colour, or for the translucent shell, a muted colour taken from the cover.
- (NSColor *)shellColor {
    CDPalette *p = self.palette;
    BOOL light = p.light;
    if (self.look == CDCassetteLookTintedShell) {
        NSColor *c = p.accent;
        CGFloat best = -1;
        for (NSColor *candidate in self.coverColors) {
            NSColor *rgb = [candidate colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
            CGFloat score = rgb.saturationComponent * (.35 + rgb.brightnessComponent);
            if (score > best) { best = score; c = rgb; }
        }
        // Coloured plastic is a little more saturated than a pastel cover average.
        c = [NSColor colorWithHue:c.hueComponent saturation:MIN(1, MAX(.18, c.saturationComponent * 1.5)) brightness:c.brightnessComponent alpha:1];
        return light ? CDMix(c, NSColor.whiteColor, .18) : CDMix(c, NSColor.blackColor, .25);
    }
    return light ? CDMix(NSColor.whiteColor, p.body, .45) : CDMix(p.body, NSColor.blackColor, .5);
}

- (void)rebuild {
    NSRect r = self.objectRect;
    if (NSWidth(r) < 4 || !self.palette) return;
    self.rebuilding = YES;
    CGFloat k = self.k, scale = CDBackingScale(self);
    CGRect box = CGRectMake(0, 0, NSWidth(r), NSHeight(r));
    for (CALayer *l in @[self.contact, self.shellHost, self.reelHost, self.skin, self.label, self.glass]) l.frame = r;
    self.interior.frame = box;
    self.reelLight.frame = box;
    // Two shadows: a wide, soft one from the room light, and a tight, dark one where the cassette meets the surface.
    CGPathRef shape = [self shellPath];
    for (CALayer *l in @[self.shellHost, self.contact]) { l.shadowPath = shape; l.shadowColor = NSColor.blackColor.CGColor; }
    self.shellHost.shadowRadius = 9 * k; self.shellHost.shadowOffset = CGSizeMake(0, -4 * k);
    self.contact.shadowRadius = 1.2 * k; self.contact.shadowOffset = CGSizeMake(0, -.6 * k);
    CGPathRelease(shape);
    // Tape packs: a ring texture as large as a full pack, shown through a circle as big as the pack is now.
    CGFloat rmax = CDPackMax * k, rmin = CDPackMin * k;
    CGImageRef rings = CDRenderImage(CGSizeMake(rmax * 2, rmax * 2), scale, ^(CGContextRef ctx, CGSize s) {
        CGPoint c = CGPointMake(s.width / 2, s.height / 2);
        CGContextSetFillColorWithColor(ctx, CDHex(0x33261D).CGColor);
        CGContextFillEllipseInRect(ctx, CGRectMake(0, 0, s.width, s.height));
        uint32_t seed = 7;
        CGFloat step = MAX(.35, .11 * k);
        for (CGFloat rr = rmin * .9; rr < rmax; rr += step) {
            seed = seed * 1664525u + 1013904223u;
            CGFloat v = ((seed >> 16) & 255) / 255.0;
            CGContextSetStrokeColorWithColor(ctx, [NSColor colorWithWhite:v > .5 ? 1 : 0 alpha:.015 + fabs(v - .5) * .09].CGColor);
            CGContextSetLineWidth(ctx, step * .7);
            CGContextStrokeEllipseInRect(ctx, CGRectMake(c.x - rr, c.y - rr, rr * 2, rr * 2));
        }
        // Anisotropic sheen: a bow-tie of light across the pack, fixed while the pack turns — as on real tape.
        CGFloat stops[] = {0, .06, .14, .22, .5, .56, .64, .72, 1};
        CGFloat comps[] = {1, 1, 1, 0,  1, .93, .85, .16,  1, 1, 1, 0,  1, 1, 1, 0,  1, 1, 1, 0,  1, .93, .85, .11,  1, 1, 1, 0,  1, 1, 1, 0,  1, 1, 1, 0};
        CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGGradientRef sheen = CGGradientCreateWithColorComponents(srgb, comps, stops, 9);
        CGColorSpaceRelease(srgb);
        CGContextSaveGState(ctx);
        CGContextAddEllipseInRect(ctx, CGRectMake(0, 0, s.width, s.height));
        CGContextClip(ctx);
        CGContextSetBlendMode(ctx, kCGBlendModeScreen);
        CGContextDrawConicGradient(ctx, sheen, c, M_PI * .18);
        CGContextRestoreGState(ctx);
        CGGradientRelease(sheen);
    });
    CGFloat hr = CDHubR * k, hole = 6.2 * k;
    CGImageRef hubImage = CDRenderImage(CGSizeMake(hr * 2, hr * 2), scale, ^(CGContextRef ctx, CGSize s) {
        CGPoint c = CGPointMake(hr, hr);
        CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGFloat comps[] = {.95, .93, .89, 1,  .91, .89, .85, 1,  .80, .78, .74, 1};
        CGFloat locs[] = {0, .72, 1};
        CGGradientRef g = CGGradientCreateWithColorComponents(srgb, comps, locs, 3);
        CGColorSpaceRelease(srgb);
        CGContextSaveGState(ctx);
        CGContextAddEllipseInRect(ctx, CGRectMake(0, 0, s.width, s.height));
        CGContextClip(ctx);
        CGContextDrawRadialGradient(ctx, g, c, hole, c, hr, 0);
        CGContextRestoreGState(ctx);
        CGGradientRelease(g);
        CGContextSetStrokeColorWithColor(ctx, [NSColor colorWithWhite:0 alpha:.28].CGColor);
        CGContextSetLineWidth(ctx, .6);
        CGContextStrokeEllipseInRect(ctx, CGRectMake(.3, .3, s.width - .6, s.height - .6));
        // A moulded ring, the centre hole with its six drive teeth, and six small windows in the flange.
        CGFloat ring = (hr + hole) / 2 + 1.35 * k;
        CGContextSetStrokeColorWithColor(ctx, [NSColor colorWithWhite:0 alpha:.07].CGColor);
        CGContextStrokeEllipseInRect(ctx, CGRectMake(c.x - ring, c.y - ring, ring * 2, ring * 2));
        CGContextSetBlendMode(ctx, kCGBlendModeClear);
        CGContextFillEllipseInRect(ctx, CGRectMake(c.x - hole, c.y - hole, hole * 2, hole * 2));
        for (int i = 0; i < 6; i++) {
            CGFloat ang = i * M_PI / 3 + M_PI / 6, rr = (hr + hole) / 2;
            CGContextFillEllipseInRect(ctx, CGRectMake(c.x + rr * cos(ang) - .9 * k, c.y + rr * sin(ang) - .9 * k, 1.8 * k, 1.8 * k));
        }
        CGContextSetBlendMode(ctx, kCGBlendModeNormal);
        CGContextSetFillColorWithColor(ctx, CDHex(0xE6E2D9).CGColor);
        for (int i = 0; i < 6; i++) {
            CGContextSaveGState(ctx);
            CGContextTranslateCTM(ctx, c.x, c.y); CGContextRotateCTM(ctx, i * M_PI / 3);
            CGContextFillRect(ctx, CGRectMake(hole * .5, -hole * .14, hole * .5 + .5, hole * .28));
            CGContextRestoreGState(ctx);
        }
        CGContextSetStrokeColorWithColor(ctx, [NSColor colorWithWhite:0 alpha:.3].CGColor);
        CGContextStrokeEllipseInRect(ctx, CGRectMake(c.x - hole, c.y - hole, hole * 2, hole * 2));
    });
    for (NSNumber *side in @[@YES, @NO]) {
        BOOL left = side.boolValue;
        CGPoint hc = [self at:left ? CDHubLX : CDHubRX :CDHubY];
        CALayer *hub = left ? self.leftHub : self.rightHub, *pack = left ? self.leftPack : self.rightPack;
        hub.transform = CATransform3DIdentity;
        hub.bounds = CGRectMake(0, 0, hr * 2, hr * 2); hub.position = hc;
        hub.contents = (__bridge id)hubImage; hub.contentsScale = scale;
        CGPathRef circle = CGPathCreateWithEllipseInRect(hub.bounds, NULL);
        hub.shadowPath = circle; CGPathRelease(circle);
        hub.shadowRadius = .9 * k;
        pack.position = hc;
        pack.contents = (__bridge id)rings; pack.contentsScale = scale;
        pack.borderColor = [CDHex(0x8A6A52) colorWithAlphaComponent:.45].CGColor;
        pack.borderWidth = MAX(.6, .12 * k);
    }
    CGImageRelease(rings); CGImageRelease(hubImage);
    CGImageRef hubLight = CDRenderImage(box.size, scale, ^(CGContextRef ctx, CGSize s) {
        for (NSNumber *x in @[@(CDHubLX), @(CDHubRX)]) {
            CGPoint c = [self at:x.doubleValue :CDHubY];
            CGContextSaveGState(ctx);
            CGContextAddEllipseInRect(ctx, CGRectMake(c.x - hr, c.y - hr, hr * 2, hr * 2)); CGContextClip(ctx);
            CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            CGFloat comps[] = {1, 1, 1, .34,  1, 1, 1, 0,  0, 0, 0, 0,  0, 0, 0, .16};
            CGGradientRef g = CGGradientCreateWithColorComponents(srgb, comps, (CGFloat[]){0, .45, .6, 1}, 4);
            CGColorSpaceRelease(srgb);
            CGContextDrawLinearGradient(ctx, g, CGPointMake(c.x - hr * .7, c.y + hr * .7), CGPointMake(c.x + hr * .7, c.y - hr * .7), 0);
            CGGradientRelease(g);
            CGContextRestoreGState(ctx);
        }
    });
    self.reelLight.contents = (__bridge id)hubLight;
    CGImageRelease(hubLight);
    self.tapeRun.frame = box;
    self.tapeRun.lineWidth = MAX(.6, .32 * k);
    self.tapeRun.hidden = self.look != CDCassetteLookTintedShell;
    self.skinKey = nil; self.labelKey = nil;
    [self paletteChanged];
    [self updatePacks];
    self.rebuilding = NO;
}

- (void)paletteChanged {
    if (!self.palette || NSWidth(self.objectRect) < 4) return;
    self.shellHost.shadowOpacity = self.palette.light ? .2 : .5;
    self.contact.shadowOpacity = self.palette.light ? .28 : .6;
    [self renderSkin];
    [self nowPlayingChanged];
}

- (void)coverChanged {
    // Find where the subject is, so the label / shell print keeps the face in view. Vision runs off the main thread.
    NSUInteger token = ++self.focusToken;
    self.artFocus = CGPointMake(.5, .42);
    self.skinKey = nil; self.labelKey = nil;
    [self paletteChanged];
    CGImageRef image = CDCGImage(self.cover);
    if (!image) return;
    CGImageRetain(image);
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        CGRect face;
        CGPoint focus;
        if (CDFindFaces(image, &face)) focus = CGPointMake(CGRectGetMidX(face), face.origin.y + face.size.height * .42);
        else {
            CGImageRef mask = CDCreateSubjectMask(image);
            focus = mask ? CDSubjectFocus(mask) : CGPointMake(.5, .42);
            if (mask) CGImageRelease(mask);
        }
        CGImageRelease(image);
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || strongSelf.focusToken != token) return;
            strongSelf.artFocus = focus;
            strongSelf.skinKey = nil; strongSelf.labelKey = nil;
            [strongSelf renderSkin];
            [strongSelf nowPlayingChanged];
        });
    });
}

/// Behind the reels: the inside of the cassette — the milky slip sheet the packs run on (what you actually see
/// through a real cassette's window), the felt pressure pad and its spring behind the tape at the head, and for
/// the translucent shell, the tinted back half with its guide rollers.
- (void)renderInterior {
    CGFloat k = self.k, scale = CDBackingScale(self);
    BOOL tinted = self.look == CDCassetteLookTintedShell, light = self.palette.light;
    NSColor *back = tinted ? CDMix(self.shellColor, NSColor.blackColor, light ? .28 : .45) : CDHex(0x17181A);
    NSColor *liner = light ? CDHex(0xB4B0A8) : CDHex(0x77736C);
    CGImageRef image = CDRenderImage(self.interior.bounds.size, scale, ^(CGContextRef ctx, CGSize s) {
        CGRect all = CGRectMake(0, 0, s.width, s.height);
        CGPathRef shape = [self shellPath];
        CGContextAddPath(ctx, shape); CGContextClip(ctx); CGPathRelease(shape);
        CGContextSetFillColorWithColor(ctx, back.CGColor);
        CGContextFillRect(ctx, all);
        if (tinted) CDDrawTile(ctx, CDGrainTile(), all, scale, .1, kCGBlendModeOverlay);
        // Slip sheet: two discs joined by a band, embossed with fine rings around each hub.
        CGPoint l = [self at:CDHubLX :CDHubY], r = [self at:CDHubRX :CDHubY];
        CGFloat sr = 24 * k;
        CGMutablePathRef sheet = CGPathCreateMutable();
        CGPathAddEllipseInRect(sheet, NULL, CGRectMake(l.x - sr, l.y - sr, sr * 2, sr * 2));
        CGPathAddEllipseInRect(sheet, NULL, CGRectMake(r.x - sr, r.y - sr, sr * 2, sr * 2));
        CGPathAddRect(sheet, NULL, CGRectMake(l.x, l.y - 14 * k, r.x - l.x, 28 * k));
        CGContextSaveGState(ctx);
        CGContextAddPath(ctx, sheet); CGContextClip(ctx);
        CGContextSetAlpha(ctx, tinted ? .55 : 1);
        CGContextBeginTransparencyLayer(ctx, NULL);
        CGContextSetFillColorWithColor(ctx, liner.CGColor);
        CGContextFillRect(ctx, all);
        CDDrawTile(ctx, CDPaperTile(), all, scale, .35, kCGBlendModeMultiply);
        for (NSValue *v in @[[NSValue valueWithPoint:l], [NSValue valueWithPoint:r]]) {
            CGPoint c = v.pointValue;
            for (CGFloat rr = 12.5 * k; rr < sr; rr += 1.1 * k) {
                CGContextSetStrokeColorWithColor(ctx, [NSColor colorWithWhite:1 alpha:.16].CGColor);
                CGContextSetLineWidth(ctx, .18 * k);
                CGContextStrokeEllipseInRect(ctx, CGRectMake(c.x - rr, c.y - rr - .12 * k, rr * 2, rr * 2));
                CGContextSetStrokeColorWithColor(ctx, [NSColor colorWithWhite:0 alpha:.08].CGColor);
                CGContextStrokeEllipseInRect(ctx, CGRectMake(c.x - rr, c.y - rr + .12 * k, rr * 2, rr * 2));
            }
        }
        // Light falls off towards the edges of the window, which sits in shadow.
        NSGradient *falloff = [[NSGradient alloc] initWithColors:@[[NSColor colorWithWhite:0 alpha:0], [NSColor colorWithWhite:0 alpha:.28]]];
        [falloff drawFromCenter:CGPointMake((l.x + r.x) / 2, l.y + 4 * k) radius:8 * k toCenter:CGPointMake((l.x + r.x) / 2, l.y) radius:46 * k options:NSGradientDrawsAfterEndingLocation];
        CGContextEndTransparencyLayer(ctx);
        CGContextRestoreGState(ctx);
        CGPathRelease(sheet);
        if (tinted) {
            // Guide rollers and pins the tape runs around.
            for (NSNumber *sx in @[@(CDRollerX), @(CDCassetteW - CDRollerX)]) {
                CGPoint c = [self at:sx.doubleValue :CDRollerY];
                CGContextSetFillColorWithColor(ctx, CDHex(0xE3DFD6).CGColor);
                CGContextFillEllipseInRect(ctx, CGRectMake(c.x - CDRollerR * k, c.y - CDRollerR * k, CDRollerR * 2 * k, CDRollerR * 2 * k));
                CGContextSetFillColorWithColor(ctx, [NSColor colorWithWhite:0 alpha:.35].CGColor);
                CGContextFillEllipseInRect(ctx, CGRectMake(c.x - .55 * k, c.y - .55 * k, 1.1 * k, 1.1 * k));
            }
            for (NSNumber *sx in @[@(CDPinX), @(CDCassetteW - CDPinX)]) {
                CGPoint c = [self at:sx.doubleValue :CDTapeY + .9];
                CGContextSetFillColorWithColor(ctx, CDHex(0xB9B7B1).CGColor);
                CGContextFillEllipseInRect(ctx, CGRectMake(c.x - .8 * k, c.y - .8 * k, 1.6 * k, 1.6 * k));
            }
        }
        // Behind the head openings: deep shadow, the felt pressure pad on its leaf spring, and the tape in front.
        CGRect head = [self box:14 :0 :72 :7.2];
        NSGradient *deep = [[NSGradient alloc] initWithColors:@[[NSColor colorWithWhite:0 alpha:.55], [NSColor colorWithWhite:0 alpha:.15]]];
        [deep drawInRect:head angle:-90];
        CGContextSetFillColorWithColor(ctx, CDHex(0x9C9A95).CGColor);
        CGContextFillRect(ctx, [self box:44.6 :5.1 :10.8 :.55]);
        CGRect pad = [self box:46.4 :2.4 :7.2 :2.7];
        CGContextSetFillColorWithColor(ctx, CDHex(0xC9BC9E).CGColor);
        CGContextFillRect(ctx, pad);
        CDDrawTile(ctx, CDPaperTile(), pad, scale * .5, .9, kCGBlendModeMultiply);
        CDDrawTile(ctx, CDGrainTile(), pad, scale * .7, .35, kCGBlendModeOverlay);
        CGContextSetFillColorWithColor(ctx, CDHex(0x3E2D22).CGColor);
        CGContextFillRect(ctx, [self box:16 :1.4 :68 :1.2]);
        NSGradient *tapeSheen = [[NSGradient alloc] initWithColors:@[[NSColor colorWithWhite:1 alpha:0], [NSColor colorWithWhite:1 alpha:.16], [NSColor colorWithWhite:1 alpha:0]]];
        [tapeSheen drawInRect:[self box:16 :1.4 :68 :1.2] angle:-90];
    });
    self.interior.contents = (__bridge id)image;
    CGImageRelease(image);
}

/// The front of the shell, above the reels: moulded plastic with grain, a bevelled edge, a recessed label bed,
/// grip ribs, metal screws and the head recess — or, for the printed shell, the cover printed across it.
- (void)renderSkin {
    CDPalette *p = self.palette;
    NSString *key = [NSString stringWithFormat:@"%@|%ld|%ld|%p|%@|%@", NSStringFromSize(self.skin.bounds.size), (long)p.index, (long)self.look, self.cover, NSStringFromPoint(self.artFocus), self.coverColors];
    if ([key isEqualToString:self.skinKey]) return;
    self.skinKey = key;
    [self renderInterior];
    [self renderGlass];
    CGFloat k = self.k, scale = CDBackingScale(self);
    BOOL light = p.light, printed = self.look == CDCassetteLookPrintedShell, tinted = self.look == CDCassetteLookTintedShell;
    NSColor *body = self.shellColor;
    CGImageRef cover = printed ? CDCGImage(self.cover) : NULL;
    CGPoint focus = self.artFocus;
    CGImageRef image = CDRenderImage(self.skin.bounds.size, scale, ^(CGContextRef ctx, CGSize s) {
        CGRect all = CGRectMake(0, 0, s.width, s.height);
        CGPathRef shape = [self shellPath], head = [self headPath], window = [self windowPath], openings = [self openingsPath];
        CGContextSaveGState(ctx);
        CGContextAddPath(ctx, shape); CGContextClip(ctx);
        // Translucent shells let the reels show through; everything else is solid plastic.
        CGContextSetAlpha(ctx, tinted ? (light ? .62 : .7) : 1);
        CGContextBeginTransparencyLayer(ctx, NULL);
        // Key light from the top left: the plastic brightens there and falls off to the lower right.
        CGContextSetFillColorWithColor(ctx, body.CGColor);
        CGContextFillRect(ctx, all);
        NSGradient *keyLight = [[NSGradient alloc] initWithColors:@[[NSColor colorWithWhite:1 alpha:light ? .34 : .1], [NSColor colorWithWhite:1 alpha:0], [NSColor colorWithWhite:0 alpha:light ? .08 : .22]] atLocations:(CGFloat[]){0, .55, 1} colorSpace:NSColorSpace.sRGBColorSpace];
        [keyLight drawFromCenter:CGPointMake(s.width * .18, s.height * .95) radius:0 toCenter:CGPointMake(s.width * .18, s.height * .95) radius:s.width * 1.05 options:NSGradientDrawsAfterEndingLocation];
        // Slight unevenness, like real injection-moulded plastic.
        CGContextSaveGState(ctx);
        CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
        CGContextSetAlpha(ctx, light ? .06 : .09);
        CGContextSetBlendMode(ctx, kCGBlendModeOverlay);
        CGContextDrawTiledImage(ctx, CGRectMake(0, 0, 30 * k, 30 * k), CDMottleTile());
        CGContextRestoreGState(ctx);
        if (printed && cover) {
            // Printed straight onto the plastic, into the head recess too (shaded there below).
            CGContextSaveGState(ctx);
            CDDrawCoverCrop(ctx, cover, all, focus, CGPointMake(.5, .19));
            CGContextSetBlendMode(ctx, kCGBlendModeSaturation);
            CGContextSetFillColorWithColor(ctx, [NSColor colorWithWhite:.5 alpha:.12].CGColor);
            CGContextFillRect(ctx, all);
            CGContextRestoreGState(ctx);
            CDDrawFilm(ctx, all, k, scale, 0xB0B5, !light);
        }
        CDDrawTile(ctx, CDGrainTile(), all, scale, light ? .12 : .15, kCGBlendModeOverlay);
        // The reflection of a soft light box across the upper half: the cue that makes it read as glossy plastic.
        CGPathRef lightBox = [self lightBoxPath];
        CDSoftFill(ctx, lightBox, 4 * k, [NSColor colorWithWhite:1 alpha:light ? .3 : .12], scale);
        CGPathRelease(lightBox);
        CDDrawScratches(ctx, all, k, 0x5C7A + (uint32_t)self.look, 70, light ? .16 : .1);
        // Head recess: darker, set back into the shell.
        CGContextSaveGState(ctx);
        CGContextAddPath(ctx, head); CGContextClip(ctx);
        NSColor *recess = printed ? [NSColor colorWithWhite:0 alpha:light ? .16 : .38] : [NSColor colorWithWhite:light ? 0 : 1 alpha:light ? .07 : .04];
        CGContextSetFillColorWithColor(ctx, recess.CGColor);
        CGContextFillRect(ctx, all);
        CGContextRestoreGState(ctx);
        CDInnerShadow(ctx, head, -.5 * k, 1.1 * k, [NSColor colorWithWhite:0 alpha:light ? .22 : .55]);
        // Grip ribs in the lower corners.
        for (NSNumber *x0 in @[@6.6, @86.4]) for (int i = 0; i < 5; i++) {
            CGRect rib = [self box:x0.doubleValue :7.4 + i * 1.9 :7 :.55];
            CGContextSetFillColorWithColor(ctx, [NSColor colorWithWhite:1 alpha:(light ? .55 : .1) * (printed ? .5 : 1)].CGColor);
            CGContextFillRect(ctx, CGRectOffset(rib, 0, .28 * k));
            CGContextSetFillColorWithColor(ctx, [NSColor colorWithWhite:0 alpha:(light ? .12 : .35) * (printed ? .6 : 1)].CGColor);
            CGContextFillRect(ctx, rib);
        }
        // The recessed bed the label sits in.
        if (!printed) {
            CGPathRef bed = CGPathCreateWithRoundedRect([self box:4.4 :19.8 :91.2 :41.4], 2.6 * k, 2.6 * k, NULL);
            CDInnerShadow(ctx, bed, -.45 * k, .9 * k, [NSColor colorWithWhite:0 alpha:light ? .18 : .45]);
            CDInnerShadow(ctx, bed, .4 * k, .5 * k, [NSColor colorWithWhite:1 alpha:light ? .7 : .12]);
            CGPathRelease(bed);
        }
        // Screws: a countersunk well and a small metal head with a cross slot.
        CGPoint screws[] = {[self at:4.4 :4.4], [self at:95.6 :4.4], [self at:4.4 :59.4], [self at:95.6 :59.4], [self at:50 :15.4]};
        for (int i = 0; i < 5; i++) {
            CGPoint c = screws[i];
            CGPathRef well = CGPathCreateWithEllipseInRect(CGRectMake(c.x - 1.55 * k, c.y - 1.55 * k, 3.1 * k, 3.1 * k), NULL);
            CGContextAddPath(ctx, well);
            CGContextSetFillColorWithColor(ctx, [NSColor colorWithWhite:0 alpha:light ? .08 : .25].CGColor);
            CGContextFillPath(ctx);
            CDInnerShadow(ctx, well, -.3 * k, .5 * k, [NSColor colorWithWhite:0 alpha:.35]);
            CGPathRelease(well);
            CGFloat sr = 1.05 * k;
            CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            CGFloat comps[] = {.9, .9, .91, 1,  .74, .75, .77, 1,  .58, .59, .61, 1};
            CGGradientRef metal = CGGradientCreateWithColorComponents(srgb, comps, (CGFloat[]){0, .6, 1}, 3);
            CGColorSpaceRelease(srgb);
            CGContextSaveGState(ctx);
            CGContextAddEllipseInRect(ctx, CGRectMake(c.x - sr, c.y - sr, sr * 2, sr * 2)); CGContextClip(ctx);
            CGContextDrawRadialGradient(ctx, metal, CGPointMake(c.x - sr * .35, c.y + sr * .4), 0, c, sr * 1.2, kCGGradientDrawsAfterEndLocation);
            // Turned metal: a bow-tie of light across the head.
            CGFloat bow[] = {1, 1, 1, 0,  1, 1, 1, .45,  1, 1, 1, 0,  1, 1, 1, 0,  1, 1, 1, .3,  1, 1, 1, 0};
            CGColorSpaceRef bowSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            CGGradientRef turned = CGGradientCreateWithColorComponents(bowSpace, bow, (CGFloat[]){0, .08, .18, .5, .58, .68}, 6);
            CGColorSpaceRelease(bowSpace);
            CGContextSetBlendMode(ctx, kCGBlendModeScreen);
            CGContextDrawConicGradient(ctx, turned, c, M_PI * .75);
            CGGradientRelease(turned);
            CGContextRestoreGState(ctx);
            CGGradientRelease(metal);
            CGContextSaveGState(ctx);
            CGContextTranslateCTM(ctx, c.x, c.y); CGContextRotateCTM(ctx, (i * 37 % 90) * M_PI / 180);
            CGContextSetLineCap(ctx, kCGLineCapRound);
            for (int pass = 0; pass < 2; pass++) {
                // The slot: a lit lower lip, then the dark cut itself.
                CGContextSetStrokeColorWithColor(ctx, pass ? [NSColor colorWithWhite:.12 alpha:.6].CGColor : [NSColor colorWithWhite:1 alpha:.55].CGColor);
                CGContextSetLineWidth(ctx, MAX(.6, .15 * k));
                CGFloat d = pass ? 0 : -.1 * k;
                CGContextMoveToPoint(ctx, -sr * .52, d); CGContextAddLineToPoint(ctx, sr * .52, d);
                CGContextMoveToPoint(ctx, 0, -sr * .52 + d); CGContextAddLineToPoint(ctx, 0, sr * .52 + d);
                CGContextStrokePath(ctx);
            }
            CGContextRestoreGState(ctx);
        }
        // Moulded lettering pressed into the plastic beside the centre screw.
        NSDictionary *moulded = CDTextAttributes([NSFont systemFontOfSize:1.55 * k weight:NSFontWeightSemibold], NSColor.blackColor, .22 * k, NSTextAlignmentCenter);
        NSArray *words = @[@"TYPE I · NORMAL", @"C-60 · 120μs EQ"];
        for (NSUInteger i = 0; i < (printed ? 0 : words.count); i++) {
            CGRect slot = [self box:i ? 55 : 21 :14.5 :24 :2.4];
            NSMutableDictionary *a = [moulded mutableCopy];
            a[NSForegroundColorAttributeName] = [NSColor colorWithWhite:1 alpha:light ? .75 : .1];
            [[[NSAttributedString alloc] initWithString:words[i] attributes:a] drawInRect:CGRectOffset(slot, 0, -.16 * k)];
            a[NSForegroundColorAttributeName] = [NSColor colorWithWhite:0 alpha:light ? .16 : .5];
            [[[NSAttributedString alloc] initWithString:words[i] attributes:a] drawInRect:slot];
        }
        // Bevelled edge with a moulded step just inside it: light along the top, shade along the bottom.
        CGPathRef step = CGPathCreateWithRoundedRect([self box:1.1 :1.1 :CDCassetteW - 2.2 :CDCassetteH - 2.2], 2.3 * k, 2.3 * k, NULL);
        CGContextSetLineWidth(ctx, .22 * k);
        CGContextSetStrokeColorWithColor(ctx, [NSColor colorWithWhite:0 alpha:light ? .07 : .3].CGColor);
        CGContextAddPath(ctx, step); CGContextStrokePath(ctx);
        CGContextSaveGState(ctx);
        CGContextTranslateCTM(ctx, 0, -.22 * k);
        CGContextSetStrokeColorWithColor(ctx, [NSColor colorWithWhite:1 alpha:light ? .55 : .08].CGColor);
        CGContextAddPath(ctx, step); CGContextStrokePath(ctx);
        CGContextRestoreGState(ctx);
        CGPathRelease(step);
        CDInnerShadow(ctx, shape, -.55 * k, .7 * k, [NSColor colorWithWhite:1 alpha:light ? .9 : .3]);
        CDInnerShadow(ctx, shape, .7 * k, 1.2 * k, [NSColor colorWithWhite:0 alpha:light ? .14 : .5]);
        CGContextEndTransparencyLayer(ctx);
        CGContextRestoreGState(ctx);
        // Cut the reel holes, the window and the head openings, with a thin dark wall around each.
        CGContextSetStrokeColorWithColor(ctx, [NSColor colorWithWhite:0 alpha:.35].CGColor);
        CGContextSetLineWidth(ctx, .5 * k);
        CGContextAddPath(ctx, window); CGContextStrokePath(ctx);
        CGContextSetBlendMode(ctx, kCGBlendModeClear);
        CGContextAddPath(ctx, window); CGContextFillPath(ctx);
        CGContextAddPath(ctx, openings); CGContextFillPath(ctx);
        CGContextSetBlendMode(ctx, kCGBlendModeNormal);
        // The walls of the openings: shadow under the top edge, light on the lower lip.
        CDInnerShadow(ctx, openings, -.5 * k, .8 * k, [NSColor colorWithWhite:0 alpha:.6]);
        CDInnerShadow(ctx, openings, .3 * k, .3 * k, [NSColor colorWithWhite:1 alpha:light ? .45 : .18]);
        CGPathRelease(shape); CGPathRelease(head); CGPathRelease(window); CGPathRelease(openings);
    });
    CDSetContents(self.skin, (__bridge id)image, self.skin.contents && !self.rebuilding ? .35 : 0);
    CGImageRelease(image);
}

/// The clear window: set back from the label (shadow along its top), a raised moulded rim, the light box
/// reflected more strongly than on the shell, fine scratches, and the counter scale printed on it.
- (void)renderGlass {
    CGFloat k = self.k, scale = CDBackingScale(self);
    BOOL light = self.palette.light;
    CGImageRef image = CDRenderImage(self.glass.bounds.size, scale, ^(CGContextRef ctx, CGSize s) {
        CGPathRef window = [self windowPath];
        CGRect bounds = CGPathGetBoundingBox(window);
        CGContextAddPath(ctx, window); CGContextClip(ctx);
        CGContextSetFillColorWithColor(ctx, [NSColor colorWithWhite:0 alpha:light ? .05 : .12].CGColor);
        CGContextFillRect(ctx, CGRectMake(0, 0, s.width, s.height));
        CDInnerShadow(ctx, window, -.8 * k, 1.6 * k, [NSColor colorWithWhite:0 alpha:.5]);
        CDInnerShadow(ctx, window, .35 * k, .4 * k, [NSColor colorWithWhite:1 alpha:.35]);
        CGPathRef lightBox = [self lightBoxPath];
        CDSoftFill(ctx, lightBox, 3 * k, [NSColor colorWithWhite:1 alpha:light ? .22 : .16], scale);
        CGPathRelease(lightBox);
        NSGradient *hi = [[NSGradient alloc] initWithColors:@[[NSColor colorWithWhite:1 alpha:0], [NSColor colorWithWhite:1 alpha:.14], [NSColor colorWithWhite:1 alpha:.03], [NSColor colorWithWhite:1 alpha:0]] atLocations:(CGFloat[]){.3, .4, .47, .56} colorSpace:NSColorSpace.sRGBColorSpace];
        [hi drawInRect:bounds angle:-35];
        CDDrawScratches(ctx, bounds, k, 0x77E1, 30, .16);
        CGContextSetStrokeColorWithColor(ctx, [NSColor colorWithWhite:1 alpha:.45].CGColor);
        CGContextSetLineWidth(ctx, MAX(1, .22 * k));
        for (int i = 0; i <= 8; i++) {
            CGPoint t = [self at:38 + i * 3 :CDHubY - 5.4];
            CGContextMoveToPoint(ctx, t.x, t.y); CGContextAddLineToPoint(ctx, t.x, t.y + (i % 2 ? .9 : 1.6) * k);
        }
        CGContextStrokePath(ctx);
        NSDictionary *scaleText = CDTextAttributes([NSFont monospacedDigitSystemFontOfSize:1.3 * k weight:NSFontWeightMedium], [NSColor colorWithWhite:1 alpha:.45], .1 * k, NSTextAlignmentCenter);
        for (int i = 0; i <= 2; i++) {
            CGPoint t = [self at:38 + i * 12 :CDHubY - 3.4];
            NSString *n = @[@"0", @"30", @"60"][i];
            [[[NSAttributedString alloc] initWithString:n attributes:scaleText] drawInRect:CGRectMake(t.x - 3 * k, t.y, 6 * k, 1.8 * k)];
        }
        CGPathRelease(window);
    });
    self.glass.contents = (__bridge id)image;
    CGImageRelease(image);
}

- (void)nowPlayingChanged {
    CDPalette *p = self.palette;
    CGSize size = self.label.bounds.size;
    if (!p || size.width < 4) return;
    NSString *title = self.np.hasSession ? (self.np.album.length ? self.np.album : @"Untitled") : @"Mixtape";
    NSArray *colors = self.coverColors.count ? self.coverColors : p.aurora;
    NSString *key = [NSString stringWithFormat:@"%@|%@|%ld|%@|%ld|%ld|%p|%@|%@", title, NSStringFromSize(size), (long)p.index, colors, (long)self.np.count, (long)self.look, self.cover, NSStringFromPoint(self.artFocus), CDLabelFontKey()];
    if ([key isEqualToString:self.labelKey]) return;
    self.labelKey = key;
    CGFloat k = self.k, scale = CDBackingScale(self);
    CDCassetteLook look = self.look;
    CGImageRef cover = CDCGImage(self.cover);
    CGPoint focus = self.artFocus;
    NSInteger tracks = MAX(0, self.np.count);
    CGImageRef image = CDRenderImage(size, scale, ^(CGContextRef ctx, CGSize s) {
        CGRect labelRect = [self labelRect];
        CGPathRef window = [self windowPath];
        NSColor *paper = CDHex(0xFBF8F0), *pen = [CDHex(0x22346B) colorWithAlphaComponent:.9];
        CGPathRef labelShape = CGPathCreateWithRoundedRect(labelRect, 2.2 * k, 2.2 * k, NULL);
        if (look != CDCassetteLookPrintedShell) {
            // The paper label, sitting a hair above the shell.
            CGContextSaveGState(ctx);
            CGContextSetShadowWithColor(ctx, CGSizeMake(0, -.25 * k), .7 * k, [NSColor colorWithWhite:0 alpha:.22].CGColor);
            CGContextAddPath(ctx, labelShape);
            CGContextSetFillColorWithColor(ctx, paper.CGColor);
            CGContextFillPath(ctx);
            CGContextRestoreGState(ctx);
            CGContextSaveGState(ctx);
            CGContextAddPath(ctx, labelShape); CGContextClip(ctx);
            if (look == CDCassetteLookCoverLabel) {
                // The cover printed edge to edge inside a thin paper margin, a little softer than on screen, as ink on paper.
                CGRect art = CGRectInset(labelRect, .9 * k, .9 * k);
                CGContextSaveGState(ctx);
                CGPathRef artShape = CGPathCreateWithRoundedRect(art, 1.6 * k, 1.6 * k, NULL);
                CGContextAddPath(ctx, artShape); CGContextClip(ctx); CGPathRelease(artShape);
                if (cover) CDDrawCoverCrop(ctx, cover, art, focus, CGPointMake(.5, .19));
                else { CGContextSetFillColorWithColor(ctx, CDMix(p.accent, paper, .4).CGColor); CGContextFillRect(ctx, art); }
                CGContextSetBlendMode(ctx, kCGBlendModeSaturation);
                CGContextSetFillColorWithColor(ctx, [NSColor colorWithWhite:.5 alpha:.14].CGColor);
                CGContextFillRect(ctx, art);
                CGContextSetBlendMode(ctx, kCGBlendModeNormal);
                CGContextSetFillColorWithColor(ctx, [paper colorWithAlphaComponent:.07].CGColor);
                CGContextFillRect(ctx, art);
                CGContextRestoreGState(ctx);
            } else {
                // Classic paper label: a colour band from the cover, a small cover sticker, ruled title line, stripes.
                NSColor *band = CDMix(colors.firstObject ?: p.accent, paper, .2);
                CGContextSetFillColorWithColor(ctx, band.CGColor);
                CGContextFillRect(ctx, CGRectMake(labelRect.origin.x, CGRectGetMaxY(labelRect) - 2.4 * k, labelRect.size.width, 2.4 * k));
                for (NSUInteger i = 0; i < 3; i++) {
                    NSColor *c = colors.count ? colors[i % colors.count] : p.accent;
                    CGContextSetFillColorWithColor(ctx, CDMix(c, paper, .12).CGColor);
                    CGContextFillRect(ctx, CGRectMake(labelRect.origin.x, labelRect.origin.y + (1.2 + i * 1.5) * k, labelRect.size.width, 1 * k));
                }
                CGContextSetStrokeColorWithColor(ctx, [CDHex(0x5B7BC4) colorWithAlphaComponent:.3].CGColor);
                CGContextSetLineWidth(ctx, 1);
                CGPoint l0 = [self at:19.5 :51.6], l1 = [self at:91 :51.6];
                CGContextMoveToPoint(ctx, l0.x, l0.y); CGContextAddLineToPoint(ctx, l1.x, l1.y); CGContextStrokePath(ctx);
                NSAttributedString *titleText = [[NSAttributedString alloc] initWithString:title attributes:CDTextAttributes(CDLabelFont(3.8 * k), pen, 0, NSTextAlignmentLeft)];
                [titleText drawWithRect:[self box:20.5 :51.9 :69.5 :5.6] options:NSStringDrawingTruncatesLastVisibleLine | NSStringDrawingUsesLineFragmentOrigin];
                CGRect sticker = [self box:7.8 :49.6 :9.2 :9.2];
                CGContextSaveGState(ctx);
                CGContextTranslateCTM(ctx, CGRectGetMidX(sticker), CGRectGetMidY(sticker));
                CGContextRotateCTM(ctx, 2.2 * M_PI / 180);
                CGRect local = CGRectOffset(sticker, -CGRectGetMidX(sticker), -CGRectGetMidY(sticker));
                CGContextSetShadowWithColor(ctx, CGSizeMake(0, -.2 * k), .6 * k, [NSColor colorWithWhite:0 alpha:.3].CGColor);
                CGContextSetFillColorWithColor(ctx, NSColor.whiteColor.CGColor);
                CGContextFillRect(ctx, local);
                CGContextSetShadowWithColor(ctx, CGSizeZero, 0, NULL);
                if (cover) CDDrawCoverCrop(ctx, cover, CGRectInset(local, .45 * k, .45 * k), CGPointMake(.5, .5), CGPointMake(.5, .5));
                CGContextClipToRect(ctx, local);
                CDDrawFilm(ctx, local, k * .5, scale, 0x5717, NO);
                CGContextRestoreGState(ctx);
                NSColor *meta = [CDHex(0x39332A) colorWithAlphaComponent:.6];
                NSAttributedString *length = [[NSAttributedString alloc] initWithString:@"C60" attributes:CDTextAttributes([NSFont systemFontOfSize:2.6 * k weight:NSFontWeightBold], meta, .15 * k, NSTextAlignmentCenter)];
                [length drawInRect:[self box:83.5 :CDHubY :11.5 :3.6]];
                if (tracks > 0) {
                    NSAttributedString *count = [[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"%ld TR", (long)tracks] attributes:CDTextAttributes([NSFont systemFontOfSize:1.7 * k weight:NSFontWeightSemibold], meta, .12 * k, NSTextAlignmentCenter)];
                    [count drawInRect:[self box:83.5 :CDHubY - 2.6 :11.5 :2.4]];
                }
            }
            CDDrawTile(ctx, CDPaperTile(), labelRect, scale, look == CDCassetteLookCoverLabel ? .15 : .6, kCGBlendModeMultiply);
            // The paper is never perfectly flat or evenly lit: a touch darker toward its edges.
            CDInnerShadow(ctx, labelShape, 0, 3 * k, [NSColor colorWithWhite:0 alpha:.1]);
            if (look == CDCassetteLookCoverLabel) CDDrawFilm(ctx, labelRect, k, scale, 0xA11CE, !p.light);
            CGContextRestoreGState(ctx);
            // Die-cut edge catching the light.
            CGContextSaveGState(ctx);
            CGContextAddPath(ctx, labelShape); CGContextClip(ctx);
            CGContextSetStrokeColorWithColor(ctx, [NSColor colorWithWhite:1 alpha:.7].CGColor);
            CGContextSetLineWidth(ctx, .3 * k);
            CGContextAddPath(ctx, labelShape); CGContextStrokePath(ctx);
            CGContextRestoreGState(ctx);
            // The holes punched through the label, with the paper's cut edge.
            CGContextSetStrokeColorWithColor(ctx, [NSColor colorWithWhite:0 alpha:.28].CGColor);
            CGContextSetLineWidth(ctx, .45 * k);
            CGContextAddPath(ctx, window); CGContextStrokePath(ctx);
            CGContextSetBlendMode(ctx, kCGBlendModeClear);
            CGContextAddPath(ctx, window); CGContextFillPath(ctx);
            CGContextSetBlendMode(ctx, kCGBlendModeNormal);
        }
        if (look != CDCassetteLookTintedShell) {
            // The title on a strip of masking tape stuck across the top edge, clear of the faces below it.
            CDDrawTitleTape(ctx, title, [self at:50 :look == CDCassetteLookPrintedShell ? 58.6 : 60.2], 64 * k, k, scale);
            CDDrawSideMark(ctx, [self at:8.9 :CDHubY], k, YES);
        } else {
            CDDrawSideMark(ctx, [self at:9.2 :CDHubY], k, NO);
        }
        CGPathRelease(window); CGPathRelease(labelShape);
    });
    CDSetContents(self.label, (__bridge id)image, self.label.contents && !self.rebuilding ? .35 : 0);
    CGImageRelease(image);
}

/// For the translucent shell: the tape as seen edge-on, from each pack round its guide roller to the pins.
- (void)updateTapeRun:(CGFloat)left :(CGFloat)right {
    if (self.tapeRun.hidden) return;
    CGFloat k = self.k;
    CGMutablePathRef path = CGPathCreateMutable();
    for (int side = 0; side < 2; side++) {
        CGFloat R = side ? right : left;
        CGPoint c = [self at:side ? CDHubRX : CDHubLX :CDHubY], q = [self at:side ? CDCassetteW - CDRollerX : CDRollerX :CDRollerY];
        CGFloat rr = CDRollerR * k, dx = q.x - c.x, dy = q.y - c.y, d = hypot(dx, dy);
        if (d <= fabs(R - rr)) continue;
        // Outer tangent, on the cassette's outside edge.
        CGFloat theta = atan2(dy, dx), alpha = acos((R - rr) / d), ang = side ? theta + alpha : theta - alpha;
        CGPoint t1 = CGPointMake(c.x + R * cos(ang), c.y + R * sin(ang)), t2 = CGPointMake(q.x + rr * cos(ang), q.y + rr * sin(ang));
        CGPoint pin = [self at:side ? CDCassetteW - CDPinX : CDPinX :CDTapeY];
        CGPathMoveToPoint(path, NULL, t1.x, t1.y);
        CGPathAddLineToPoint(path, NULL, t2.x, t2.y);
        CGPathAddArc(path, NULL, q.x, q.y, rr, ang, -M_PI / 2, side ? YES : NO);
        CGPathAddLineToPoint(path, NULL, pin.x, pin.y);
        if (!side) { CGPoint other = [self at:CDCassetteW - CDPinX :CDTapeY]; CGPathAddLineToPoint(path, NULL, other.x, other.y); }
    }
    self.tapeRun.path = path;
    CGPathRelease(path);
}

- (void)updatePacks {
    CGFloat k = self.k, rmin = CDPackMin * k, rmax = CDPackMax * k;
    double p = MAX(0, MIN(1, self.wound));
    CGFloat left = sqrt(rmin * rmin + (1 - p) * (rmax * rmax - rmin * rmin));
    CGFloat right = sqrt(rmin * rmin + p * (rmax * rmax - rmin * rmin));
    self.leftPack.bounds = CGRectMake(0, 0, left * 2, left * 2); self.leftPack.cornerRadius = left;
    self.rightPack.bounds = CGRectMake(0, 0, right * 2, right * 2); self.rightPack.cornerRadius = right;
    [self updateTapeRun:left :right];
}
- (void)step:(CFTimeInterval)dt {
    CGFloat k = self.k;
    if (k <= 0) return;
    CGFloat rmin = CDPackMin * k, rmax = CDPackMax * k;
    double target = self.np.hasSession ? MAX(0, MIN(1, self.np.trackProgress)) : 0;
    BOOL rewinding = target < self.wound - .02;
    double wound = self.wound;
    if (rewinding) wound = MAX(target, wound - dt * 1.1);          // a new track: fast rewind to the start of the tape
    else wound = CDApproach(wound, target, 6, dt);
    BOOL moved = fabs(wound - self.wound) > 1e-6;
    self.wound = wound;
    double v0 = 2 * M_PI * .45 * rmax;
    double targetSpeed = rewinding ? -v0 * 5 : (self.np.playing ? v0 : 0);
    self.speed = CDApproach(self.speed, targetSpeed, rewinding ? 9 : 3, dt);
    if (fabs(self.speed) < .01 && !moved) return;
    double p = MAX(0, MIN(1, wound));
    CGFloat left = sqrt(rmin * rmin + (1 - p) * (rmax * rmax - rmin * rmin)), right = sqrt(rmin * rmin + p * (rmax * rmax - rmin * rmin));
    // Tape speed is constant, so the small pack spins faster; cap it below the wagon-wheel blur.
    double wl = MAX(-5 * 2 * M_PI, MIN(5 * 2 * M_PI, self.speed / left)), wr = MAX(-5 * 2 * M_PI, MIN(5 * 2 * M_PI, self.speed / right));
    self.leftAngle = fmod(self.leftAngle + wl * dt, 2 * M_PI);
    self.rightAngle = fmod(self.rightAngle + wr * dt, 2 * M_PI);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.leftHub.transform = CATransform3DMakeRotation(-self.leftAngle, 0, 0, 1);
    self.rightHub.transform = CATransform3DMakeRotation(-self.rightAngle, 0, 0, 1);
    if (moved) [self updatePacks];
    [CATransaction commit];
}
@end
