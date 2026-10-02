#import "CDRetroPlayer.h"
#import "CDPixelArt.h"
#import <QuartzCore/QuartzCore.h>

static const int CDBands = 32;
// The dot matrix: 300 × 195 (the user's pick from 240 / 300 / 340 / 380). Layout is written in units of the
// original 240 × 156 design and scaled by U(); lines stay one dot thin. Build with -DCD_LCD_COLS=… to try others.
#ifndef CD_LCD_COLS
#define CD_LCD_COLS 300
#endif
static const int CDCols = CD_LCD_COLS, CDRows = (CD_LCD_COLS * 156 + 120) / 240;
static const CGFloat CDK = CD_LCD_COLS / 240.0;
static int U(CGFloat v) { return (int)lround(v * CDK); }
/// The cover is drawn once at this size: 1× on the playing page and exactly 2× on the art page, so zooming in shows
/// the same pixels, bigger — as large as fits between the status bar and the title line.
static int CDArtSide(void) { return ((CDRows - U(14) - U(16) - U(4)) / 2) & ~1; }

// The housing around the screen, in fractions of the LCD's width: a dark glass surround (a little taller at the
// top for its printed legend), then the matte shell with a deeper chin for the wordmark and the status LED.
static const CGFloat CDSurround = .03, CDSurroundTop = .054, CDBezel = .055, CDChin = .114, CDChamfer = .011;
static CGFloat CDDeviceWidth(CGFloat w) { return w * (1 + 2 * (CDSurround + CDBezel)); }
static CGFloat CDDeviceHeight(CGFloat w) { return w * CDRows / (CGFloat)CDCols + w * (CDSurroundTop + CDSurround + CDBezel + CDChin); }
static NSColor *CDShellColor(void) { return CDHex(0xBAA98C); }        // warm grey-khaki, bead-blasted
static NSColor *CDWarmLight(void) { return CDHex(0xFFF4E2); }
static NSColor *CDWarmShade(void) { return CDHex(0x2B2116); }

@interface CDPixelScreenView ()
@property (nonatomic, strong) CALayer *glow, *lcd, *shell, *contactShadow, *ambientShadow, *led;
@property (nonatomic) CGRect deviceRect, windowRect;
@property (nonatomic, copy) NSString *shellKey;
@property (nonatomic, strong) CAGradientLayer *backlight, *glare;
@property (nonatomic, strong) CAShapeLayer *rim;
@property (nonatomic) int pitch;
@property (nonatomic) double marqueeClock, renderClock, volumeUntil, clock;
@property (nonatomic) long long lastSecond;
@property (nonatomic) BOOL marqueeActive, dirty, spectrumActive, lightInk, artReady;
@property (nonatomic) uint8_t *mask;             // the LCD's gray mask while a frame is being drawn
@property (nonatomic) float *levels, *peaks;
@property (nonatomic) CGFloat scrollAccumulator;
@property (nonatomic) NSPoint downPoint;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSData *> *artCache;
@property (nonatomic, strong, nullable) id artMask;          // CGImage of the lifted subject, if any
@property (nonatomic) NSUInteger artToken;
@end

@implementation CDPixelScreenView

- (CGFloat)aspect { return CDDeviceWidth(1) / CDDeviceHeight(1); }
+ (CGFloat)screenAspect { return CDCols / (CGFloat)CDRows; }
+ (NSRect)housingForScreen:(NSRect)screen within:(NSRect)limits avoiding:(NSRect)avoid scale:(CGFloat)scale {
    // Never bigger than the bare screen would be; step down one whole dot pitch at a time until the housing fits.
    int largest = (int)floor(MIN(NSWidth(screen) * scale / CDCols, NSHeight(screen) * scale / CDRows));
    for (int pitch = largest; pitch >= 3; pitch--) {
        CGFloat w = CDCols * pitch / scale;
        NSRect d = NSMakeRect(NSMidX(limits) - CDDeviceWidth(w) / 2, NSMidY(limits) - CDDeviceHeight(w) / 2, CDDeviceWidth(w), CDDeviceHeight(w));
        if (NSWidth(d) > NSWidth(limits) || NSHeight(d) > NSHeight(limits)) continue;
        if (!NSIsEmptyRect(avoid) && NSIntersectsRect(d, avoid)) {
            // Clear the corner list by lifting it if there is room above; it stays centred left to right.
            CGFloat lift = NSMaxY(d) - NSMinY(avoid);
            if (NSMinY(d) - lift < NSMinY(limits)) continue;
            d.origin.y -= lift;
        }
        return NSIntegralRect(d);
    }
    return [self housingForScreen:NSMakeRect(NSMidX(limits) - 60, NSMidY(limits) - 39, 120, 78)];
}
+ (NSRect)housingForScreen:(NSRect)screen {
    CGFloat w = NSWidth(screen);
    // In the stage's flipped coordinates: legend band and bezel above the screen, surround and chin below it.
    return NSMakeRect(NSMinX(screen) - w * (CDSurround + CDBezel), NSMinY(screen) - w * (CDSurroundTop + CDBezel), CDDeviceWidth(w), CDDeviceHeight(w));
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.glow = [CALayer layer];
        self.lcd = [CALayer layer];
        self.lcd.masksToBounds = YES;
        self.backlight = [CAGradientLayer layer];
        self.backlight.type = kCAGradientLayerRadial;
        self.glare = [CAGradientLayer layer];
        self.rim = [CAShapeLayer layer];
        self.ambientShadow = [CALayer layer];
        self.contactShadow = [CALayer layer];
        self.shell = [CALayer layer];
        self.led = [CALayer layer];
        for (CALayer *l in @[self.ambientShadow, self.contactShadow, self.shell, self.glow, self.lcd, self.backlight, self.glare, self.rim, self.led]) [self.layer addSublayer:l];
        for (CALayer *l in @[self.ambientShadow, self.contactShadow]) l.shadowColor = NSColor.blackColor.CGColor;
        self.glow.hidden = YES;
        self.lastSecond = -1;
        self.artCache = [NSMutableDictionary new];
        self.artReady = YES;
        self.levels = calloc(CDBands, sizeof(float));
        self.peaks = calloc(CDBands, sizeof(float));
    }
    return self;
}
- (void)dealloc { free(_levels); free(_peaks); }

#pragma mark Layout

- (void)rebuild {
    NSRect r = self.objectRect;
    CGFloat scale = self.window.backingScaleFactor ?: 2;
    // Whole dots only: the LCD takes the largest pitch that, with its housing, still fits.
    CGFloat fitW = MIN(NSWidth(r) / CDDeviceWidth(1), NSHeight(r) / CDDeviceHeight(1));
    self.pitch = MAX(3, (int)floor(fitW * scale / CDCols + .02));
    CGFloat w = CDCols * self.pitch / scale, h = CDRows * self.pitch / scale;
    CGSize device = CGSizeMake(CDDeviceWidth(w), CDDeviceHeight(w));
    CGRect deviceRect = CGRectMake(round(NSMidX(r) - device.width / 2), round(NSMidY(r) - device.height / 2), round(device.width), round(device.height));
    CGRect frame = CGRectMake(round((deviceRect.origin.x + w * (CDBezel + CDSurround)) * scale) / scale,
                              round((deviceRect.origin.y + w * (CDChin + CDSurround)) * scale) / scale, w, h);
    CGRect window = CGRectMake(frame.origin.x - w * CDSurround, frame.origin.y - w * CDSurround, w * (1 + 2 * CDSurround), h + w * (CDSurround + CDSurroundTop));
    self.deviceRect = deviceRect; self.windowRect = window;
    CGFloat radius = w * .012;
    self.lcd.frame = frame; self.lcd.cornerRadius = radius; self.lcd.contentsScale = scale;
    CGPathRef shape = CGPathCreateWithRoundedRect(frame, radius, radius, NULL);
    self.rim.path = shape;
    self.rim.fillColor = NULL;
    self.rim.lineWidth = 1;
    CGPathRelease(shape);
    self.backlight.frame = frame; self.backlight.cornerRadius = radius; self.backlight.masksToBounds = YES;
    // One sheet of glass covers the whole window, so its reflection runs across the surround too.
    self.glare.frame = window; self.glare.cornerRadius = w * .026; self.glare.masksToBounds = YES;
    // Uneven backlight: brighter centre, slightly dimmer corners.
    self.backlight.startPoint = CGPointMake(.5, .55); self.backlight.endPoint = CGPointMake(1.15, 1.2);
    self.backlight.colors = @[(id)[NSColor colorWithWhite:1 alpha:.07].CGColor, (id)[NSColor colorWithWhite:1 alpha:0].CGColor, (id)[NSColor colorWithWhite:0 alpha:.14].CGColor];
    self.backlight.locations = @[@0, @.5, @1];
    self.glare.startPoint = CGPointMake(0, 1); self.glare.endPoint = CGPointMake(1, 0);
    CGColorRef clear = [NSColor colorWithWhite:1 alpha:0].CGColor;
    self.glare.colors = @[(id)[NSColor colorWithWhite:1 alpha:.1].CGColor, (id)[NSColor colorWithWhite:1 alpha:.03].CGColor, (__bridge id)clear, (__bridge id)clear];
    self.glare.locations = @[@0, @.38, @.39, @1];
    // Two shadows: a tight one where the shell meets the surface and a wide, soft one.
    CGFloat R = w * .07;
    CGPathRef body = CGPathCreateWithRoundedRect(deviceRect, R, R, NULL);
    for (CALayer *l in @[self.ambientShadow, self.contactShadow]) { l.frame = self.bounds; l.shadowPath = body; }
    CGPathRelease(body);
    self.contactShadow.shadowRadius = MAX(2, w * .007); self.contactShadow.shadowOffset = CGSizeMake(0, -w * .005);
    self.ambientShadow.shadowRadius = w * .05; self.ambientShadow.shadowOffset = CGSizeMake(0, -w * .032);
    // Status LED on the chin, at the left, in line with the window's edge.
    CGFloat ledD = MAX(4, round(w * .0125));
    self.led.frame = CGRectMake(round(CGRectGetMinX(window) + w * .014), round(deviceRect.origin.y + w * CDChin / 2 - ledD / 2 + w * .004), ledD, ledD);
    self.led.cornerRadius = ledD / 2;
    self.shell.frame = deviceRect;
    self.shellKey = nil;
    [self paletteChanged];
}

/// The shell as one image: moulded body, rolled edge, parting line, the recess and dark glass around the LCD,
/// the printed legend and the debossed wordmark. Redrawn only when the size or the backlight colour changes.
- (void)renderShell {
    CDPalette *p = self.palette;
    CGRect deviceRect = self.deviceRect, window = self.windowRect, lcd = self.lcd.frame;
    if (!p || deviceRect.size.width < 20) return;
    CGFloat scale = self.window.backingScaleFactor ?: 2;
    NSString *key = [NSString stringWithFormat:@"%@|%@|%.1f|%@", NSStringFromRect(deviceRect), NSStringFromRect(lcd), scale, p.lcd];
    if ([key isEqualToString:self.shellKey]) return;
    self.shellKey = key;
    CGFloat w = lcd.size.width;
    CGPoint o = deviceRect.origin;
    CGRect win = CGRectOffset(window, -o.x, -o.y), screen = CGRectOffset(lcd, -o.x, -o.y), ledRect = CGRectOffset(self.led.frame, -o.x, -o.y);
    NSColor *base = CDShellColor(), *lcdColor = p.lcd;
    CGImageRef image = CDRenderImage(deviceRect.size, scale, ^(CGContextRef ctx, CGSize size) {
        CGRect B = CGRectMake(0, 0, size.width, size.height);
        CGFloat R = w * .07, wr = w * .026, c = w * CDChamfer;
        CGPathRef body = CGPathCreateWithRoundedRect(B, R, R, NULL);
        CGContextSaveGState(ctx);
        CGContextAddPath(ctx, body); CGContextClip(ctx);
        // Moulded body under a soft key light from the top left: no gloss, just gently graded matte plastic.
        NSGradient *fall = [[NSGradient alloc] initWithColorsAndLocations:CDMix(base, CDWarmLight(), .12), 0.0, base, .55, CDMix(base, CDWarmShade(), .1), 1.0, nil];
        [fall drawInRect:B angle:-90];
        NSGradient *keyLight = [[NSGradient alloc] initWithColors:@[[CDWarmLight() colorWithAlphaComponent:.14], [CDWarmLight() colorWithAlphaComponent:0]]];
        NSPoint lightAt = NSMakePoint(size.width * .26, size.height * .86);
        [keyLight drawFromCenter:lightAt radius:0 toCenter:lightAt radius:size.width * .72 options:0];
        // Bead-blasted finish: a slight unevenness and a very fine, dense grain.
        CGContextSaveGState(ctx);
        CGContextSetAlpha(ctx, .06); CGContextSetBlendMode(ctx, kCGBlendModeSoftLight);
        CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
        CGContextDrawTiledImage(ctx, CGRectMake(0, 0, w * .3, w * .3), CDMottleTile());
        CGContextRestoreGState(ctx);
        CDDrawTile(ctx, CDGrainTile(), B, scale, .22, kCGBlendModeOverlay);
        CDDrawTile(ctx, CDGrainTile(), B, scale * .5, .1, kCGBlendModeSoftLight);
        CGContextRestoreGState(ctx);
        // Rolled edge: lit along the top, darker along the bottom and the sides.
        CDInnerShadow(ctx, body, 0, w * .012, [NSColor colorWithWhite:0 alpha:.13]);
        CDInnerShadow(ctx, body, -w * .0035, w * .004, [NSColor colorWithWhite:1 alpha:.55]);
        CDInnerShadow(ctx, body, w * .004, w * .006, [NSColor colorWithWhite:0 alpha:.22]);
        // Parting line between the front and back halves, just inside the edge.
        CGFloat inset = w * .017;
        CGPathRef seam = CGPathCreateWithRoundedRect(CGRectInset(B, inset, inset), R - inset, R - inset, NULL);
        CGContextSaveGState(ctx);
        CGContextTranslateCTM(ctx, 0, -.7);
        CGContextAddPath(ctx, seam); CGContextSetLineWidth(ctx, .7);
        CGContextSetStrokeColorWithColor(ctx, [NSColor colorWithWhite:1 alpha:.24].CGColor); CGContextStrokePath(ctx);
        CGContextRestoreGState(ctx);
        CGContextAddPath(ctx, seam); CGContextSetLineWidth(ctx, .75);
        CGContextSetStrokeColorWithColor(ctx, [NSColor colorWithWhite:0 alpha:.17].CGColor); CGContextStrokePath(ctx);
        CGPathRelease(seam);
        // The recess: a chamfer steps down to the window; its top wall is in shadow, its bottom wall catches the light.
        CGRect chamfer = CGRectInset(win, -c, -c);
        CGPathRef step = CGPathCreateWithRoundedRect(chamfer, wr + c, wr + c, NULL);
        CGContextSaveGState(ctx);
        CGContextSetShadowWithColor(ctx, CGSizeMake(0, -w * .002 * scale), w * .006 * scale, [NSColor colorWithWhite:1 alpha:.35].CGColor);
        CGContextAddPath(ctx, step); CGContextSetFillColorWithColor(ctx, base.CGColor); CGContextFillPath(ctx);
        CGContextRestoreGState(ctx);
        CGContextSaveGState(ctx);
        CGContextAddPath(ctx, step); CGContextClip(ctx);
        NSGradient *wall = [[NSGradient alloc] initWithColorsAndLocations:CDMix(base, CDWarmShade(), .55), 0.0, CDMix(base, CDWarmShade(), .3), .35, CDMix(base, CDWarmShade(), .12), .6, CDMix(base, CDWarmLight(), .38), 1.0, nil];
        [wall drawInRect:chamfer angle:-90];
        // The glass sits below the step: a soft contact shadow where they meet.
        CGPathRef seat = CGPathCreateWithRoundedRect(CGRectInset(win, -.6, -.6), wr + .6, wr + .6, NULL);
        CGContextSetShadowWithColor(ctx, CGSizeMake(0, -w * .001 * scale), w * .004 * scale, [NSColor colorWithWhite:0 alpha:.55].CGColor);
        CGContextAddPath(ctx, seat); CGContextSetFillColorWithColor(ctx, CDHex(0x1B1917).CGColor); CGContextFillPath(ctx);
        CGPathRelease(seat);
        CGContextRestoreGState(ctx);
        CGContextAddPath(ctx, step); CGContextSetLineWidth(ctx, .6);
        CGContextSetStrokeColorWithColor(ctx, [NSColor colorWithWhite:0 alpha:.22].CGColor); CGContextStrokePath(ctx);
        CGPathRelease(step);
        // Dark glass around the LCD, lit a little by the backlight.
        CGPathRef glass = CGPathCreateWithRoundedRect(win, wr, wr, NULL);
        CGContextSaveGState(ctx);
        CGContextAddPath(ctx, glass); CGContextClip(ctx);
        NSGradient *smoke = [[NSGradient alloc] initWithStartingColor:CDHex(0x221F1C) endingColor:CDHex(0x151412)];
        [smoke drawInRect:win angle:-90];
        CGContextSetShadowWithColor(ctx, CGSizeZero, w * .03 * scale, [lcdColor colorWithAlphaComponent:.55].CGColor);
        CGContextSetFillColorWithColor(ctx, lcdColor.CGColor);
        CGContextFillRect(ctx, screen);
        CGContextRestoreGState(ctx);
        // Printed legend in the top band of the glass, between two hairlines.
        NSFont *legendFont = [NSFont systemFontOfSize:MAX(6, w * .0165) weight:NSFontWeightMedium];
        NSColor *printInk = [CDHex(0x9A948A) colorWithAlphaComponent:.8];
        NSString *legendText = [NSString stringWithFormat:@"DOT MATRIX  ·  %d × %d", CDCols, CDRows];
        NSAttributedString *legend = [[NSAttributedString alloc] initWithString:legendText attributes:@{NSFontAttributeName: legendFont, NSForegroundColorAttributeName: printInk, NSKernAttributeName: @(legendFont.pointSize * .22)}];
        NSSize ls = legend.size;
        CGFloat bandMid = CGRectGetMaxY(screen) + (CGRectGetMaxY(win) - CGRectGetMaxY(screen)) / 2;
        [legend drawAtPoint:NSMakePoint(CGRectGetMidX(win) - ls.width / 2, bandMid - ls.height / 2 - legendFont.descender * .35)];
        CGContextSetStrokeColorWithColor(ctx, [printInk colorWithAlphaComponent:.45].CGColor); CGContextSetLineWidth(ctx, .8);
        CGFloat gapX = w * .018;
        CGContextMoveToPoint(ctx, CGRectGetMinX(screen), bandMid); CGContextAddLineToPoint(ctx, CGRectGetMidX(win) - ls.width / 2 - gapX, bandMid);
        CGContextMoveToPoint(ctx, CGRectGetMidX(win) + ls.width / 2 + gapX, bandMid); CGContextAddLineToPoint(ctx, CGRectGetMaxX(screen), bandMid);
        CGContextStrokePath(ctx);
        // Edges of the glass: a bright hairline along the top, a dark one along the bottom.
        CDInnerShadow(ctx, glass, -1, 1.2, [NSColor colorWithWhite:1 alpha:.18]);
        CDInnerShadow(ctx, glass, 1, 2, [NSColor colorWithWhite:0 alpha:.5]);
        CGPathRelease(glass);
        // Debossed wordmark on the chin: dark where the pressed-in letters face down, a light lip below.
        NSFont *markFont = [NSFont systemFontOfSize:MAX(7, w * .022) weight:NSFontWeightSemibold];
        NSDictionary *markAttrs = @{NSFontAttributeName: markFont, NSKernAttributeName: @(markFont.pointSize * .42)};
        NSString *mark = @"CD NOOK";
        NSSize ms = [mark sizeWithAttributes:markAttrs];
        NSPoint mp = NSMakePoint(round(size.width / 2 - ms.width / 2 + markFont.pointSize * .21), round(w * CDChin / 2 - ms.height / 2 + w * .004));
        NSMutableDictionary *lip = [markAttrs mutableCopy]; lip[NSForegroundColorAttributeName] = [NSColor colorWithWhite:1 alpha:.42];
        [mark drawAtPoint:NSMakePoint(mp.x, mp.y - .8) withAttributes:lip];
        NSMutableDictionary *cut = [markAttrs mutableCopy]; cut[NSForegroundColorAttributeName] = [CDMix(base, NSColor.blackColor, .34) colorWithAlphaComponent:.92];
        [mark drawAtPoint:mp withAttributes:cut];
        // Bezel around the status LED.
        CGContextSetFillColorWithColor(ctx, CDMix(base, NSColor.blackColor, .55).CGColor);
        CGContextFillEllipseInRect(ctx, CGRectInset(ledRect, -1.4, -1.4));
        CGContextSetStrokeColorWithColor(ctx, [NSColor colorWithWhite:1 alpha:.35].CGColor); CGContextSetLineWidth(ctx, .7);
        CGContextAddArc(ctx, CGRectGetMidX(ledRect), CGRectGetMidY(ledRect), ledRect.size.width / 2 + 1.6, M_PI * 1.1, M_PI * 1.9, 0);
        CGContextStrokePath(ctx);
        CGPathRelease(body);
    });
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.shell.contents = (__bridge id)image;
    [CATransaction commit];
    if (image) CGImageRelease(image);
}

/// Amber while playing, a faint glow when paused, off without a disc.
- (void)updateLED {
    CDNowPlaying *np = self.np;
    NSColor *amber = CDHex(0xFFA43A);
    CGFloat level = !np.hasSession ? 0 : np.playing ? 1 : .3;
    [CATransaction begin];
    [CATransaction setAnimationDuration:.25];
    self.led.backgroundColor = (level > 0 ? CDMix(CDHex(0x5A4630), amber, level) : CDHex(0x3B342C)).CGColor;
    self.led.shadowColor = amber.CGColor;
    self.led.shadowOffset = CGSizeZero;
    self.led.shadowRadius = MAX(2, self.led.bounds.size.width * .8);
    self.led.shadowOpacity = level * .9;
    [CATransaction commit];
}

- (void)paletteChanged {
    CDPalette *p = self.palette;
    if (!p) return;
    self.rim.strokeColor = [NSColor colorWithWhite:0 alpha:.45].CGColor;
    self.contactShadow.shadowOpacity = p.light ? .3 : .55;
    self.ambientShadow.shadowOpacity = p.light ? .22 : .5;
    [self renderShell];
    [self updateLED];
    // Some themes use light pixels on a dark screen; the cover must not turn into a negative there.
    BOOL lightInk = CDLuminance(p.lcdInk) > CDLuminance(p.lcd);
    if (lightInk != self.lightInk) { self.lightInk = lightInk; [self.artCache removeAllObjects]; }
    self.dirty = YES;
    [self renderLCD];
}

#pragma mark State

- (void)nowPlayingChanged {
    if (!self.np.hasSession && self.screen != 0) _screen = 0;
    [self updateLED];
    self.marqueeClock = 0;
    self.dirty = YES;
    [self renderLCD];
}
- (void)progressChanged {
    long long second = self.np.elapsedMS / 1000;
    if (second != self.lastSecond) { self.lastSecond = second; self.dirty = YES; }
}
- (void)setScreen:(NSInteger)screen { _screen = screen; self.marqueeClock = 0; self.dirty = YES; [self renderLCD]; }

- (void)step:(CFTimeInterval)dt {
    self.clock += dt;
    self.marqueeClock += dt;
    self.renderClock += dt;
    [self stepSpectrum:dt];
    BOOL volumeVisible = self.clock < self.volumeUntil;
    if ((self.marqueeActive || volumeVisible || self.spectrumActive) && self.renderClock > .1) self.dirty = YES;
    if (self.dirty && self.renderClock > .05) [self renderLCD];
}

- (void)stepSpectrum:(CFTimeInterval)dt {
    BOOL live = self.np.hasSession && self.np.playing;
    double t = self.clock;
    for (int i = 0; i < CDBands; i++) {
        float f = i / (float)(CDBands - 1), target = 0;
        if (live) {
            // Smooth pseudo-music: a bass-heavy tilt plus a few drifting sines per band.
            float wobble = .5f + .5f * sinf(t * (2.1 + i * .29) + i * 1.7f) * sinf(t * (1.3 + i * .09) + i * .6f);
            float pulse = .5f + .5f * sinf(t * 7.8 + i * .4f);
            target = (.88f - .48f * f) * (.35f + .65f * wobble) * (.75f + .25f * pulse);
        }
        float current = self.levels[i];
        current += (target - current) * MIN(1.f, (target > current ? 18 : 5) * (float)dt);
        self.levels[i] = current;
        self.peaks[i] = MAX(current, self.peaks[i] - (float)dt * .45f);
    }
}

#pragma mark Text helpers (drawn without antialiasing so glyphs land on whole LCD pixels)

static NSFont *CDLCDFont(CGFloat size) { size = U(size); return [NSFont fontWithName:@"HiraginoSans-W3" size:size] ?: [NSFont systemFontOfSize:size]; }
static NSFont *CDLCDDigitFont(void) { CGFloat size = U(10); return [NSFont fontWithName:@"Monaco" size:size] ?: [NSFont monospacedDigitSystemFontOfSize:size weight:NSFontWeightRegular]; }
static void CDLCDText(NSString *text, CGFloat x, CGFloat y, CGFloat size, BOOL inverse) {
    [text drawAtPoint:NSMakePoint(x, y) withAttributes:@{NSFontAttributeName: CDLCDFont(size), NSForegroundColorAttributeName: inverse ? NSColor.whiteColor : NSColor.blackColor}];
}
static CGFloat CDLCDWidth(NSString *text, CGFloat size) { return ceil([text sizeWithAttributes:@{NSFontAttributeName: CDLCDFont(size)}].width); }
static void CDLCDDigits(NSString *text, CGFloat x, CGFloat y, BOOL inverse) {
    [text drawAtPoint:NSMakePoint(x, y) withAttributes:@{NSFontAttributeName: CDLCDDigitFont(), NSForegroundColorAttributeName: inverse ? NSColor.whiteColor : NSColor.blackColor}];
}
static CGFloat CDLCDDigitsWidth(NSString *text) { return ceil([text sizeWithAttributes:@{NSFontAttributeName: CDLCDDigitFont()}].width); }
static NSString *CDClockText(long long ms) {
    long long s = MAX(0, ms / 1000);
    return s >= 3600 ? [NSString stringWithFormat:@"%lld:%02lld:%02lld", s / 3600, (s / 60) % 60, s % 60] : [NSString stringWithFormat:@"%lld:%02lld", s / 60, s % 60];
}
static uint32_t CDPackLCD(const float *bg, const float *ink, float share) {
    uint8_t c[4];
    for (int k = 0; k < 3; k++) c[k] = (uint8_t)MAX(0, MIN(255, (bg[k] * (1 - share) + ink[k] * share) * 255));
    c[3] = 255;
    uint32_t v; memcpy(&v, c, 4); return v;
}

- (void)marquee:(NSString *)text x:(CGFloat)x y:(CGFloat)y width:(CGFloat)width size:(CGFloat)size ctx:(CGContextRef)ctx centered:(BOOL)centered {
    CGFloat w = CDLCDWidth(text, size);
    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, CGRectMake(x, y - 1, width, U(size + 5)));
    if (w > width) {
        self.marqueeActive = YES;
        // An old LCD advances its text in small, distinct steps. Longer overflow travels
        // farther per step so a long credit does not take minutes to become readable.
        CGFloat overflow = w - width;
        CGFloat stride = MIN(U(12), MAX(U(4), round(U(4) + overflow / U(140))));
        const double interval = .7, startHold = 14.0, endHold = 3.2;
        NSInteger steps = (NSInteger)ceil(overflow / stride);
        double cycle = startHold + steps * interval + endHold;
        double t = fmod(self.marqueeClock, cycle);
        NSInteger step = t < startHold ? 0 : MIN(steps, (NSInteger)floor((t - startHold) / interval) + 1);
        CGFloat offset = MIN(overflow, step * stride);
        CDLCDText(text, x - offset, y, size, NO);
    } else CDLCDText(text, centered ? x + (width - w) / 2 : x, y, size, NO);
    CGContextRestoreGState(ctx);
}

#pragma mark Artwork

// Cover art goes through CDPixelArt: the subject is lifted off the cover (Vision, off the main thread), drawn
// as clean shapes with a firm outline, and the background keeps only a few clean contours. Results are cached
// per page size; a theme change only redraws (a light-ink screen needs the art the other way round).

- (void)coverChanged {
    NSUInteger token = ++self.artToken;
    self.artCache = [NSMutableDictionary new];
    self.artMask = nil;
    self.artReady = NO;
    self.dirty = YES;
    NSImage *cover = self.cover;
    CGImageRef image = CDCGImage(cover);
    if (!image) { self.artReady = YES; [self renderLCD]; return; }
    CGImageRetain(image);
    BOOL lightInk = self.lightInk;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        CGImageRef mask = CDCreateSubjectMask(image);
        NSDictionary *art = @{@(CDArtSide()): CDPixelArtRender(image, mask, CDArtSide(), lightInk)};
        CGImageRelease(image);
        id maskObject = mask ? (__bridge_transfer id)mask : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || strongSelf.artToken != token) return;
            strongSelf.artMask = maskObject;
            strongSelf.artReady = YES;
            if (strongSelf.lightInk == lightInk) [strongSelf.artCache addEntriesFromDictionary:art];
            strongSelf.dirty = YES;
            [strongSelf renderLCD];
        });
    });
    [self renderLCD];
}

- (const uint8_t *)art {
    if (!self.cover || !self.artReady) return NULL;
    NSData *art = self.artCache[@(CDArtSide())];
    if (!art) {
        CGImageRef image = CDCGImage(self.cover);
        if (!image) return NULL;
        art = CDPixelArtRender(image, (__bridge CGImageRef)self.artMask, CDArtSide(), self.lightInk);
        self.artCache[@(CDArtSide())] = art;
    }
    return art.bytes;
}

/// The cover at `scale` × its drawn size, so the art page is a true zoom of the playing page: same pixels, bigger.
- (void)drawCover:(CGContextRef)ctx x:(int)x0 y:(int)y0 scale:(int)scale {
    if (self.cover && !self.artReady) return;          // the subject is still being lifted; the art appears in a moment
    const uint8_t *art = self.art;
    int side = CDArtSide();
    if (!art || !self.mask) { [self drawPlaceholder:ctx x:x0 y:y0 side:side * scale]; return; }
    // Written straight into the LCD's gray mask (row 0 = top): 0 lights a pixel.
    for (int y = 0; y < side * scale; y++) {
        if (y0 + y < 0 || y0 + y >= CDRows) continue;
        uint8_t *row = self.mask + (y0 + y) * CDCols;
        const uint8_t *source = art + (y / scale) * side;
        for (int x = 0; x < side * scale; x++) if (source[x / scale] && x0 + x >= 0 && x0 + x < CDCols) row[x0 + x] = 0;
    }
}

- (void)drawPlaceholder:(CGContextRef)ctx x:(int)x0 y:(int)y0 side:(int)side {
    CGContextSetGrayFillColor(ctx, 0, 1);
    CGContextStrokeRectWithWidth(ctx, CGRectMake(x0 + .5, y0 + .5, side - 1, side - 1), 1);
    CGFloat r = side * .32;
    CGContextStrokeEllipseInRect(ctx, CGRectMake(x0 + side / 2.0 - r, y0 + side / 2.0 - r, r * 2, r * 2));
    CGContextFillRect(ctx, CGRectMake(x0 + side / 2 - 1, y0 + side / 2 - 1, 3, 3));
}

#pragma mark Rendering

- (void)renderLCD {
    CDPalette *p = self.palette;
    int pitch = self.pitch;
    if (!p || pitch < 3) return;
    self.dirty = NO;
    self.renderClock = 0;
    const int cols = CDCols, rows = CDRows;
    uint8_t *mask = calloc(cols * rows, 1);
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGContextRef ctx = CGBitmapContextCreate(mask, cols, rows, 8, cols, gray, (CGBitmapInfo)kCGImageAlphaNone);
    self.mask = mask;
    CGColorSpaceRelease(gray);
    CGContextSetGrayFillColor(ctx, 1, 1);
    CGContextFillRect(ctx, CGRectMake(0, 0, cols, rows));
    CGContextTranslateCTM(ctx, 0, rows);
    CGContextScaleCTM(ctx, 1, -1);
    CGContextSetShouldAntialias(ctx, false);
    CGContextSetAllowsAntialiasing(ctx, false);
    CGContextSetShouldSmoothFonts(ctx, false);
    CGContextSetGrayStrokeColor(ctx, 0, 1);
    CGContextSetGrayFillColor(ctx, 0, 1);
    NSGraphicsContext *previous = NSGraphicsContext.currentContext;
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:YES];
    self.marqueeActive = NO;
    self.spectrumActive = NO;
    [self drawStatusBar:ctx];
    if (!self.np.hasSession) [self drawEmpty:ctx];
    else if (self.screen == 1) [self drawArtwork:ctx];
    else [self drawNowPlaying:ctx];
    NSGraphicsContext.currentContext = previous;
    CGContextRelease(ctx);
    self.mask = NULL;
    // Compose the dot matrix from prebuilt cells: off, on, and off with a soft shadow on its left / top / both edges.
    int W = cols * pitch, H = rows * pitch;
    int gapWidth = MAX(1, pitch / 6), shadeWidth = MAX(1, pitch / 5);
    uint32_t *rgba = malloc((size_t)W * H * 4);
    NSColor *bgc = [p.lcd colorUsingColorSpace:NSColorSpace.sRGBColorSpace], *inkc = [p.lcdInk colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    float bg[3] = {bgc.redComponent, bgc.greenComponent, bgc.blueComponent}, ink[3] = {inkc.redComponent, inkc.greenComponent, inkc.blueComponent};
    uint32_t off = CDPackLCD(bg, ink, 0), offGap = CDPackLCD(bg, ink, .07f), on = CDPackLCD(bg, ink, 1), onGap = CDPackLCD(bg, ink, .62f), shade = CDPackLCD(bg, ink, .2f);
    int cellSize = pitch * pitch;
    uint32_t *cells = malloc(sizeof(uint32_t) * cellSize * 5);
    for (int variant = 0; variant < 5; variant++) for (int iy = 0; iy < pitch; iy++) for (int ix = 0; ix < pitch; ix++) {
        BOOL gap = ix >= pitch - gapWidth || iy >= pitch - gapWidth;
        uint32_t v = variant == 1 ? (gap ? onGap : on) : (gap ? offGap : off);
        if (!gap && (variant == 2 || variant == 4) && ix < shadeWidth) v = shade;
        if (!gap && (variant == 3 || variant == 4) && iy < shadeWidth) v = shade;
        cells[variant * cellSize + iy * pitch + ix] = v;
    }
    for (int cy = 0; cy < rows; cy++) for (int cx = 0; cx < cols; cx++) {
        int variant;
        if (mask[cy * cols + cx] < 128) variant = 1;
        else {
            BOOL left = cx > 0 && mask[cy * cols + cx - 1] < 128, top = cy > 0 && mask[(cy - 1) * cols + cx] < 128;
            variant = left && top ? 4 : left ? 2 : top ? 3 : 0;
        }
        const uint32_t *cell = cells + variant * cellSize;
        for (int iy = 0; iy < pitch; iy++) memcpy(rgba + (size_t)(cy * pitch + iy) * W + cx * pitch, cell + iy * pitch, pitch * 4);
    }
    free(cells);
    free(mask);
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef out = CGBitmapContextCreate(rgba, W, H, 8, W * 4, srgb, (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
    CGColorSpaceRelease(srgb);
    CGImageRef image = CGBitmapContextCreateImage(out);
    CGContextRelease(out);
    free(rgba);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.lcd.contents = (__bridge id)image;
    [CATransaction commit];
    CGImageRelease(image);
}

- (void)drawStatusBar:(CGContextRef)ctx {
    const int cols = CDCols;
    if (self.np.hasSession) {
        if (self.np.playing) {
            CGMutablePathRef tri = CGPathCreateMutable();
            CGPathMoveToPoint(tri, NULL, U(5), U(3)); CGPathAddLineToPoint(tri, NULL, U(5), U(10)); CGPathAddLineToPoint(tri, NULL, U(9), U(6.5)); CGPathCloseSubpath(tri);
            CGContextAddPath(ctx, tri); CGContextFillPath(ctx); CGPathRelease(tri);
        } else {
            CGContextFillRect(ctx, CGRectMake(U(5), U(3), U(2), U(7))); CGContextFillRect(ctx, CGRectMake(U(8), U(3), U(2), U(7)));
        }
        CDLCDDigits([NSString stringWithFormat:@"%ld/%ld", (long)self.np.index + 1, (long)self.np.count], U(14), U(1), NO);
        NSString *mode = self.screen == 1 ? @"ART" : @"PLAY";
        CDLCDDigits(mode, (cols - CDLCDDigitsWidth(mode)) / 2, U(1), NO);
    } else {
        CDLCDDigits(@"CD NOOK", U(5), U(1), NO);
    }
    int bx = cols - U(21), by = U(3), bw = U(13), bh = U(6);
    CGContextStrokeRectWithWidth(ctx, CGRectMake(bx + .5, by + .5, bw, bh), 1);
    CGContextFillRect(ctx, CGRectMake(bx + bw + 1, U(5), U(2), U(3)));
    for (int i = 0; i < 3; i++) CGContextFillRect(ctx, CGRectMake(bx + U(2) + i * U(4), U(5), U(3), U(3)));
    CGContextFillRect(ctx, CGRectMake(0, U(13), cols, 1));
}

- (void)drawNowPlaying:(CGContextRef)ctx {
    const int cols = CDCols, rows = CDRows, side = CDArtSide();
    [self drawCover:ctx x:U(6) y:U(19) scale:1];
    CGFloat x0 = U(6) + side + U(9), width = cols - x0 - U(6);
    [self marquee:self.np.track.length ? self.np.track : @"—" x:x0 y:U(21) width:width size:12 ctx:ctx centered:NO];
    CGFloat y = U(40);
    if (self.np.artist.length) { [self marquee:self.np.artist x:x0 y:y width:width size:11 ctx:ctx centered:NO]; y += U(15); }
    if (self.np.album.length) { [self marquee:self.np.album x:x0 y:y width:width size:11 ctx:ctx centered:NO]; y += U(15); }
    CDLCDDigits([NSString stringWithFormat:@"TRACK %ld OF %ld", (long)self.np.index + 1, (long)self.np.count], x0, y + U(4), NO);
    int barY = rows - U(24);
    // The spectrum starts below whichever is lower: the cover or the text beside it.
    [self drawSpectrumTop:(int)MAX(U(19) + side + U(7), y + U(4) + U(16)) bottom:barY - U(6) ctx:ctx];
    if (self.clock < self.volumeUntil) {
        CGContextFillRect(ctx, CGRectMake(U(6), barY + U(1), U(3), U(5)));
        CGMutablePathRef cone = CGPathCreateMutable();
        CGPathMoveToPoint(cone, NULL, U(9), barY + U(1)); CGPathAddLineToPoint(cone, NULL, U(13), barY - U(2)); CGPathAddLineToPoint(cone, NULL, U(13), barY + U(9)); CGPathAddLineToPoint(cone, NULL, U(9), barY + U(6)); CGPathCloseSubpath(cone);
        CGContextAddPath(ctx, cone); CGContextFillPath(ctx); CGPathRelease(cone);
        int segments = 20, left = U(20), span = cols - left - U(6);
        int lit = (int)round(self.np.volume / 100.0 * segments);
        for (int i = 0; i < segments; i++) {
            CGRect cell = CGRectMake(left + i * span / (double)segments, barY - U(1), span / (double)segments - U(2), U(9));
            if (i < lit) CGContextFillRect(ctx, cell); else CGContextStrokeRectWithWidth(ctx, CGRectInset(cell, .5, .5), 1);
        }
        CDLCDDigits([NSString stringWithFormat:@"VOL %ld", (long)self.np.volume], U(6), rows - U(13), NO);
        return;
    }
    CGContextStrokeRectWithWidth(ctx, CGRectMake(U(5) + .5, barY + .5, cols - 2 * U(5) - 1, U(7)), 1);
    CGContextFillRect(ctx, CGRectMake(U(7), barY + U(2), round((cols - 2 * U(7)) * MAX(0, MIN(1, self.np.trackProgress))), U(4)));
    NSString *elapsed = CDClockText(self.np.elapsedMS);
    NSString *remain = [@"-" stringByAppendingString:CDClockText(MAX(0, self.np.durationMS - self.np.elapsedMS))];
    CDLCDDigits(elapsed, U(6), rows - U(13), NO);
    CDLCDDigits(remain, cols - U(6) - CDLCDDigitsWidth(remain), rows - U(13), NO);
}

- (void)drawSpectrumTop:(int)top bottom:(int)bottom ctx:(CGContextRef)ctx {
    const int cols = CDCols;
    int width = cols - U(12), bandW = MAX(3, width / CDBands), left = U(6) + (width - bandW * CDBands) / 2;
    int span = bottom - top, step = U(3), bar = U(2);
    if (span < U(6)) return;
    BOOL any = NO;
    for (int i = 0; i < CDBands; i++) {
        int x = left + i * bandW;
        int h = (int)round(self.levels[i] * span);
        for (int y = bottom - bar; y > bottom - h; y -= step) CGContextFillRect(ctx, CGRectMake(x, y, bandW - 1, bar));
        int peak = bottom - (int)round(self.peaks[i] * span) - 1;
        if (self.peaks[i] > .02) CGContextFillRect(ctx, CGRectMake(x, MAX(top, peak), bandW - 1, 1));
        if (self.levels[i] > .01 || self.peaks[i] > .02) any = YES;
    }
    CGContextFillRect(ctx, CGRectMake(left, bottom, bandW * CDBands - 1, 1));
    self.spectrumActive = any || (self.np.hasSession && self.np.playing);
}

- (void)drawArtwork:(CGContextRef)ctx {
    // The cover doubled, centred between the status bar and the title line.
    const int cols = CDCols, rows = CDRows, top = U(14), bottom = rows - U(16), side = CDArtSide() * 2;
    [self drawCover:ctx x:(cols - side) / 2 y:top + MAX(0, (bottom - top - side) / 2) scale:2];
    [self marquee:self.np.track.length ? self.np.track : @"—" x:U(6) y:rows - U(15) width:cols - U(12) size:11 ctx:ctx centered:YES];
}

- (void)drawEmpty:(CGContextRef)ctx {
    const int cols = CDCols, rows = CDRows;
    int side = U(50);
    [self drawPlaceholder:ctx x:(cols - side) / 2 y:U(28) side:side];
    NSString *line1 = @"INSERT A DISC";
    CDLCDDigits(line1, (cols - CDLCDDigitsWidth(line1)) / 2, U(28) + side + U(10), NO);
    NSString *line2 = @"CMD-O  OPEN FOLDER", *line3 = @"CMD-D  PLAY DEMO";
    CDLCDDigits(line2, (cols - CDLCDDigitsWidth(line2)) / 2, rows - U(34), NO);
    CDLCDDigits(line3, (cols - CDLCDDigitsWidth(line3)) / 2, rows - U(20), NO);
}

#pragma mark Interaction

- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (void)mouseDown:(NSEvent *)event { self.downPoint = [self convertPoint:event.locationInWindow fromView:nil]; }
- (void)mouseUp:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    if (!CGRectContainsPoint(self.deviceRect, p) || hypot(p.x - self.downPoint.x, p.y - self.downPoint.y) > 6) return;
    if (!self.np.hasSession) { if (self.onOpen) self.onOpen(); return; }
    self.screen = self.screen == 1 ? 0 : 1;
}
- (void)scrollWheel:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    if (!CGRectContainsPoint(self.deviceRect, p) || !self.np.hasSession) { [super scrollWheel:event]; return; }
    CGFloat delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8;
    // Follow the finger / wheel direction: up = louder.
    self.scrollAccumulator += event.directionInvertedFromDevice ? -delta : delta;
    while (fabs(self.scrollAccumulator) >= 14) {
        NSInteger step = self.scrollAccumulator > 0 ? 1 : -1;
        self.scrollAccumulator -= step * 14;
        if (self.onVolumeStep) { self.np.volume = self.onVolumeStep(step * 4); self.volumeUntil = self.clock + 1.6; }
        self.dirty = YES;
    }
    [self renderLCD];
}
@end
