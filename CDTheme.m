#import "CDTheme.h"

NSColor *CDHex(uint32_t rgb) {
    return [NSColor colorWithSRGBRed:((rgb >> 16) & 0xff) / 255.0 green:((rgb >> 8) & 0xff) / 255.0 blue:(rgb & 0xff) / 255.0 alpha:1];
}

static NSColor *CDRGB(NSColor *color) {
    return [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace] ?: [NSColor colorWithSRGBRed:.5 green:.5 blue:.5 alpha:1];
}

NSColor *CDMix(NSColor *a, NSColor *b, CGFloat t) {
    NSColor *x = CDRGB(a), *y = CDRGB(b);
    return [NSColor colorWithSRGBRed:x.redComponent * (1 - t) + y.redComponent * t
                               green:x.greenComponent * (1 - t) + y.greenComponent * t
                                blue:x.blueComponent * (1 - t) + y.blueComponent * t
                               alpha:x.alphaComponent * (1 - t) + y.alphaComponent * t];
}

static CGFloat CDLinear(CGFloat c) { return c <= .04045 ? c / 12.92 : pow((c + .055) / 1.055, 2.4); }
CGFloat CDLuminance(NSColor *color) {
    NSColor *c = CDRGB(color);
    return .2126 * CDLinear(c.redComponent) + .7152 * CDLinear(c.greenComponent) + .0722 * CDLinear(c.blueComponent);
}
static CGFloat CDContrast(NSColor *a, NSColor *b) {
    CGFloat x = CDLuminance(a), y = CDLuminance(b);
    return (MAX(x, y) + .05) / (MIN(x, y) + .05);
}
/// Smallest ink alpha over `base` that still reaches `target` contrast, never below `floor`.
static CGFloat CDAlphaForContrast(NSColor *ink, NSColor *base, CGFloat target, CGFloat floor) {
    CGFloat lo = 0, hi = 1;
    for (int i = 0; i < 24; i++) {
        CGFloat mid = (lo + hi) / 2;
        if (CDContrast(CDMix(base, ink, mid), base) >= target) hi = mid; else lo = mid;
    }
    return MAX(floor, MIN(1, hi));
}

CGImageRef CDCGImage(NSImage *image) {
    return image ? [image CGImageForProposedRect:NULL context:nil hints:nil] : NULL;
}

static NSFont *CDCascade(NSFont *font, NSArray<NSString *> *names) {
    NSMutableArray *list = [NSMutableArray new];
    for (NSString *name in names) [list addObject:[NSFontDescriptor fontDescriptorWithName:name size:font.pointSize]];
    NSFontDescriptor *descriptor = [font.fontDescriptor fontDescriptorByAddingAttributes:@{NSFontCascadeListAttribute: list}];
    return [NSFont fontWithDescriptor:descriptor size:font.pointSize] ?: font;
}

NSFont *CDSerifFont(CGFloat size, NSFontWeight weight) {
    NSFont *base = [NSFont systemFontOfSize:size weight:weight];
    NSFontDescriptor *serif = [base.fontDescriptor fontDescriptorWithDesign:NSFontDescriptorSystemDesignSerif];
    NSFont *font = serif ? [NSFont fontWithDescriptor:serif size:size] : base;
    BOOL heavy = weight >= NSFontWeightMedium;
    return CDCascade(font ?: base, heavy ? @[@"HiraMinProN-W6", @"STSongti-SC-Bold"] : @[@"HiraMinProN-W3", @"STSongti-SC-Light"]);
}

NSFont *CDRoundedFont(CGFloat size, NSFontWeight weight) {
    NSFont *base = [NSFont systemFontOfSize:size weight:weight];
    NSFontDescriptor *rounded = [base.fontDescriptor fontDescriptorWithDesign:NSFontDescriptorSystemDesignRounded];
    NSFont *font = rounded ? [NSFont fontWithDescriptor:rounded size:size] : base;
    return CDCascade(font ?: base, weight >= NSFontWeightMedium ? @[@"HiraMaruProN-W4"] : @[@"HiraMaruProN-W4"]);
}

NSFont *CDHandFont(CGFloat size) {
    NSFont *font = [NSFont fontWithName:@"Klee-Demibold" size:size] ?: [NSFont fontWithName:@"HanziPenSC-W5" size:size] ?: [NSFont fontWithName:@"BradleyHandITCTT-Bold" size:size];
    if (!font) return [NSFont systemFontOfSize:size weight:NSFontWeightMedium];
    return CDCascade(font, @[@"HanziPenSC-W5", @"Klee-Demibold", @"BradleyHandITCTT-Bold"]);
}

static NSArray<NSString *> *CDLabelNames;
static CGFloat CDLabelScale = 1;
void CDSetLabelFont(NSArray<NSString *> *names, CGFloat scale) { CDLabelNames = [names copy]; CDLabelScale = scale > 0 ? scale : 1; }
NSString *CDLabelFontKey(void) { return CDLabelNames ? [NSString stringWithFormat:@"%@@%.2f", [CDLabelNames componentsJoinedByString:@","], CDLabelScale] : @"default"; }
NSFont *CDLabelFont(CGFloat size) {
    NSArray<NSString *> *names = CDLabelNames ?: @[@"ToppanBunkyuMidashiMinchoStdN-ExtraBold"];
    CGFloat scale = CDLabelNames ? CDLabelScale : .84;      // it runs large next to the hand it replaced
    for (NSString *name in names) {
        NSFont *font = [NSFont fontWithName:name size:size * scale];
        if (!font) continue;
        NSMutableArray *rest = [NSMutableArray arrayWithArray:names];
        [rest removeObject:name];
        [rest addObjectsFromArray:@[@"Klee-Demibold", @"HanziPenSC-W5"]];
        return CDCascade(font, rest);
    }
    return CDHandFont(size);
}

NSDictionary *CDTextAttributes(NSFont *font, NSColor *color, CGFloat kern, NSTextAlignment alignment) {
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.alignment = alignment;
    paragraph.lineBreakMode = NSLineBreakByTruncatingTail;
    return @{NSFontAttributeName: font, NSForegroundColorAttributeName: color, NSKernAttributeName: @(kern), NSParagraphStyleAttributeName: paragraph};
}

@interface CDPalette ()
@property (nonatomic, readwrite) NSInteger index;
@property (nonatomic, readwrite) BOOL light;
@property (nonatomic, readwrite, copy) NSString *name;
@property (nonatomic, readwrite, strong) NSColor *base, *ink, *accent, *surface, *body, *lcd, *lcdInk;
@property (nonatomic, readwrite, strong, nullable) NSColor *glassTint;
@property (nonatomic, readwrite, copy) NSArray<NSColor *> *aurora;
@property (nonatomic, readwrite) CGFloat secondary, tertiary;
@end

@implementation CDPalette

+ (NSArray<NSString *> *)names { return @[@"深空灰", @"海雾蓝", @"暮光紫", @"暖茶棕", @"白粉色", @"玻璃浅绿", @"奶油白", @"晴空浅蓝"]; }
+ (NSInteger)count { return 8; }

+ (CDPalette *)paletteAtIndex:(NSInteger)index {
    static NSArray<CDPalette *> *all;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // base, ink, accent, surface, body, lcd, lcdInk, aurora ×3, glass tint (rgba ×1000, 0 = none)
        uint32_t table[8][10] = {
            {0x0E1013, 0xF4F5F7, 0xC9D3E0, 0x1A1D22, 0x2B2E34, 0xC6DBDF, 0x14232A, 0x3A4456, 0x2A3140, 0x4A4E5E},
            {0x07151E, 0xEEF7FB, 0x7CC6EC, 0x0F2330, 0x1B3544, 0x2E6BCB, 0xE8F2FF, 0x0D4C66, 0x1D6480, 0x0A3246},
            {0x130C1E, 0xF7F1FC, 0xC4A3F6, 0x201832, 0x2F2443, 0xCDBDF2, 0x271543, 0x4C2C72, 0x6D3A6B, 0x2D2358},
            {0x18100A, 0xFBF4EC, 0xE3B17B, 0x271C13, 0x3B2A1D, 0xEDB457, 0x3A2006, 0x5C3B1E, 0x714B25, 0x3A2615},
            {0xFBF2F5, 0x3B2A31, 0xE0809F, 0xFFF8FA, 0xF6D9E3, 0xF3D1DD, 0x4A1C2E, 0xF8C3D4, 0xFADFC6, 0xE6D1F4},
            {0xECF6F1, 0x22342E, 0x3FA578, 0xF7FCF9, 0xD2EADE, 0xB8D49A, 0x1E3212, 0xBDE7D2, 0xD8F1C7, 0xC4E2EE},
            {0xFAF6EC, 0x39332A, 0xBE9146, 0xFFFCF4, 0xF0E6CF, 0xE5DCBC, 0x36301B, 0xF5E1BA, 0xF2D4C2, 0xE8E9CE},
            {0xECF4FB, 0x21303D, 0x3F8CCF, 0xF8FBFE, 0xD4E6F5, 0xBEDCF2, 0x0F2F49, 0xC2DCF6, 0xD6EDF7, 0xDFD7F5},
        };
        CGFloat tints[8][4] = {{0,0,0,0}, {.45,.75,.95,.16}, {.76,.62,1,.16}, {1,.80,.55,.14}, {1,.77,.85,.23}, {.60,.92,.75,.25}, {1,.91,.68,.20}, {.67,.86,1,.22}};
        NSMutableArray *list = [NSMutableArray new];
        for (NSInteger i = 0; i < 8; i++) {
            CDPalette *p = [CDPalette new];
            p.index = i; p.light = i >= 4; p.name = [self names][i];
            p.base = CDHex(table[i][0]); p.ink = CDHex(table[i][1]); p.accent = CDHex(table[i][2]);
            p.surface = CDHex(table[i][3]); p.body = CDHex(table[i][4]); p.lcd = CDHex(table[i][5]); p.lcdInk = CDHex(table[i][6]);
            p.aurora = @[CDHex(table[i][7]), CDHex(table[i][8]), CDHex(table[i][9])];
            p.glassTint = tints[i][3] > 0 ? [NSColor colorWithSRGBRed:tints[i][0] green:tints[i][1] blue:tints[i][2] alpha:tints[i][3]] : nil;
            p.secondary = CDAlphaForContrast(p.ink, p.base, 5.2, .6);
            p.tertiary = CDAlphaForContrast(p.ink, p.base, 4.6, .48);
            [list addObject:p];
        }
        all = list;
    });
    return all[MAX(0, MIN(7, index))];
}

- (NSColor *)ink:(CGFloat)alpha { return [self.ink colorWithAlphaComponent:alpha]; }

- (NSImage *)swatch {
    return [NSImage imageWithSize:NSMakeSize(14, 14) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        NSBezierPath *outer = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(rect, 1, 1)];
        [self.base setFill]; [outer fill];
        [[NSColor colorWithWhite:.5 alpha:.45] setStroke]; outer.lineWidth = .8; [outer stroke];
        [self.accent setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(rect, 4.5, 4.5)] fill];
        return YES;
    }];
}
@end

NSArray<NSColor *> *CDDominantColors(NSImage *image, NSUInteger count) {
    CGImageRef cg = CDCGImage(image);
    if (!cg || !count) return @[];
    enum { side = 32 };
    uint8_t pixels[side * side * 4];
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(pixels, side, side, 8, side * 4, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    if (!ctx) return @[];
    CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);
    CGContextDrawImage(ctx, CGRectMake(0, 0, side, side), cg);
    CGContextRelease(ctx);
    enum { k = 6, n = side * side };
    float centers[k][3], sums[k][3]; int counts[k];
    for (int c = 0; c < k; c++) {
        int p = (c * 997 + 131) % n;
        for (int j = 0; j < 3; j++) centers[c][j] = pixels[p * 4 + j];
    }
    int labels[n];
    for (int iteration = 0; iteration < 10; iteration++) {
        memset(sums, 0, sizeof sums); memset(counts, 0, sizeof counts);
        for (int p = 0; p < n; p++) {
            int best = 0; float bestDistance = MAXFLOAT;
            for (int c = 0; c < k; c++) {
                float d = 0;
                for (int j = 0; j < 3; j++) { float v = pixels[p * 4 + j] - centers[c][j]; d += v * v; }
                if (d < bestDistance) { bestDistance = d; best = c; }
            }
            labels[p] = best; counts[best]++;
            for (int j = 0; j < 3; j++) sums[best][j] += pixels[p * 4 + j];
        }
        for (int c = 0; c < k; c++) if (counts[c]) for (int j = 0; j < 3; j++) centers[c][j] = sums[c][j] / counts[c];
    }
    NSMutableArray *scored = [NSMutableArray new];
    for (int c = 0; c < k; c++) {
        if (!counts[c]) continue;
        NSColor *color = [NSColor colorWithSRGBRed:centers[c][0] / 255 green:centers[c][1] / 255 blue:centers[c][2] / 255 alpha:1];
        CGFloat h, s, b, a; [color getHue:&h saturation:&s brightness:&b alpha:&a];
        double score = counts[c] * (.35 + s) * (b < .12 ? .3 : 1);
        [scored addObject:@{@"color": color, @"score": @(score)}];
    }
    [scored sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [b[@"score"] compare:a[@"score"]]; }];
    NSMutableArray *result = [NSMutableArray new];
    for (NSDictionary *entry in scored) { if (result.count == count) break; [result addObject:entry[@"color"]]; }
    while (result.count && result.count < count) [result addObject:result[result.count % MAX(1, scored.count)]];
    return result;
}
