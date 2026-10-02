#import "CDAlbumWall.h"
#import "CDVolumes.h"
#import <QuartzCore/QuartzCore.h>
#import <ImageIO/ImageIO.h>
#import <CoreImage/CoreImage.h>

#pragma mark - Helpers

static NSString *CDWString(id value) { return [value isKindOfClass:NSString.class] ? value : @""; }
static CGFloat CDWClamp(CGFloat v, CGFloat lo, CGFloat hi) { return MAX(lo, MIN(hi, v)); }
static CGFloat CDWRad(CGFloat degrees) { return degrees * M_PI / 180; }
static uint64_t CDWHash64(NSString *text) {
    // Stable between launches, unlike NSString's hash.
    uint64_t h = 1469598103934665603ULL;
    for (NSUInteger i = 0; i < text.length; i++) { h ^= [text characterAtIndex:i]; h *= 1099511628211ULL; }
    return h;
}
typedef struct { uint64_t s; } CDWRandom;
static CDWRandom CDWSeeded(NSString *key) { CDWRandom r = { CDWHash64(key ?: @"") | 1 }; return r; }
static CGFloat CDWNext(CDWRandom *r) { r->s ^= r->s << 13; r->s ^= r->s >> 7; r->s ^= r->s << 17; return (r->s >> 11) * (1.0 / 9007199254740992.0); }
static void CDWQuiet(void (^block)(void)) { [CATransaction begin]; [CATransaction setDisableActions:YES]; block(); [CATransaction commit]; }
static NSValue *CDWPoint(CGPoint p) { return [NSValue valueWithPoint:NSPointFromCGPoint(p)]; }
static NSValue *CDWT(CATransform3D t) { return [NSValue valueWithCATransform3D:t]; }

// Springs always leave the model at the destination, so nothing snaps back when the animation is removed.
static void CDWSpringFrom(CALayer *layer, NSString *path, id from, id to, CGFloat stiffness, CGFloat damping, CFTimeInterval delay) {
    CDWQuiet(^{ [layer setValue:to forKeyPath:path]; });
    CASpringAnimation *a = [CASpringAnimation animationWithKeyPath:path];
    a.fromValue = from; a.toValue = to; a.mass = 1; a.stiffness = stiffness; a.damping = damping;
    a.duration = a.settlingDuration;
    if (delay > 0) { a.beginTime = CACurrentMediaTime() + delay; a.fillMode = kCAFillModeBackwards; }
    [layer addAnimation:a forKey:path];
}
static void CDWSpring(CALayer *layer, NSString *path, id to, CGFloat stiffness, CGFloat damping, CFTimeInterval delay) {
    CALayer *present = layer.presentationLayer;
    CDWSpringFrom(layer, path, [present ?: layer valueForKeyPath:path], to, stiffness, damping, delay);
}
static void CDWFade(CALayer *layer, CGFloat to, CFTimeInterval duration, CFTimeInterval delay) {
    CALayer *present = layer.presentationLayer;
    CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"opacity"];
    a.fromValue = @(present ? present.opacity : layer.opacity); a.toValue = @(to); a.duration = duration;
    a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    if (delay > 0) { a.beginTime = CACurrentMediaTime() + delay; a.fillMode = kCAFillModeBackwards; }
    CDWQuiet(^{ layer.opacity = to; });
    [layer addAnimation:a forKey:@"opacity"];
}

#pragma mark - Images

static CGColorSpaceRef CDWSRGB(void) {
    static CGColorSpaceRef space; static dispatch_once_t once;
    dispatch_once(&once, ^{ space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB); });
    return space;
}
static CGContextRef CDWBitmap(size_t w, size_t h, BOOL opaque) {
    return CGBitmapContextCreate(NULL, w, h, 8, 0, CDWSRGB(), opaque ? (CGBitmapInfo)kCGImageAlphaNoneSkipLast : (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
}
/// Draws in points with y pointing down, like the wall's layers.
static CGImageRef CDWDraw(CGSize size, CGFloat scale, void (^draw)(CGContextRef ctx)) CF_RETURNS_RETAINED {
    size_t w = MAX(1, (size_t)ceil(size.width * scale)), h = MAX(1, (size_t)ceil(size.height * scale));
    CGContextRef ctx = CDWBitmap(w, h, NO);
    CGContextTranslateCTM(ctx, 0, h); CGContextScaleCTM(ctx, scale, -scale);
    draw(ctx);
    CGImageRef image = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return image;
}
static void CDWGradientFill(CGContextRef ctx, CGPoint a, CGPoint b, NSArray<NSColor *> *colors, NSArray<NSNumber *> *stops) {
    NSMutableArray *cg = [NSMutableArray new];
    for (NSColor *c in colors) [cg addObject:(__bridge id)[c colorUsingColorSpace:NSColorSpace.sRGBColorSpace].CGColor];
    CGFloat locations[8] = {0};
    for (NSUInteger i = 0; i < stops.count && i < 8; i++) locations[i] = stops[i].doubleValue;
    CGGradientRef gradient = CGGradientCreateWithColors(CDWSRGB(), (__bridge CFArrayRef)cg, locations);
    CGContextDrawLinearGradient(ctx, gradient, a, b, kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
    CGGradientRelease(gradient);
}
static NSColor *CDWWhite(CGFloat a) { return [NSColor colorWithSRGBRed:1 green:1 blue:1 alpha:a]; }
static NSColor *CDWBlack(CGFloat a) { return [NSColor colorWithSRGBRed:0 green:0 blue:0 alpha:a]; }

/// Text into an unflipped bitmap context, safe off the main thread.
static void CDWDrawText(CGContextRef ctx, NSString *text, NSFont *font, NSColor *color, CGRect rect, NSTextAlignment alignment, CGFloat kern) {
    NSGraphicsContext *previous = NSGraphicsContext.currentContext;
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:NO];
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.alignment = alignment; paragraph.lineBreakMode = NSLineBreakByWordWrapping; paragraph.lineSpacing = font.pointSize * .12;
    NSAttributedString *string = [[NSAttributedString alloc] initWithString:text ?: @"" attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: color, NSParagraphStyleAttributeName: paragraph, NSKernAttributeName: @(kern)}];
    NSRect need = [string boundingRectWithSize:rect.size options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine];
    CGFloat height = MIN(rect.size.height, ceil(need.size.height));
    [string drawWithRect:NSMakeRect(rect.origin.x, rect.origin.y, rect.size.width, height) options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine];
    NSGraphicsContext.currentContext = previous;
}

static NSString *CDWThumbFolder(void) {
    static NSString *folder; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
        folder = [caches stringByAppendingPathComponent:@"CD Glass/Wall"];
#ifdef CDGLASS_SNAPSHOT
        NSString *store = NSProcessInfo.processInfo.environment[@"CDGLASS_STORE"];
        if (store.length) folder = [store stringByAppendingPathComponent:@"Wall"];
#endif
        [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
    });
    return folder;
}
/// Decodes and downsamples into an opaque sRGB bitmap (CMYK / P3 / alpha covers all composite cheaply afterwards).
static CGImageRef CDWDecode(NSString *path, NSInteger maxPixel, BOOL flatten) CF_RETURNS_RETAINED {
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
    if (!source) return NULL;
    CGImageRef raw = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)@{
        (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES, (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (id)kCGImageSourceThumbnailMaxPixelSize: @(maxPixel), (id)kCGImageSourceShouldCacheImmediately: @YES});
    CFRelease(source);
    if (!raw) return NULL;
    size_t w = CGImageGetWidth(raw), h = CGImageGetHeight(raw);
    if (w < 4 || h < 4) { CGImageRelease(raw); return NULL; }
    if (!flatten) return raw;                                     // our own thumbnails are sRGB and opaque already
    CGContextRef ctx = CDWBitmap(w, h, YES);
    CGContextSetRGBFillColor(ctx, 1, 1, 1, 1); CGContextFillRect(ctx, CGRectMake(0, 0, w, h));
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), raw);
    CGImageRelease(raw);
    CGImageRef flat = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return flat;
}
/// A 640 px master of every cover is kept on the internal disk, so the wall opens quickly (and still shows covers)
/// when the CDs live on a slow or disconnected external drive.
static NSString *CDWThumbPath(NSString *path) {
    return [CDWThumbFolder() stringByAppendingPathComponent:[NSString stringWithFormat:@"%016llx.jpg", CDWHash64(path)]];
}
static CGImageRef CDWMakeMaster(NSString *path, NSString *thumb) CF_RETURNS_RETAINED {
    CGImageRef master = CDWDecode(path, 640, YES);
    if (!master) return NULL;
    NSString *temporary = [thumb stringByAppendingFormat:@".%u.jpg", arc4random()];
    CGImageDestinationRef out = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:temporary], CFSTR("public.jpeg"), 1, NULL);
    if (out) {
        CGImageDestinationAddImage(out, master, (__bridge CFDictionaryRef)@{(id)kCGImageDestinationLossyCompressionQuality: @.88});
        if (CGImageDestinationFinalize(out)) rename(temporary.fileSystemRepresentation, thumb.fileSystemRepresentation);
        CFRelease(out);
    }
    [NSFileManager.defaultManager removeItemAtPath:temporary error:nil];
    return master;
}
static NSOperationQueue *CDWIdleQueue(void);
/// How long reading one original may take before its disk counts as not answering (a sleeping drive spins up
/// well within this). Past it the wall stops asking that disk and says so, instead of queueing more reads behind it.
static const NSTimeInterval CDWDiskPatience = 10;
static CGImageRef CDWThumb(NSString *path, NSInteger px) CF_RETURNS_RETAINED {
    if (!path.length) return NULL;
    NSString *thumb = CDWThumbPath(path);
    if ([NSFileManager.defaultManager fileExistsAtPath:thumb]) {
        // Shown at once; whether the original changed since is checked later, off the critical path.
        static NSMutableSet *checked; static dispatch_once_t once; dispatch_once(&once, ^{ checked = [NSMutableSet new]; });
        BOOL check = NO;
        @synchronized (checked) { if (![checked containsObject:path]) { [checked addObject:path]; check = YES; } }
        if (check) [CDWIdleQueue() addOperationWithBlock:^{
            CDVolumeRun(path, CDWDiskPatience, ^id{
                NSFileManager *fm = NSFileManager.defaultManager;
                NSDate *source = [fm attributesOfItemAtPath:path error:nil].fileModificationDate, *cached = [fm attributesOfItemAtPath:thumb error:nil].fileModificationDate;
                if (source && cached && [cached compare:source] == NSOrderedAscending) { CGImageRef fresh = CDWMakeMaster(path, thumb); if (fresh) CGImageRelease(fresh); }
                return nil;
            }, NULL);
        }];
        CGImageRef image = CDWDecode(thumb, px, NO);
        if (image) return image;
    }
    // The original lives on the CD's disk, which may have stopped answering.
    id made = CDVolumeRun(path, CDWDiskPatience, ^id{ CGImageRef m = CDWMakeMaster(path, thumb); return m ? CFBridgingRelease(m) : nil; }, NULL);
    CGImageRef master = made ? CGImageRetain((__bridge CGImageRef)made) : NULL;
    if (!master || px >= 600) return master;
    CGImageRelease(master);
    return CDWDecode(thumb, px, NO);
}
/// Posters are tall, with faces near the top and the logo at the bottom: crop the square from the upper part.
static CGImageRef CDWSquareFromTop(CGImageRef image) CF_RETURNS_RETAINED {
    size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);
    if (h <= w * 1.04) return CGImageRetain(image);
    return CGImageCreateWithImageInRect(image, CGRectMake(0, round((h - w) * .18), w, w));
}
/// A series key visual standing in for a CD sleeve gets the CD's name printed along the bottom,
/// so a burst of look-alike fallbacks can still be told apart.
static CGImageRef CDWCaptioned(CGImageRef art, NSString *caption) CF_RETURNS_RETAINED {
    size_t w = CGImageGetWidth(art), h = CGImageGetHeight(art);
    CGFloat side = MIN(w, h);
    CGContextRef ctx = CDWBitmap((size_t)side, (size_t)side, YES);
    CGContextDrawImage(ctx, CGRectMake((side - w) / 2, (side - h) / 2, w, h), art);
    CDWGradientFill(ctx, CGPointMake(0, 0), CGPointMake(0, side * .52), @[CDWBlack(.72), CDWBlack(.28), CDWBlack(0)], @[@0, @.55, @1]);
    CGFloat pad = round(side * .07);
    NSFont *font = [NSFont systemFontOfSize:MAX(8, round(side * .062)) weight:NSFontWeightSemibold];
    CDWDrawText(ctx, caption, font, CDWWhite(.96), CGRectMake(pad, pad, side - pad * 2, font.pointSize * 3.9), NSTextAlignmentLeft, 0);
    CGImageRef image = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return image;
}
static NSCache *CDWMemory(void) {
    static NSCache *cache; static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; cache.countLimit = 600; cache.totalCostLimit = 220 * 1024 * 1024; });
    return cache;
}
static NSOperationQueue *CDWQueue(void) {
    static NSOperationQueue *queue; static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = [NSOperationQueue new]; queue.maxConcurrentOperationCount = 4; queue.qualityOfService = NSQualityOfServiceUserInitiated; });
    return queue;
}
static NSOperationQueue *CDWIdleQueue(void) {
    static NSOperationQueue *queue; static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = [NSOperationQueue new]; queue.maxConcurrentOperationCount = 1; queue.qualityOfService = NSQualityOfServiceUtility; });
    return queue;
}
static NSInteger CDWBucket(CGFloat pixels) {
    for (NSNumber *b in @[@96, @160, @256, @384, @512]) if (pixels <= b.doubleValue) return b.integerValue;
    return 640;
}

#pragma mark - Layers without implicit animations

@interface CDWLayer : CALayer @end
@implementation CDWLayer
- (id<CAAction>)actionForKey:(NSString *)event { return nil; }
@end
@interface CDWText : CATextLayer @end
@implementation CDWText
- (id<CAAction>)actionForKey:(NSString *)event { return nil; }
@end
static CGFloat CDWTextWidth(CATextLayer *layer) {
    NSString *string = [layer.string isKindOfClass:NSString.class] ? layer.string : [layer.string isKindOfClass:NSAttributedString.class] ? [layer.string string] : @"";
    if (!string.length) return 0;
    id font = (__bridge id)layer.font;
    NSFont *measure = [font isKindOfClass:NSFont.class] ? [NSFont fontWithDescriptor:[font fontDescriptor] size:layer.fontSize] : [NSFont systemFontOfSize:layer.fontSize];
    return ceil([string sizeWithAttributes:@{NSFontAttributeName: measure ?: [NSFont systemFontOfSize:layer.fontSize]}].width);
}
@interface CDWGradient : CAGradientLayer @end
@implementation CDWGradient
- (id<CAAction>)actionForKey:(NSString *)event { return nil; }
@end

/// One sleeve: a shadowed plate (jewel case, print, glass tile or pixel frame) holding the art.
@interface CDWPlate : CDWLayer
@property (nonatomic, strong) CDWLayer *art, *skin, *shade, *tape;
@end
@implementation CDWPlate
- (instancetype)init {
    if ((self = [super init])) {
        _art = [CDWLayer layer]; _art.masksToBounds = YES; _art.contentsGravity = kCAGravityResizeAspectFill;
        _skin = [CDWLayer layer];
        _shade = [CDWLayer layer]; _shade.backgroundColor = CGColorGetConstantColor(kCGColorBlack); _shade.opacity = 0;
        _tape = [CDWLayer layer]; _tape.hidden = YES;
        for (CALayer *layer in @[_art, _skin, _shade, _tape]) [self addSublayer:layer];
    }
    return self;
}
@end

@interface CDWItem : NSObject
@property (nonatomic, copy) NSString *key, *title, *detail, *seriesArt;
@property (nonatomic, copy) NSArray<NSDictionary *> *albums, *faces;
@end
@implementation CDWItem @end

@interface CDWCell : NSObject
@property (nonatomic, strong) CDWLayer *root;
@property (nonatomic, strong) NSArray<CDWPlate *> *plates;      // back-most first; the last one is the face
@property (nonatomic, strong) CDWText *title, *detail;
@property (nonatomic) NSInteger index;
@property (nonatomic) NSUInteger faces;
@end
@implementation CDWCell @end

@interface CDWBurstCard : NSObject
@property (nonatomic, strong) CDWLayer *mover, *spinner, *scaler, *tilter;
@property (nonatomic, strong) CDWPlate *plate;
@property (nonatomic, strong) CDWText *caption;
@property (nonatomic, strong) NSDictionary *album;
@property (nonatomic) CGPoint home;
@property (nonatomic) CGFloat tilt, side, cap;
@property (nonatomic) CATransform3D lean;
@end
@implementation CDWBurstCard @end

#pragma mark - Burst layout

static BOOL CDWFree(CGRect r, CGRect bounds, CGRect title, const CGRect *taken, NSUInteger count, NSInteger skip) {
    if (!CGRectContainsRect(bounds, r) || CGRectIntersectsRect(r, title)) return NO;
    for (NSUInteger i = 0; i < count; i++) if ((NSInteger)i != skip && CGRectIntersectsRect(r, taken[i])) return NO;
    return YES;
}
/// Rings of slots around the title, filled from the inside out. A ring that is only partly needed gets its cards
/// spread evenly round it, so the burst stays balanced; slots never overlap each other, the title or the edges.
static NSUInteger CDWPlaceRings(NSUInteger n, CGPoint c, CGRect area, CGRect title, CGFloat bw, CGFloat bh, CDWRandom *rng, CGRect *out) {
    NSUInteger placed = 0;
    CGRect *ring = calloc(1024, sizeof(CGRect));
    for (int k = 0; k < 24 && placed < n; k++) {
        CGFloat rx = title.size.width / 2 + bw / 2 + k * bw * 1.02, ry = title.size.height / 2 + bh / 2 + k * bh * 1.02;
        BOOL enclosing = c.x - rx + bw / 2 < CGRectGetMinX(area) && c.x + rx - bw / 2 > CGRectGetMaxX(area) && c.y - ry + bh / 2 < CGRectGetMinY(area) && c.y + ry - bh / 2 > CGRectGetMaxY(area);
        NSUInteger steps = MIN(1024, (NSUInteger)ceil(2 * M_PI * MAX(rx, ry) / (MIN(bw, bh) * .16)));
        CGFloat t0 = CDWNext(rng) * 2 * M_PI;
        NSUInteger found = 0;
        for (NSUInteger j = 0; j < steps; j++) {
            CGFloat t = t0 + j * 2 * M_PI / steps;
            CGRect r = CGRectMake(c.x + rx * cos(t) - bw / 2, c.y + ry * sin(t) - bh / 2, bw, bh);
            if (!CDWFree(r, area, title, out, placed, -1) || !CDWFree(r, area, title, ring, found, -1)) continue;
            ring[found++] = r;
        }
        NSUInteger need = n - placed;
        if (found <= need) { for (NSUInteger j = 0; j < found; j++) out[placed++] = ring[j]; }
        else for (NSUInteger j = 0; j < need; j++) out[placed++] = ring[(NSUInteger)floor((j + .5) * found / need)];
        if (enclosing) break;
    }
    free(ring);
    return placed;
}
NSArray<NSValue *> *CDWBurstLayout(NSUInteger n, CGPoint origin, CGRect area, CGSize titleSize, NSString *seed, CDWBurstGeometry *geometry) {
    NSMutableArray<NSValue *> *result = [NSMutableArray new];
    CDWBurstGeometry geo = { origin, 0, 0, CGRectZero };
    if (!n || area.size.width < 120 || area.size.height < 120) { if (geometry) *geometry = geo; return result; }
    CGPoint mid = CGPointMake(CGRectGetMidX(area), CGRectGetMidY(area));
    CGFloat target = CDWClamp(sqrt(area.size.width * area.size.height * .19 / n), 96, 280);
    CGRect *slots = calloc(n, sizeof(CGRect));
    CGFloat side = target, cap = 0, gap = 0;
    CGPoint c = origin;
    CGRect title = CGRectZero;
    BOOL done = NO;
    for (int k = 0; k < 28 && !done; k++) {
        side = MAX(44, target * pow(.93, k));
        cap = side >= 128 ? round(MIN(30, 18 + side * .045)) : 0;
        gap = MAX(12, side * .1);
        // Footprint of a card tilted up to ~12°, with breathing room.
        CGFloat bw = side * 1.13 + gap, bh = (side + cap) * 1.08 + gap;
        // The burst stays on the stack; only when there is no room there does it drift towards the middle.
        NSArray *shifts = k < 4 ? @[@0, @.2, @.4] : @[@0, @.2, @.4, @.6, @.8, @1];
        for (NSNumber *shift in shifts) {
            CGFloat f = shift.doubleValue, tw = titleSize.width + 24, th = titleSize.height + 14;
            c = CGPointMake(origin.x + (mid.x - origin.x) * f, origin.y + (mid.y - origin.y) * f);
            c.x = CDWClamp(c.x, CGRectGetMinX(area) + tw / 2, CGRectGetMaxX(area) - tw / 2);
            c.y = CDWClamp(c.y, CGRectGetMinY(area) + th / 2, CGRectGetMaxY(area) - th / 2);
            title = CGRectMake(c.x - tw / 2, c.y - th / 2, tw, th);
            CDWRandom rng = CDWSeeded(seed);
            CGRect bounds = CGRectInset(area, -gap / 2, -gap / 2);
            if (CDWPlaceRings(n, c, bounds, title, bw, bh, &rng, slots) < n) continue;
            // Bounded jitter: a little freedom inside each slot, never into a neighbour.
            for (NSUInteger i = 0; i < n; i++) for (int tries = 0; tries < 3; tries++) {
                CGRect moved = CGRectOffset(slots[i], (CDWNext(&rng) - .5) * side * .16, (CDWNext(&rng) - .5) * side * .12);
                if (CDWFree(moved, bounds, title, slots, n, i)) { slots[i] = moved; break; }
            }
            done = YES;
            break;
        }
    }
    for (NSUInteger i = 0; i < n; i++) [result addObject:CDWPoint(CGPointMake(CGRectGetMidX(slots[i]), CGRectGetMidY(slots[i])))];
    free(slots);
    geo = (CDWBurstGeometry){ c, side, cap, CGRectMake(c.x - titleSize.width / 2, c.y - titleSize.height / 2, titleSize.width, titleSize.height) };
    if (geometry) *geometry = geo;
    return result;
}

#pragma mark - Wall

// The blur wave: four levels of blur follow each other outwards, so every region the ripple has crossed
// goes from lightly to deeply defocused. The deepest level settles two seconds after the click.
static const CFTimeInterval CDWWaveTotal = 2.15;
static const CGFloat CDWWaveDelay[4] = { 0, .12, .24, .36 };
static const CGFloat CDWWaveSweep = 1.76;
static const CGFloat CDWBlurSigma[4] = { 4, 11, 24, 46 };
/// Radius of a blur level's front, as a fraction of the distance to the farthest corner. Nearly constant speed,
/// easing off only at the end, so the ripple visibly takes its two seconds to cross the window.
static CGFloat CDWFront(CGFloat t, NSUInteger level) {
    CGFloat x = CDWClamp((t - CDWWaveDelay[level]) / CDWWaveSweep, 0, 1);
    return (1 - pow(1 - x, 1.18)) * 1.07;
}
static NSArray<NSNumber *> *CDWStops(NSArray<NSNumber *> *raw) {
    NSMutableArray *stops = [NSMutableArray new]; CGFloat last = 0;
    for (NSNumber *n in raw) { CGFloat v = CDWClamp(n.doubleValue, last, 1); [stops addObject:@(v)]; last = v; }
    return stops;
}
static void CDWAnimateStopsFor(CAGradientLayer *layer, CFTimeInterval duration, NSArray<NSNumber *> *(^stopsAt)(CGFloat t)) {
    NSMutableArray *values = [NSMutableArray new];
    NSInteger frames = (NSInteger)ceil(duration * 40);
    for (NSInteger i = 0; i <= frames; i++) [values addObject:CDWStops(stopsAt(duration * i / frames))];
    CDWQuiet(^{ layer.locations = values.lastObject; });
    CAKeyframeAnimation *a = [CAKeyframeAnimation animationWithKeyPath:@"locations"];
    a.values = values; a.duration = duration; a.calculationMode = kCAAnimationLinear;
    [layer addAnimation:a forKey:@"wave"];
}
static void CDWAnimateStops(CAGradientLayer *layer, NSArray<NSNumber *> *(^stopsAt)(CGFloat t)) { CDWAnimateStopsFor(layer, CDWWaveTotal, stopsAt); }

// Coming back from a CD's player page the ripple runs the other way: it closes in from the window's edges on the
// stack, a little quicker, and leaves the same deep blur behind. Fronts go from beyond the corners to past the centre.
static const CFTimeInterval CDWReturnTotal = 1.45;
static CGFloat CDWInFront(CGFloat t, NSUInteger level) {
    CGFloat x = CDWClamp((t - level * .09) / (CDWReturnTotal - .27 - .08), 0, 1);
    return 1.15 * pow(1 - x, 1.45) - .08;
}

@interface CDAlbumWall ()
@property (nonatomic, strong, readwrite) CDBackdropView *backdrop;
@property (nonatomic, strong) NSView *surface;
@property (nonatomic, strong) CDWLayer *gridHost, *clip, *content, *indicator, *blurHost, *burstHost;
@property (nonatomic, strong) CDWGradient *clipMask;
@property (nonatomic, strong) CDWText *heading, *subheading, *emptyTitle, *emptyDetail, *burstTitle, *burstDetail, *notice;
@property (nonatomic, strong) CDSoftButton *scanButton, *archiveButton, *stackButton, *emptyButton, *retryButton;
@property (nonatomic, strong) NSMutableSet<NSString *> *probing;     // disks being asked whether they answer
@property (nonatomic, copy, nullable) NSString *noticeFlash;         // a short "back again" after a retry
@property (nonatomic, copy) NSArray<CDWItem *> *items;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, CDWCell *> *live;
@property (nonatomic, strong) NSMutableArray<CDWCell *> *spare;
@property (nonatomic) NSInteger columns, hoverIndex, pressIndex, burstIndex;
@property (nonatomic) CGFloat cellSide, gap, gridLeft, peek, captionTop, cellHeight, rowPitch, contentPad, contentHeight, clipTop, offset, margin;
@property (nonatomic) NSSize laidOut;
@property (nonatomic) BOOL burstOpen, leaving, ignoreMomentum, needsItems;
@property (nonatomic) NSUInteger token;
@property (nonatomic) NSUInteger showing;     // bumps on every show / hide; a resize or restyle mid-fade must not cancel a hide
@property (nonatomic) BOOL hiding;
@property (nonatomic) CGPoint burstOrigin;
@property (nonatomic, strong) NSMutableArray<CDWBurstCard *> *cards;
@property (nonatomic, weak) CDWBurstCard *hoverCard, *pressCard;
@property (nonatomic, strong) NSMutableDictionary *skinCache, *placeholderCache;
@property (nonatomic, strong) NSTrackingArea *tracking;
@property (nonatomic, copy) NSString *prefetchedKey;
@property (nonatomic, strong) NSArray *prefetchLayers;
@property (nonatomic, strong) CDWBurstCard *launchCard;
@property (nonatomic, strong) NSMutableSet<NSString *> *prefetched;
@end

@implementation CDAlbumWall

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        _albums = @[]; _items = @[]; _grouped = YES;
        _live = [NSMutableDictionary new]; _spare = [NSMutableArray new]; _cards = [NSMutableArray new];
        _skinCache = [NSMutableDictionary new]; _placeholderCache = [NSMutableDictionary new];
        _hoverIndex = _pressIndex = _burstIndex = -1;
        _backdrop = [[CDBackdropView alloc] initWithFrame:self.bounds];
        [self addSubview:_backdrop];
        _surface = [[CDFlippedView alloc] initWithFrame:self.bounds];
        _surface.wantsLayer = YES;
        [self addSubview:_surface];
        CALayer *root = _surface.layer;
        _gridHost = [CDWLayer layer];
        _clip = [CDWLayer layer]; _clip.masksToBounds = YES;
        _clipMask = [CDWGradient layer];
        _clipMask.colors = @[(id)CDWWhite(0).CGColor, (id)CDWWhite(1).CGColor, (id)CDWWhite(1).CGColor, (id)CDWWhite(0).CGColor];
        _clip.mask = _clipMask;
        _content = [CDWLayer layer]; _content.anchorPoint = CGPointZero;
        [_clip addSublayer:_content];
        _heading = [CDWText layer]; _subheading = [CDWText layer]; _notice = [CDWText layer];
        _emptyTitle = [CDWText layer]; _emptyDetail = [CDWText layer];
        for (CDWText *t in @[_heading, _subheading, _notice, _emptyTitle, _emptyDetail]) { t.truncationMode = kCATruncationEnd; [_gridHost addSublayer:t]; }
        _notice.hidden = YES;
        _probing = [NSMutableSet new];
        _emptyDetail.wrapped = YES;
        [_gridHost addSublayer:_clip];
        _indicator = [CDWLayer layer]; _indicator.cornerRadius = 1.5; _indicator.opacity = 0;
        _blurHost = [CDWLayer layer]; _burstHost = [CDWLayer layer];
        _burstTitle = [CDWText layer]; _burstDetail = [CDWText layer];
        for (CDWText *t in @[_burstTitle, _burstDetail]) { t.alignmentMode = kCAAlignmentCenter; t.truncationMode = kCATruncationEnd; t.opacity = 0; [_burstHost addSublayer:t]; }
        for (CALayer *layer in @[_gridHost, _indicator, _blurHost, _burstHost]) [root addSublayer:layer];
        _scanButton = [self actionButton:@"plus" title:@"添加文件夹" action:@selector(scan:)];
        _archiveButton = [self actionButton:@"archivebox" title:@"归档到文件夹…" action:@selector(archive:)];
        _stackButton = [self actionButton:@"square.stack.3d.up" title:@"按番剧堆叠" action:@selector(toggleGrouped:)];
        _emptyButton = [self actionButton:@"folder.badge.plus" title:@"添加文件夹" action:@selector(scan:)];
        _scanButton.toolTip = @"选择一个目录，其中任意层级的音乐 CD 都会加入专辑墙";
        _archiveButton.toolTip = @"选择归档位置，把专辑墙里的 CD 复制过去，原文件留在原处";
        _stackButton.toolTip = @"同一部番的 CD 叠成一摞";
        _stackButton.active = YES;
        _retryButton = [self actionButton:@"arrow.clockwise" title:@"重试" action:@selector(retryVolumes:)];
        _retryButton.toolTip = @"重新连接这块硬盘";
        _retryButton.hidden = YES;
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(volumesChanged:) name:CDVolumesChangedNotification object:nil];
    }
    return self;
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (CDSoftButton *)actionButton:(NSString *)symbol title:(NSString *)title action:(SEL)action {
    CDSoftButton *button = [CDSoftButton buttonWithSymbol:symbol title:title target:self action:action];
    button.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    button.glyphSize = 12;
    button.restOpacity = .72;
    [self addSubview:button];
    return button;
}
- (CGFloat)scale { return self.window.backingScaleFactor ?: NSScreen.mainScreen.backingScaleFactor ?: 2; }
- (NSArray<CDSoftButton *> *)headerButtons { return @[self.scanButton, self.archiveButton, self.stackButton, self.retryButton]; }
- (BOOL)expanded { return self.burstOpen; }
- (NSString *)expandedStackKey {
    if (!self.burstOpen || self.burstIndex < 0 || self.burstIndex >= (NSInteger)self.items.count) return nil;
    CDWItem *item = self.items[self.burstIndex];
    return item.albums.count > 1 ? item.key : nil;
}
- (BOOL)expandStackWithKey:(NSString *)key {
    if (!key.length || self.burstOpen || self.leaving) return NO;
    [self layoutSubtreeIfNeeded];
    for (NSUInteger index = 0; index < self.items.count; index++) {
        CDWItem *item = self.items[index];
        if ([item.key isEqualToString:key] && item.albums.count > 1) {
            if (!self.live[@(index)]) {
                NSInteger row = (NSInteger)index / self.columns;
                CGFloat top = self.contentPad + row * self.rowPitch;
                [self setOffset:CDWClamp(top - self.clipHeight * .3, 0, self.maxOffset)];
            }
            [self burst:(NSInteger)index];
            return self.burstOpen;
        }
    }
    return NO;
}
- (BOOL)returnToStackWithKey:(NSString *)key albumID:(NSString *)albumID page:(CGImageRef)page cover:(NSRect)cover {
    if (!key.length) return NO;
    self.showing++; self.hiding = NO;
    [self resetTransients];
    self.hidden = NO; self.alphaValue = 1;
    [self layoutSubtreeIfNeeded];
    if (self.needsItems) [self refresh];
    [self checkVolumes];
    for (NSUInteger index = 0; index < self.items.count; index++) {
        CDWItem *item = self.items[index];
        if (![item.key isEqualToString:key] || item.albums.count < 2) continue;
        if (!self.live[@(index)]) {
            NSInteger row = (NSInteger)index / self.columns;
            [self setOffset:CDWClamp(self.contentPad + row * self.rowPitch - self.clipHeight * .3, 0, self.maxOffset)];
        }
        NSMutableDictionary *back = [@{@"cover": [NSValue valueWithRect:cover]} mutableCopy];
        if (albumID.length) back[@"album"] = albumID;
        if (page) back[@"page"] = (__bridge id)page;
        [self burst:(NSInteger)index returning:back];
        return self.burstOpen;
    }
    return NO;
}
- (BOOL)pixelStyle { return self.playerStyle == 3; }

#pragma mark Appearance

- (void)setPalette:(CDPalette *)palette {
    if (_palette == palette) return;
    _palette = palette;
    [self.backdrop applyPalette:palette];
    [self.skinCache removeAllObjects]; [self.placeholderCache removeAllObjects];
    [self restyle];
}
- (void)setPlayerStyle:(NSInteger)playerStyle {
    if (_playerStyle == playerStyle) return;
    _playerStyle = playerStyle;
    [self.skinCache removeAllObjects]; [self.placeholderCache removeAllObjects];
    if (self.burstOpen || self.leaving) [self resetTransients];
    [self restyle];
    [self relayoutGrid];
}
- (NSFont *)font:(CGFloat)size weight:(NSFontWeight)weight {
    if (self.playerStyle == 2) return CDLabelFont(round(size * 1.14));
    if (self.playerStyle == 3) return [NSFont monospacedSystemFontOfSize:round(size * .9) weight:weight];
    return [NSFont systemFontOfSize:size weight:weight];
}
- (NSFont *)headingFont:(CGFloat)size {
    if (self.playerStyle == 0) return CDSerifFont(size, NSFontWeightLight);
    if (self.playerStyle == 2) return CDLabelFont(round(size * 1.08));
    if (self.playerStyle == 3) return [NSFont monospacedSystemFontOfSize:round(size * .78) weight:NSFontWeightRegular];
    return [NSFont systemFontOfSize:size weight:NSFontWeightLight];
}
- (void)setText:(CDWText *)layer string:(NSString *)string font:(NSFont *)font color:(NSColor *)color {
    layer.string = string ?: @"";
    layer.font = (__bridge CFTypeRef)font; layer.fontSize = font.pointSize;
    layer.foregroundColor = color.CGColor; layer.contentsScale = self.scale;
}
- (void)restyle {
    CDPalette *p = self.palette;
    if (!p) return;
    NSColor *glow = p.light ? CDMix(p.accent, p.ink, .12) : CDMix(p.ink, p.accent, .35);
    for (CDSoftButton *b in @[self.scanButton, self.archiveButton, self.stackButton, self.emptyButton, self.retryButton]) {
        b.tint = [p ink:p.light ? .78 : .82]; b.glowColor = glow; b.restGlow = b == self.emptyButton ? .35 : 0;
        b.font = [self font:12 weight:NSFontWeightMedium];
    }
    self.indicator.backgroundColor = [p ink:.28].CGColor;
    [self refreshHeader];
    for (CDWCell *cell in self.live.allValues) [self configureCell:cell index:cell.index];
}
- (void)refreshHeader {
    CDPalette *p = self.palette;
    if (!p) return;
    NSUInteger series = 0; NSMutableSet *keys = [NSMutableSet new];
    for (NSDictionary *a in self.albums) [keys addObject:CDWString(a[@"animeKey"]).length ? a[@"animeKey"] : CDWString(a[@"id"])];
    series = keys.count;
    [self setText:self.heading string:@"音乐收藏" font:[self headingFont:32] color:p.ink];
    NSString *counts = self.albums.count ? [NSString stringWithFormat:@"%lu 部作品  ·  %lu 张唱片", (unsigned long)series, (unsigned long)self.albums.count] : @"";
    [self setText:self.subheading string:counts font:[self font:12 weight:NSFontWeightRegular] color:[p ink:p.secondary]];
    [self setText:self.emptyTitle string:@"还没有收藏的 CD" font:[self headingFont:26] color:p.ink];
    [self setText:self.emptyDetail string:@"选择一个文件夹，其中任意层级的音乐 CD 都会按番剧叠放在这里。扫描只建立索引，不移动原文件。" font:[self font:13 weight:NSFontWeightRegular] color:[p ink:p.secondary]];
    self.heading.alignmentMode = self.subheading.alignmentMode = self.notice.alignmentMode = kCAAlignmentLeft;
    self.emptyTitle.alignmentMode = self.emptyDetail.alignmentMode = kCAAlignmentCenter;
    [self refreshNotice];
}

#pragma mark Skins

- (CGRect)artRectForSide:(CGFloat)s {
    switch (self.playerStyle) {
        case 1: { CGFloat spine = round(s * .085), m = MAX(1.5, round(s * .016)); return CGRectMake(spine, m, s - spine - m, s - m * 2); }
        case 2: { CGFloat b = round(s * .052); return CGRectInset(CGRectMake(0, 0, s, s), b, b); }
        case 3: return CGRectInset(CGRectMake(0, 0, s, s), 3, 3);
        default: return CGRectMake(0, 0, s, s);
    }
}
- (CGFloat)cornerForSide:(CGFloat)s {
    switch (self.playerStyle) { case 1: return 3; case 2: return 1.5; case 3: return 0; default: return round(MAX(6, s * .05)); }
}
- (id)skinForSide:(CGFloat)s {
    NSString *key = [NSString stringWithFormat:@"%ld|%.1f", (long)self.playerStyle, s];
    id cached = self.skinCache[key];
    if (cached) return cached == NSNull.null ? nil : cached;
    CGFloat r = [self cornerForSide:s];
    CGRect bounds = CGRectMake(0, 0, s, s), art = [self artRectForSide:s];
    NSInteger style = self.playerStyle;
    BOOL light = self.palette.light;
    CGImageRef image = CDWDraw(bounds.size, self.scale, ^(CGContextRef ctx) {
        CGPathRef outline = CGPathCreateWithRoundedRect(bounds, r, r, NULL);
        if (style == 0) {
            // Glass tile: a soft key light from the top-left and a lit rim.
            CGContextSaveGState(ctx); CGContextAddPath(ctx, outline); CGContextClip(ctx);
            CDWGradientFill(ctx, CGPointMake(0, 0), CGPointMake(s * .72, s * .72), @[CDWWhite(.2), CDWWhite(.05), CDWWhite(0)], @[@0, @.42, @1]);
            CGContextRestoreGState(ctx);
            CGPathRef rim = CGPathCreateWithRoundedRect(CGRectInset(bounds, .5, .5), MAX(0, r - .5), MAX(0, r - .5), NULL);
            CGContextSaveGState(ctx); CGContextAddPath(ctx, rim); CGContextSetLineWidth(ctx, 1); CGContextReplacePathWithStrokedPath(ctx); CGContextClip(ctx);
            CDWGradientFill(ctx, CGPointMake(0, 0), CGPointMake(0, s), @[CDWWhite(.5), CDWWhite(.12), CDWWhite(.2)], @[@0, @.6, @1]);
            CGContextRestoreGState(ctx);
            CGPathRelease(rim);
        } else if (style == 1) {
            // Jewel case: hinged spine with moulded ridges, a clear lid with a raking reflection.
            CGFloat spine = art.origin.x;
            CGContextSaveGState(ctx); CGContextClipToRect(ctx, CGRectMake(0, 0, spine, s));
            CDWGradientFill(ctx, CGPointMake(0, 0), CGPointMake(spine, 0), @[CDWWhite(.1), CDWBlack(.28), CDWBlack(.1), CDWWhite(.14)], @[@0, @.35, @.8, @1]);
            CGContextRestoreGState(ctx);
            for (int k = 0; k < 4; k++) {
                CGFloat x = round(spine * (.24 + k * .16)) + .5;
                CGContextSetStrokeColorWithColor(ctx, CDWWhite(.22).CGColor); CGContextSetLineWidth(ctx, .7);
                CGContextMoveToPoint(ctx, x, s * .07); CGContextAddLineToPoint(ctx, x, s * .93); CGContextStrokePath(ctx);
                CGContextSetStrokeColorWithColor(ctx, CDWBlack(.2).CGColor);
                CGContextMoveToPoint(ctx, x + .9, s * .07); CGContextAddLineToPoint(ctx, x + .9, s * .93); CGContextStrokePath(ctx);
            }
            CGContextSetFillColorWithColor(ctx, CDWWhite(.3).CGColor);
            CGPathRef tab = CGPathCreateWithRoundedRect(CGRectMake(spine * .18, s * .018, spine * .64, s * .04), 1, 1, NULL);
            CGContextAddPath(ctx, tab); CGContextFillPath(ctx); CGPathRelease(tab);
            tab = CGPathCreateWithRoundedRect(CGRectMake(spine * .18, s * .942, spine * .64, s * .04), 1, 1, NULL);
            CGContextAddPath(ctx, tab); CGContextFillPath(ctx); CGPathRelease(tab);
            CGContextSetStrokeColorWithColor(ctx, CDWBlack(.25).CGColor); CGContextSetLineWidth(ctx, .8);
            CGContextStrokeRect(ctx, CGRectInset(art, -.4, -.4));
            CGContextSaveGState(ctx);
            CGContextMoveToPoint(ctx, spine, 0); CGContextAddLineToPoint(ctx, s * .6, 0); CGContextAddLineToPoint(ctx, s * .28, s); CGContextAddLineToPoint(ctx, spine, s); CGContextClosePath(ctx); CGContextClip(ctx);
            CDWGradientFill(ctx, CGPointMake(spine, 0), CGPointMake(s * .55, s * .2), @[CDWWhite(.16), CDWWhite(.05)], @[@0, @1]);
            CGContextRestoreGState(ctx);
            CGContextSetStrokeColorWithColor(ctx, CDWWhite(.62).CGColor); CGContextSetLineWidth(ctx, 1);
            CGContextAddPath(ctx, outline); CGContextStrokePath(ctx);
            CGContextSetStrokeColorWithColor(ctx, CDWWhite(.4).CGColor); CGContextSetLineWidth(ctx, .7);
            CGContextMoveToPoint(ctx, spine - .5, 1); CGContextAddLineToPoint(ctx, spine - .5, s - 1); CGContextStrokePath(ctx);
        } else if (style == 2) {
            // A print on paper: faint fibre along the border and the print's own edge.
            CDWRandom rng = CDWSeeded(@"paper");
            for (int k = 0; k < 90; k++) {
                CGFloat x = CDWNext(&rng) * s, y = CDWNext(&rng) * s;
                if (CGRectContainsPoint(art, CGPointMake(x, y))) continue;
                CGContextSetFillColorWithColor(ctx, CDWBlack(.05 + CDWNext(&rng) * .05).CGColor);
                CGContextFillRect(ctx, CGRectMake(x, y, .8 + CDWNext(&rng) * 2.4, .6));
            }
            CGContextSetStrokeColorWithColor(ctx, CDWBlack(.14).CGColor); CGContextSetLineWidth(ctx, .7);
            CGContextStrokeRect(ctx, CGRectInset(art, -.35, -.35));
            CGContextSaveGState(ctx); CGContextClipToRect(ctx, art);
            CDWGradientFill(ctx, CGPointMake(0, 0), CGPointMake(s * .6, s * .6), @[CDWWhite(.12), CDWWhite(0)], @[@0, @1]);
            CGContextRestoreGState(ctx);
        } else {
            // Pixel frame: a square, ink-bordered sleeve with a hard offset shadow; the art itself stays sharp
            // (only the player's own screen is drawn in dots), with a faint inner edge and a lit top line.
            CGContextSetStrokeColorWithColor(ctx, (light ? CDWBlack(.12) : CDWBlack(.25)).CGColor); CGContextSetLineWidth(ctx, .7);
            CGContextStrokeRect(ctx, CGRectInset(art, .35, .35));
            CGContextSetFillColorWithColor(ctx, CDWWhite(.16).CGColor);
            CGContextFillRect(ctx, CGRectMake(art.origin.x, art.origin.y, art.size.width, 1));
        }
        CGPathRelease(outline);
    });
    id object = image ? CFBridgingRelease(image) : NSNull.null;
    self.skinCache[key] = object;
    return object == NSNull.null ? nil : object;
}
- (id)tapeImageForSide:(CGFloat)s {
    NSString *key = [NSString stringWithFormat:@"tape|%.1f", s];
    if (self.skinCache[key]) return self.skinCache[key];
    CGSize size = CGSizeMake(round(s * .36), round(MAX(9, s * .085)));
    BOOL light = self.palette.light;
    CGImageRef image = CDWDraw(size, self.scale, ^(CGContextRef ctx) {
        CGFloat w = size.width, h = size.height, tooth = h / 5;
        CGContextMoveToPoint(ctx, 0, 0);
        CGContextAddLineToPoint(ctx, w, 0);
        for (int k = 0; k < 5; k++) CGContextAddLineToPoint(ctx, w - (k % 2 ? 0 : 1.6), (k + 1) * tooth);
        CGContextAddLineToPoint(ctx, 0, h);
        for (int k = 4; k >= 0; k--) CGContextAddLineToPoint(ctx, (k % 2 ? 0 : 1.6), k * tooth);
        CGContextClosePath(ctx);
        CGContextSaveGState(ctx); CGContextClip(ctx);
        NSColor *tape = light ? [NSColor colorWithSRGBRed:.94 green:.9 blue:.78 alpha:.86] : [NSColor colorWithSRGBRed:.86 green:.81 blue:.68 alpha:.84];
        CGContextSetFillColorWithColor(ctx, tape.CGColor); CGContextFillRect(ctx, CGRectMake(0, 0, w, h));
        CDWGradientFill(ctx, CGPointMake(0, 0), CGPointMake(0, h), @[CDWWhite(.3), CDWWhite(0), CDWBlack(.06)], @[@0, @.5, @1]);
        CGContextRestoreGState(ctx);
    });
    id object = CFBridgingRelease(image);
    self.skinCache[key] = object;
    return object;
}
/// Sets up a plate for the current style. `depth` > 0 marks sleeves further down a stack.
- (void)stylePlate:(CDWPlate *)plate side:(CGFloat)s depth:(NSUInteger)depth seed:(NSString *)seed {
    NSString *signature = [NSString stringWithFormat:@"%ld|%.1f|%lu|%ld|%@", (long)self.playerStyle, s, (unsigned long)depth, (long)self.palette.index, seed];
    if ([[plate valueForKey:@"cdwSignature"] isEqual:signature]) return;
    [plate setValue:signature forKey:@"cdwSignature"];
    CDPalette *p = self.palette;
    BOOL light = p.light;
    CGFloat r = [self cornerForSide:s];
    CGRect bounds = CGRectMake(0, 0, s, s);
    plate.bounds = bounds;
    plate.cornerRadius = r;
    CGPathRef path = CGPathCreateWithRoundedRect(bounds, r, r, NULL);
    plate.shadowPath = path; CGPathRelease(path);
    plate.shadowColor = CGColorGetConstantColor(kCGColorBlack);
    plate.art.frame = [self artRectForSide:s];
    plate.art.cornerRadius = self.playerStyle == 0 ? r : self.playerStyle == 1 ? 1 : 0;
    plate.art.magnificationFilter = kCAFilterLinear;
    // Still loading: a quiet tint of the theme rather than a blank white tile.
    plate.art.backgroundColor = CDMix(p.surface, p.accent, light ? .16 : .1).CGColor;
    plate.skin.frame = bounds;
    plate.skin.contents = [self skinForSide:s];
    plate.shade.frame = bounds; plate.shade.cornerRadius = r;
    plate.shade.opacity = depth == 0 ? 0 : (light ? .07 : .16) * depth;
    switch (self.playerStyle) {
        case 1:
            plate.backgroundColor = [NSColor colorWithSRGBRed:.1 green:.1 blue:.11 alpha:.9].CGColor;
            plate.shadowOpacity = light ? .3 : .55; plate.shadowRadius = MAX(5, s * .045); plate.shadowOffset = CGSizeMake(0, s * .03);
            break;
        case 2:
            plate.backgroundColor = (light ? [NSColor colorWithSRGBRed:.975 green:.962 blue:.93 alpha:1] : [NSColor colorWithSRGBRed:.9 green:.88 blue:.83 alpha:1]).CGColor;
            plate.shadowOpacity = light ? .22 : .5; plate.shadowRadius = MAX(3, s * .03); plate.shadowOffset = CGSizeMake(0, s * .018);
            break;
        case 3:
            plate.backgroundColor = [p ink:.9].CGColor;
            plate.shadowColor = [p ink:1].CGColor;
            plate.shadowOpacity = .26; plate.shadowRadius = 0; plate.shadowOffset = CGSizeMake(5, 5);
            break;
        default:
            plate.backgroundColor = CDMix(p.surface, p.accent, light ? .16 : .1).CGColor;
            plate.shadowOpacity = light ? .2 : .5; plate.shadowRadius = MAX(6, s * .07); plate.shadowOffset = CGSizeMake(0, s * .045);
            break;
    }
    plate.tape.hidden = self.playerStyle != 2 || depth > 0;
    if (!plate.tape.hidden) {
        CDWRandom rng = CDWSeeded(seed);
        CGSize t = CGSizeMake(round(s * .36), round(MAX(9, s * .085)));
        plate.tape.contents = [self tapeImageForSide:s];
        plate.tape.bounds = CGRectMake(0, 0, t.width, t.height);
        plate.tape.position = CGPointMake(s / 2 + (CDWNext(&rng) - .5) * s * .12, t.height * .18);
        plate.tape.transform = CATransform3DMakeRotation(CDWRad((CDWNext(&rng) - .5) * 9), 0, 0, 1);
    }
}
- (CGImageRef)placeholderFor:(NSString *)title px:(NSInteger)px {
    NSString *key = [NSString stringWithFormat:@"%@|%ld", title, (long)px];
    id cached = self.placeholderCache[key];
    if (cached) return (__bridge CGImageRef)cached;
    CDPalette *p = self.palette;
    NSArray<NSColor *> *aurora = p.aurora.count ? p.aurora : @[p.accent, p.surface];
    NSColor *a = CDMix(p.surface, aurora[0], .55), *b = CDMix(p.base, aurora[MIN(1, aurora.count - 1)], .45);
    NSColor *ink = [p ink:.72];
    CGFloat side = px;
    CGContextRef ctx = CDWBitmap(px, px, YES);
    CDWGradientFill(ctx, CGPointMake(0, side), CGPointMake(side, 0), @[a, b], @[@0, @1]);
    CDWGradientFill(ctx, CGPointMake(0, side), CGPointMake(side * .5, side * .5), @[CDWWhite(.18), CDWWhite(0)], @[@0, @1]);
    NSFont *font = self.playerStyle == 3 ? [NSFont monospacedSystemFontOfSize:round(side * .075) weight:NSFontWeightMedium] : CDSerifFont(round(side * .085), NSFontWeightRegular);
    CDWDrawText(ctx, title, font, ink, CGRectMake(side * .1, side * .3, side * .8, side * .42), NSTextAlignmentCenter, 0);
    CDWDrawText(ctx, @"CD", [NSFont systemFontOfSize:round(side * .045) weight:NSFontWeightMedium], [p ink:.4], CGRectMake(0, side * .1, side, side * .08), NSTextAlignmentCenter, side * .02);
    CGImageRef image = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    self.placeholderCache[key] = CFBridgingRelease(image);
    return image;
}

#pragma mark Art loading

/// Candidate files for one CD, best first: its own sleeve (or the archived copy), then the series key visual.
- (NSArray<NSString *> *)pathsForAlbum:(NSDictionary *)album item:(CDWItem *)item fallbackFrom:(NSUInteger *)fallback {
    NSMutableArray *paths = [NSMutableArray new];
    NSString *cover = CDWString(album[@"coverPath"]), *source = CDWString(album[@"sourcePath"]), *archived = CDWString(album[@"libraryPath"]);
    if (cover.length) [paths addObject:cover];
    if (cover.length && archived.length && source.length && [cover hasPrefix:[source stringByAppendingString:@"/"]])
        [paths addObject:[archived stringByAppendingPathComponent:[cover substringFromIndex:source.length + 1]]];
    *fallback = paths.count;
    for (NSString *p in @[CDWString(album[@"seriesCoverPath"]), item.seriesArt ?: @""]) if (p.length && ![paths containsObject:p]) [paths addObject:p];
    return paths;
}
- (void)loadAlbum:(NSDictionary *)album item:(CDWItem *)item into:(CDWLayer *)art px:(NSInteger)px caption:(nullable NSString *)caption {
    [self loadAlbum:album item:item into:art px:px caption:caption priority:NSOperationQueuePriorityNormal];
}
- (void)loadAlbum:(NSDictionary *)album item:(CDWItem *)item into:(CDWLayer *)art px:(NSInteger)px caption:(nullable NSString *)caption priority:(NSOperationQueuePriority)priority {
    NSUInteger fallback = 0;
    NSArray *paths = [self pathsForAlbum:album item:item fallbackFrom:&fallback];
    NSString *key = [NSString stringWithFormat:@"%@|%ld|%@", [paths componentsJoinedByString:@"\n"], (long)px, caption ?: @""];
    if ([[art valueForKey:@"cdwKey"] isEqual:key] && art.contents) return;
    [(NSOperation *)[art valueForKey:@"cdwOp"] cancel];
    [art setValue:key forKey:@"cdwKey"];
    id cached = [CDWMemory() objectForKey:key];
    if (cached) { art.contents = cached; return; }
    // Show any size already decoded (the grid's, when a stack bursts) while the right one loads.
    art.contents = nil;
    NSString *joined = [paths componentsJoinedByString:@"\n"];
    for (NSNumber *b in @[@640, @512, @384, @256, @160, @96]) {
        id near = [CDWMemory() objectForKey:[NSString stringWithFormat:@"%@|%@|%@", joined, b, caption ?: @""]] ?: [CDWMemory() objectForKey:[NSString stringWithFormat:@"%@|%@|", joined, b]];
        if (near) { art.contents = near; break; }
    }
    NSString *placeholderTitle = CDWString(item.title).length ? item.title : CDWString(album[@"album"]);
    if (!paths.count) { art.contents = (__bridge id)[self placeholderFor:placeholderTitle px:MIN(px, 384)]; return; }
    __weak CDWLayer *weakArt = art;
    __weak typeof(self) weakSelf = self;
    NSBlockOperation *op = [NSBlockOperation new];
    __weak NSBlockOperation *weakOp = op;
    [op addExecutionBlock:^{
        if (weakOp.isCancelled) return;
        CGImageRef image = NULL; BOOL usedFallback = NO;
        for (NSUInteger i = 0; i < paths.count && !image; i++) {
            if (weakOp.isCancelled) return;
            image = CDWThumb(paths[i], px);
            usedFallback = image && i >= fallback;
        }
        if (image && usedFallback) { CGImageRef square = CDWSquareFromTop(image); CGImageRelease(image); image = square; }
        if (image && usedFallback && caption.length) { CGImageRef captioned = CDWCaptioned(image, caption); CGImageRelease(image); image = captioned; }
        id object = image ? CFBridgingRelease(image) : nil;
        if (object) [CDWMemory() setObject:object forKey:key cost:CGImageGetBytesPerRow((__bridge CGImageRef)object) * CGImageGetHeight((__bridge CGImageRef)object)];
        dispatch_async(dispatch_get_main_queue(), ^{
            CDWLayer *target = weakArt;
            if (!target || ![[target valueForKey:@"cdwKey"] isEqual:key]) return;
            CATransition *fade = [CATransition animation]; fade.type = kCATransitionFade; fade.duration = target.contents ? .15 : .28;
            [target addAnimation:fade forKey:@"contents"];
            target.contents = object ?: (__bridge id)[weakSelf placeholderFor:placeholderTitle px:MIN(px, 384)];
            [target setValue:object ? nil : @YES forKey:@"cdwMissing"];
        });
    }];
    op.queuePriority = priority;
    [art setValue:op forKey:@"cdwOp"];
    [CDWQueue() addOperation:op];
}
/// In the background, every CD of the stacks on screen gets its disk thumbnail and a small decoded copy,
/// so a burst shows all its sleeves at once (sharpening a moment later) even straight off an external drive.
- (void)prefetchStacksOnScreen {
    if (!self.prefetched) self.prefetched = [NSMutableSet new];
    for (CDWCell *cell in self.live.allValues) {
        if (cell.index >= (NSInteger)self.items.count) continue;
        CDWItem *item = self.items[cell.index];
        if (item.albums.count < 2 || [self.prefetched containsObject:item.key]) continue;
        [self.prefetched addObject:item.key];
        for (NSDictionary *album in item.albums) {
            NSUInteger fallback = 0;
            NSArray *paths = [self pathsForAlbum:album item:item fallbackFrom:&fallback];
            NSString *key = [NSString stringWithFormat:@"%@|96|", [paths componentsJoinedByString:@"\n"]];
            if (!paths.count || [CDWMemory() objectForKey:key]) continue;
            [CDWIdleQueue() addOperationWithBlock:^{
                CGImageRef image = NULL;
                for (NSUInteger i = 0; i < paths.count && !image; i++) {
                    image = CDWThumb(paths[i], 96);
                    if (image && i >= fallback) { CGImageRef square = CDWSquareFromTop(image); CGImageRelease(image); image = square; }
                }
                if (image) [CDWMemory() setObject:CFBridgingRelease(image) forKey:key cost:96 * 96 * 4];
            }];
        }
    }
}
- (NSInteger)pxForSide:(CGFloat)s { return CDWBucket(s * self.scale); }

#pragma mark Data

- (void)setAlbums:(NSArray<NSDictionary *> *)albums {
    if ([_albums isEqualToArray:albums ?: @[]]) return;
    _albums = [albums ?: @[] copy];
    [self refresh];
}
- (void)setGrouped:(BOOL)grouped {
    if (_grouped == grouped) return;
    _grouped = grouped;
    self.stackButton.active = grouped;
    [self refresh];
}
- (NSArray<CDWItem *> *)buildItems {
    NSMutableDictionary<NSString *, NSMutableArray *> *byKey = [NSMutableDictionary new];
    for (NSDictionary *album in self.albums) {
        NSString *key = CDWString(album[@"animeKey"]);
        if (!key.length || [key isEqualToString:@"unmatched"]) key = [@"album:" stringByAppendingString:CDWString(album[@"id"])];
        if (!byKey[key]) byKey[key] = [NSMutableArray new];
        [byKey[key] addObject:album];
    }
    NSComparator byFolder = ^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [CDWString(a[@"sourcePath"]).lastPathComponent localizedStandardCompare:CDWString(b[@"sourcePath"]).lastPathComponent];
    };
    NSString *(^seriesTitle)(NSArray *) = ^NSString *(NSArray *albums) {
        NSString *title = CDWString([albums.firstObject objectForKey:@"animeTitle"]);
        return title.length ? title : CDWString([albums.firstObject objectForKey:@"album"]);
    };
    NSArray *keys = [byKey.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [seriesTitle(byKey[a]) localizedStandardCompare:seriesTitle(byKey[b])];
    }];
    NSMutableArray<CDWItem *> *items = [NSMutableArray new];
    for (NSString *key in keys) {
        NSArray *albums = [byKey[key] sortedArrayUsingComparator:byFolder];
        NSString *series = @"";
        for (NSDictionary *a in albums) if (CDWString(a[@"seriesCoverPath"]).length) { series = a[@"seriesCoverPath"]; break; }
        if (self.grouped) {
            CDWItem *item = [CDWItem new];
            item.key = key; item.albums = albums; item.seriesArt = series; item.title = seriesTitle(albums);
            item.detail = albums.count > 1 ? [NSString stringWithFormat:@"%lu 张唱片", (unsigned long)albums.count] : CDWString(albums.firstObject[@"album"]);
            // The top of a stack shows real sleeves first; CDs without one fall back to the series visual.
            NSMutableArray *covered = [NSMutableArray new], *bare = [NSMutableArray new];
            for (NSDictionary *a in albums) [CDWString(a[@"coverPath"]).length ? covered : bare addObject:a];
            item.faces = [[covered arrayByAddingObjectsFromArray:bare] subarrayWithRange:NSMakeRange(0, MIN(3, albums.count))];
            [items addObject:item];
        } else for (NSDictionary *album in albums) {
            CDWItem *item = [CDWItem new];
            item.key = CDWString(album[@"id"]); item.albums = @[album]; item.faces = @[album]; item.seriesArt = series;
            item.title = CDWString(album[@"album"]); item.detail = seriesTitle(albums);
            [items addObject:item];
        }
    }
    return items;
}
- (void)refresh {
    if (self.burstOpen || self.leaving) { self.needsItems = YES; return; }
    self.needsItems = NO;
    self.items = [self buildItems];
    [self refreshHeader];
    BOOL empty = self.items.count == 0;
    self.emptyTitle.hidden = self.emptyDetail.hidden = self.emptyButton.hidden = !empty;
    self.archiveButton.hidden = self.stackButton.hidden = empty;
    [self relayoutGrid];
}

#pragma mark Layout

- (void)layout {
    [super layout];
    NSRect b = self.bounds;
    CGFloat W = NSWidth(b), H = NSHeight(b);
    self.backdrop.frame = b; self.surface.frame = b;
    self.margin = round(CDWClamp(W * .05, 28, 84));
    CGFloat m = self.margin;
    CDWQuiet(^{
        for (CALayer *layer in @[self.gridHost, self.blurHost, self.burstHost]) layer.frame = b;
        self.heading.frame = CGRectMake(m - 1, 72, W * .5, 44);
        self.subheading.frame = CGRectMake(m, 118, W * .5, 18);
        CGFloat countsWidth = CDWTextWidth(self.subheading);
        CGFloat noticeX = m + (countsWidth > 0 ? countsWidth + 22 : 0);
        CGFloat noticeWidth = CDWTextWidth(self.notice) + 2;
        self.notice.frame = CGRectMake(noticeX, 118, MIN(noticeWidth, MAX(40, W - noticeX - m - 90)), 18);
        self.clipTop = 128;
        self.clip.frame = CGRectMake(0, self.clipTop, W, MAX(10, H - self.clipTop));
        self.clipMask.frame = self.clip.bounds;
        CGFloat h = NSHeight(self.clip.bounds);
        self.clipMask.locations = @[@0, @(MIN(.3, 30 / h)), @(MAX(.5, 1 - 70 / h)), @1];
        self.emptyTitle.frame = CGRectMake(40, H * .42 - 40, W - 80, 40);
        self.emptyDetail.frame = CGRectMake(W / 2 - 230, H * .42 + 8, 460, 44);
    });
    CGFloat x = W - m, y = 95;
    for (CDSoftButton *button in @[self.stackButton, self.archiveButton, self.scanButton]) {
        CGFloat w = button.contentWidth + 30;
        button.frame = NSIntegralRect(NSMakeRect(x - w, y - 17, w, 34));
        x -= w + 4;
    }
    CGFloat rw = self.retryButton.contentWidth + 26;
    self.retryButton.frame = NSIntegralRect(NSMakeRect(NSMaxX(self.notice.frame) + 6, 127 - 14, rw, 28));
    CGFloat ew = self.emptyButton.contentWidth + 40;
    self.emptyButton.frame = NSIntegralRect(NSMakeRect(W / 2 - ew / 2, H * .42 + 66, ew, 38));
    if (!NSEqualSizes(b.size, self.laidOut)) {
        self.laidOut = b.size;
        // While fading out (the player going full screen as a CD is picked) the cards just leave with the wall.
        if ((self.burstOpen || self.leaving) && !self.hiding) [self resetTransients];
        [self relayoutGrid];
    }
}
- (void)relayoutGrid {
    CGFloat W = NSWidth(self.bounds);
    if (W < 100) return;
    CGFloat m = self.margin;
    self.gap = round(CDWClamp(W * .024, 26, 46));
    CGFloat minCell = 176;
    self.columns = MAX(2, (NSInteger)floor((W - 2 * m + self.gap) / (minCell + self.gap)));
    self.cellSide = floor(MIN(262, (W - 2 * m - (self.columns - 1) * self.gap) / self.columns));
    self.gridLeft = round((W - self.columns * self.cellSide - (self.columns - 1) * self.gap) / 2);
    self.peek = round(self.cellSide * .135);
    self.captionTop = self.peek + self.cellSide + round(self.cellSide * .07);
    self.cellHeight = self.captionTop + 20 + 17;
    self.rowPitch = self.cellHeight + round(self.gap * .8);
    self.contentPad = 26;
    NSInteger rows = (self.items.count + self.columns - 1) / self.columns;
    self.contentHeight = self.contentPad + rows * self.rowPitch + 70;
    CDWQuiet(^{ self.content.bounds = CGRectMake(0, 0, W, self.contentHeight); });
    for (CDWCell *cell in self.live.allValues) [self recycle:cell];
    [self.live removeAllObjects];
    self.hoverIndex = -1;
    [self setOffset:CDWClamp(self.offset, 0, self.maxOffset)];
}
- (CGFloat)clipHeight { return NSHeight(self.clip.bounds); }
- (CGFloat)maxOffset { return MAX(0, self.contentHeight - self.clipHeight); }
- (void)setOffset:(CGFloat)offset {
    _offset = offset;
    [self.content removeAnimationForKey:@"position"];
    CDWQuiet(^{ self.content.position = CGPointMake(0, -offset); });
    [self updateCells];
    [self placeIndicator];
}
- (void)updateCells {
    if (!self.items.count || self.columns < 1) { for (CDWCell *c in self.live.allValues) [self recycle:c]; [self.live removeAllObjects]; return; }
    CGFloat y0 = self.offset - self.rowPitch * .5, y1 = self.offset + self.clipHeight + self.rowPitch * .5;
    NSInteger first = MAX(0, (NSInteger)floor((y0 - self.contentPad) / self.rowPitch));
    NSInteger last = (NSInteger)floor((y1 - self.contentPad) / self.rowPitch);
    NSInteger lo = first * self.columns, hi = MIN((NSInteger)self.items.count - 1, (last + 1) * self.columns - 1);
    for (NSNumber *key in self.live.allKeys) {
        NSInteger index = key.integerValue;
        if (index < lo || index > hi) { [self recycle:self.live[key]]; [self.live removeObjectForKey:key]; }
    }
    for (NSInteger i = lo; i <= hi; i++) {
        if (self.live[@(i)]) continue;
        CDWCell *cell = self.spare.lastObject;
        if (cell) [self.spare removeLastObject]; else cell = [self makeCell];
        [self configureCell:cell index:i];
        self.live[@(i)] = cell;
    }
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(prefetchStacksOnScreen) object:nil];
    [self performSelector:@selector(prefetchStacksOnScreen) withObject:nil afterDelay:.6];
}
- (CDWCell *)makeCell {
    CDWCell *cell = [CDWCell new];
    cell.root = [CDWLayer layer];
    NSMutableArray *plates = [NSMutableArray new];
    for (int i = 0; i < 3; i++) { CDWPlate *plate = [CDWPlate layer]; [cell.root addSublayer:plate]; [plates addObject:plate]; }
    cell.plates = plates;
    cell.title = [CDWText layer]; cell.detail = [CDWText layer];
    for (CDWText *t in @[cell.title, cell.detail]) { t.alignmentMode = kCAAlignmentCenter; t.truncationMode = kCATruncationEnd; [cell.root addSublayer:t]; }
    [self.content addSublayer:cell.root];
    return cell;
}
- (void)recycle:(CDWCell *)cell {
    cell.root.hidden = YES;
    [cell.root removeAllAnimations];
    for (CDWPlate *plate in cell.plates) { [plate removeAllAnimations]; [(NSOperation *)[plate.art valueForKey:@"cdwOp"] cancel]; }
    [self.spare addObject:cell];
}
- (CATransform3D)stackPose:(NSUInteger)depth hover:(BOOL)hover faces:(NSUInteger)faces {
    CGFloat s = self.cellSide, tx = 0, ty = 0, rot = 0, sc = 1;
    if (depth == 0) { if (hover) { ty = -s * .03; sc = faces > 1 ? 1.03 : 1.045; } }
    else if (depth == 1) {
        if (hover) { tx = -s * .15; ty = -s * .025; rot = -9; sc = .95; }
        else { tx = -s * .026; ty = -s * .066; rot = -3.1; sc = .95; }
    } else {
        if (hover) { tx = s * .15; ty = -s * .05; rot = 8; sc = .91; }
        else { tx = s * .03; ty = -s * .118; rot = 3.6; sc = .89; }
    }
    if (self.pixelStyle) { rot = 0; tx = round(tx / 3) * 3; ty = round(ty / 3) * 3; }
    CATransform3D t = CATransform3DMakeScale(sc, sc, 1);
    t = CATransform3DConcat(t, CATransform3DMakeRotation(CDWRad(rot), 0, 0, 1));
    return CATransform3DConcat(t, CATransform3DMakeTranslation(tx, ty, 0));
}
- (void)configureCell:(CDWCell *)cell index:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.items.count) return;
    CDWItem *item = self.items[index];
    CGFloat s = self.cellSide;
    NSInteger row = index / self.columns, col = index % self.columns;
    cell.index = index;
    cell.faces = MIN(3, item.faces.count);
    [cell.root removeAllAnimations];
    cell.root.hidden = NO; cell.root.opacity = 1; cell.root.transform = CATransform3DIdentity;
    cell.root.frame = CGRectMake(self.gridLeft + col * (s + self.gap), self.contentPad + row * self.rowPitch, s, self.cellHeight);
    NSInteger px = [self pxForSide:s];
    for (NSUInteger depth = 0; depth < 3; depth++) {
        CDWPlate *plate = cell.plates[2 - depth];
        [plate removeAllAnimations];
        plate.hidden = depth >= cell.faces;
        if (plate.hidden) continue;
        NSDictionary *album = item.faces[depth];
        [self stylePlate:plate side:s depth:depth seed:CDWString(album[@"id"])];
        plate.position = CGPointMake(s / 2, self.peek + s / 2);
        plate.transform = [self stackPose:depth hover:NO faces:cell.faces];
        // Faces first; the sleeves further down a stack mostly hide behind them.
        [self loadAlbum:album item:item into:plate.art px:px caption:nil priority:depth == 0 ? NSOperationQueuePriorityHigh : NSOperationQueuePriorityLow];
    }
    CDPalette *p = self.palette;
    [self setText:cell.title string:item.title font:[self font:13 weight:NSFontWeightMedium] color:p.ink];
    [self setText:cell.detail string:item.detail font:[self font:11 weight:NSFontWeightRegular] color:[p ink:p.secondary]];
    cell.title.frame = CGRectMake(-6, self.captionTop, s + 12, 20);
    cell.detail.frame = CGRectMake(0, self.captionTop + 21, s, 16);
}
- (void)placeIndicator {
    CGFloat viewport = self.clipHeight, total = self.contentHeight;
    if (total <= viewport + 1) { self.indicator.hidden = YES; return; }
    self.indicator.hidden = NO;
    CGFloat h = MAX(36, viewport * viewport / total), travel = viewport - h - 40;
    CGFloat f = CDWClamp(self.offset / MAX(1, self.maxOffset), 0, 1);
    self.indicator.frame = CGRectMake(NSWidth(self.bounds) - 8, self.clipTop + 20 + travel * f, 3, h);
}
- (void)flashIndicator {
    if (self.indicator.hidden) return;
    [self.indicator removeAnimationForKey:@"opacity"];
    self.indicator.opacity = 1;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(fadeIndicator) object:nil];
    [self performSelector:@selector(fadeIndicator) withObject:nil afterDelay:.9];
}
- (void)fadeIndicator { CDWFade(self.indicator, 0, .5, 0); }

#pragma mark Presenting

- (void)presentAnimated:(BOOL)animated {
    self.showing++; self.hiding = NO;
    [self resetTransients];
    self.hidden = NO;
    [self layoutSubtreeIfNeeded];
    if (self.needsItems) [self refresh];
    [self checkVolumes];
    if (!animated) { self.alphaValue = 1; return; }
    self.alphaValue = 0;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = .3; context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        self.animator.alphaValue = 1;
    }];
    // Cards rise into place row by row, with a little bounce.
    NSInteger firstRow = MAX(0, (NSInteger)floor((self.offset - self.contentPad) / self.rowPitch));
    for (CDWCell *cell in self.live.allValues) {
        NSInteger row = cell.index / self.columns - firstRow, col = cell.index % self.columns;
        if (row < 0 || row > 6) continue;
        CFTimeInterval delay = MIN(.38, row * .06 + col * .028);
        CGPoint p = cell.root.position;
        CDWSpringFrom(cell.root, @"position", CDWPoint(CGPointMake(p.x, p.y + 42)), CDWPoint(p), 170, 15, delay);
        CDWSpringFrom(cell.root, @"transform.scale", @.9, @1, 200, 14, delay);
        cell.root.opacity = 0;
        CDWFade(cell.root, 1, .32, delay);
    }
    for (CALayer *layer in @[self.heading, self.subheading]) {
        CGPoint p = layer.position;
        CDWSpringFrom(layer, @"position", CDWPoint(CGPointMake(p.x, p.y + 14)), CDWPoint(p), 200, 20, 0);
        layer.opacity = 0; CDWFade(layer, 1, .35, 0);
    }
}
- (void)dismissAnimated:(BOOL)animated completion:(void (^)(void))completion {
    self.hoverIndex = -1;
    // Only showing the wall again calls this off. The player going full screen right as a CD is picked resizes the
    // wall mid-fade, and that clears the transients (and their token) — the wall must still go away.
    NSUInteger showing = ++self.showing;
    self.token++;                               // still calls off whatever the cards had scheduled
    self.hiding = YES;
    void (^finish)(void) = ^{
        if (self.showing != showing) return;
        self.hiding = NO;
        self.hidden = YES; self.alphaValue = 1;
        [self resetTransients];
        if (completion) completion();
    };
    if (!animated) { finish(); return; }
    void (^fade)(void) = ^{
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = self.leaving ? .42 : .26;
            context.timingFunction = [CAMediaTimingFunction functionWithName:self.leaving ? kCAMediaTimingFunctionEaseIn : kCAMediaTimingFunctionEaseInEaseOut];
            self.animator.alphaValue = 0;
        } completionHandler:finish];
    };
    // A CD on its way into the player gets a head start before the wall fades.
    if (self.leaving) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ if (self.showing == showing) fade(); });
    else fade();
}
- (void)resetTransients {
    self.token++;
    for (CDWBurstCard *card in self.cards) [card.mover removeFromSuperlayer];
    [self.cards removeAllObjects];
    self.hoverCard = self.pressCard = nil; self.launchCard = nil;
    for (CALayer *layer in [self.blurHost.sublayers copy]) [layer removeFromSuperlayer];
    self.blurHost.opacity = 1;
    self.gridHost.mask = nil; self.gridHost.hidden = NO;
    [self.gridHost removeAllAnimations]; self.gridHost.opacity = 1;
    self.burstTitle.opacity = self.burstDetail.opacity = 0;
    for (CDWCell *cell in self.live.allValues) { cell.root.hidden = NO; cell.root.opacity = 1; }
    for (CDSoftButton *b in self.headerButtons) b.alphaValue = 1;
    self.burstOpen = self.leaving = NO;
    self.burstIndex = -1;
    if (self.needsItems) [self refresh];
}

#pragma mark Hover and clicks

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.tracking) [self removeTrackingArea:self.tracking];
    self.tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect owner:self userInfo:nil];
    [self addTrackingArea:self.tracking];
}
- (NSView *)hitTest:(NSPoint)point {
    NSView *hit = [super hitTest:point];
    if (!hit) return nil;
    if (hit == self.surface || hit == self.backdrop || [hit isDescendantOf:self.backdrop]) return self;
    if (self.burstOpen || self.leaving) return self;       // the header buttons sleep under the blur
    return hit;
}
- (NSInteger)itemAtPoint:(NSPoint)p {
    if (self.burstOpen || self.leaving || p.y < self.clipTop + 6) return -1;
    CGPoint q = CGPointMake(p.x, p.y - self.clipTop + self.offset);
    for (CDWCell *cell in self.live.allValues) {
        CGRect f = cell.root.frame;
        CGRect hot = CGRectMake(f.origin.x - 4, f.origin.y + self.peek * .3, f.size.width + 8, f.size.height - self.peek * .3);
        if (CGRectContainsPoint(hot, q)) return cell.index;
    }
    return -1;
}
- (CDWBurstCard *)cardAtPoint:(NSPoint)p {
    for (CDWBurstCard *card in self.cards.reverseObjectEnumerator) {
        CALayer *mover = card.mover.presentationLayer ?: card.mover;
        CGFloat angle = card == self.hoverCard ? 0 : card.tilt;
        CGFloat dx = p.x - mover.position.x, dy = p.y - mover.position.y;
        CGFloat x = dx * cos(-angle) - dy * sin(-angle), y = dx * sin(-angle) + dy * cos(-angle);
        CGFloat half = card.side / 2 * (card == self.hoverCard ? 1.07 : 1);
        if (fabs(x) <= half && y >= -(card.side + card.cap) / 2 && y <= (card.side + card.cap) / 2) return card;
    }
    return nil;
}
- (void)setHoverIndex:(NSInteger)index {
    if (index == _hoverIndex) return;
    CDWCell *old = _hoverIndex >= 0 ? self.live[@(_hoverIndex)] : nil;
    _hoverIndex = index;
    if (old) [self poseCell:old hover:NO];
    CDWCell *cell = index >= 0 ? self.live[@(index)] : nil;
    if (cell) [self poseCell:cell hover:YES];
    if (cell && cell.faces > 1) {
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [weakSelf prefetchBurst:index]; });
    }
}
- (void)poseCell:(CDWCell *)cell hover:(BOOL)hover {
    for (NSUInteger depth = 0; depth < cell.faces; depth++) {
        CDWPlate *plate = cell.plates[2 - depth];
        CDWSpring(plate, @"transform", CDWT([self stackPose:depth hover:hover faces:cell.faces]), 320, 16, depth * .02);
        if (depth > 0) CDWFade(plate.shade, hover ? plate.shade.opacity * 0 + (self.palette.light ? .03 : .08) * depth : (self.palette.light ? .07 : .16) * depth, .25, 0);
    }
    CDWPlate *face = cell.plates.lastObject;
    CGFloat base = self.playerStyle == 3 ? 0 : MAX(6, self.cellSide * (self.playerStyle == 0 ? .07 : .04));
    if (self.playerStyle != 3) CDWSpring(face, @"shadowRadius", @(hover ? base * 1.6 : base), 300, 22, 0);
}
- (void)pose:(CDWBurstCard *)card hover:(BOOL)hover {
    CDWSpring(card.spinner, @"transform.rotation.z", @(hover ? 0 : card.tilt), 240, 15, 0);
    CDWSpring(card.tilter, @"transform", CDWT(hover ? CATransform3DIdentity : card.lean), 240, 16, 0);
    CDWSpring(card.scaler, @"transform.scale", @(hover ? 1.07 : 1), 320, 15, 0);
    card.mover.zPosition = hover ? 50 : 0;
    CDWFade(card.caption, hover || card.cap > 0 ? 1 : 0, .2, 0);
}
- (void)setHoverCard:(CDWBurstCard *)card {
    if (card == _hoverCard) return;
    CDWBurstCard *old = _hoverCard;
    _hoverCard = card;
    if (old && !self.leaving) [self pose:old hover:NO];
    if (card && !self.leaving) [self pose:card hover:YES];
}
- (void)mouseMoved:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    if (self.leaving) return;
    if (self.burstOpen) { self.hoverCard = [self cardAtPoint:p]; [(self.hoverCard ? NSCursor.pointingHandCursor : NSCursor.arrowCursor) set]; return; }
    self.hoverIndex = [self itemAtPoint:p];
    [(self.hoverIndex >= 0 ? NSCursor.pointingHandCursor : NSCursor.arrowCursor) set];
}
- (void)mouseExited:(NSEvent *)event { self.hoverIndex = -1; if (!self.leaving) self.hoverCard = nil; }
- (void)mouseDown:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    if (self.leaving) return;
    if (self.burstOpen) {
        self.pressCard = [self cardAtPoint:p];
        if (self.pressCard) CDWSpring(self.pressCard.scaler, @"transform.scale", @.95, 600, 28, 0);
        return;
    }
    self.pressIndex = [self itemAtPoint:p];
    CDWCell *cell = self.pressIndex >= 0 ? self.live[@(self.pressIndex)] : nil;
    if (cell) CDWSpring(cell.root, @"transform.scale", @.965, 600, 30, 0);
}
- (void)mouseUp:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    if (self.leaving) return;
    if (self.burstOpen) {
        CDWBurstCard *card = [self cardAtPoint:p], *pressed = self.pressCard;
        self.pressCard = nil;
        if (pressed && card == pressed) { [self launch:card]; return; }
        if (pressed) { [self pose:pressed hover:pressed == self.hoverCard]; return; }
        if (!card) [self collapse];
        return;
    }
    NSInteger index = [self itemAtPoint:p], pressed = self.pressIndex;
    self.pressIndex = -1;
    CDWCell *cell = pressed >= 0 ? self.live[@(pressed)] : nil;
    if (cell) CDWSpring(cell.root, @"transform.scale", @1, 420, 17, 0);
    if (cell && index == pressed) [self activate:pressed];
}
- (void)scrollWheel:(NSEvent *)event {
    if (self.burstOpen || self.leaving || !self.items.count) return;
    self.hoverIndex = -1;
    CGFloat delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 14;
    CGFloat maxOffset = self.maxOffset, next = self.offset - delta;
    BOOL legacy = event.phase == NSEventPhaseNone && event.momentumPhase == NSEventPhaseNone;
    if (event.phase == NSEventPhaseBegan) self.ignoreMomentum = NO;
    if (event.momentumPhase != NSEventPhaseNone && self.ignoreMomentum) return;
    if (legacy) next = CDWClamp(next, 0, maxOffset);
    else if (self.offset < 0 || self.offset > maxOffset) next = self.offset - delta * .3;    // rubber band
    [self setOffset:next];
    [self flashIndicator];
    BOOL outside = self.offset < 0 || self.offset > maxOffset;
    if (outside && event.momentumPhase == NSEventPhaseBegan) { self.ignoreMomentum = YES; [self settle]; }
    else if (outside && (event.phase == NSEventPhaseEnded || event.phase == NSEventPhaseCancelled || event.momentumPhase == NSEventPhaseEnded || event.momentumPhase == NSEventPhaseChanged)) [self settle];
}
- (void)settle {
    CGFloat target = CDWClamp(self.offset, 0, self.maxOffset);
    if (fabs(target - self.offset) < .5) return;
    CGPoint from = ((CALayer *)self.content.presentationLayer ?: self.content).position;
    _offset = target;
    [self updateCells];
    [self placeIndicator];
    CDWSpringFrom(self.content, @"position", CDWPoint(from), CDWPoint(CGPointMake(0, -target)), 260, 26, 0);
}
- (void)activate:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.items.count) return;
    CDWItem *item = self.items[index];
    CDWCell *cell = self.live[@(index)];
    if (!cell) return;
    if (item.albums.count > 1) [self burst:index];
    else [self enterFromCell:cell item:item];
}

#pragma mark Burst

- (CDWBurstCard *)cardFor:(NSDictionary *)album item:(CDWItem *)item side:(CGFloat)side caption:(CGFloat)cap {
    CDWBurstCard *card = [CDWBurstCard new];
    card.album = album; card.side = side; card.cap = cap;
    CGRect box = CGRectMake(0, 0, side, side + cap);
    card.mover = [CDWLayer layer]; card.spinner = [CDWLayer layer]; card.scaler = [CDWLayer layer]; card.tilter = [CDWLayer layer];
    card.mover.bounds = box;
    for (CDWLayer *layer in @[card.spinner, card.scaler, card.tilter]) { layer.bounds = box; layer.position = CGPointMake(side / 2, (side + cap) / 2); }
    [card.mover addSublayer:card.spinner]; [card.spinner addSublayer:card.scaler]; [card.scaler addSublayer:card.tilter];
    CATransform3D perspective = CATransform3DIdentity; perspective.m34 = -1 / (side * 3.4);
    card.scaler.sublayerTransform = perspective;
    card.plate = [CDWPlate layer];
    [self stylePlate:card.plate side:side depth:0 seed:CDWString(album[@"id"])];
    card.plate.position = CGPointMake(side / 2, side / 2);
    [card.tilter addSublayer:card.plate];
    card.caption = [CDWText layer];
    card.caption.alignmentMode = kCAAlignmentCenter; card.caption.truncationMode = kCATruncationEnd;
    [self setText:card.caption string:CDWString(album[@"album"]) font:[self font:11.5 weight:NSFontWeightMedium] color:[self.palette ink:.86]];
    card.caption.frame = CGRectMake(-10, side + 9, side + 20, 17);
    card.caption.opacity = cap > 0 ? 1 : 0;
    [card.tilter addSublayer:card.caption];
    // Under a bare series visual the CD's name is printed on the art itself when there is no room for a caption.
    [self loadAlbum:album item:item into:card.plate.art px:[self pxForSide:side] caption:self.pixelStyle || cap > 0 ? nil : CDWString(album[@"album"])];
    return card;
}
- (NSArray<NSValue *> *)burstSpotsFor:(CDWItem *)item origin:(CGPoint)origin geometry:(CDWBurstGeometry *)geo {
    CGFloat W = NSWidth(self.bounds), H = NSHeight(self.bounds);
    NSFont *titleFont = [self headingFont:28];
    CGFloat titleWidth = MAX(250, MIN(W * .42, ceil([item.title sizeWithAttributes:@{NSFontAttributeName: titleFont}].width) + 8));
    CGRect area = CGRectMake(self.margin * .55, 62, W - self.margin * 1.1, H - 62 - 26);
    return CDWBurstLayout(item.albums.count, origin, area, CGSizeMake(titleWidth, 64), item.key, geo);
}
/// Hovering a stack decodes its CDs at burst size, so they are sharp the moment it opens.
- (void)prefetchBurst:(NSInteger)index {
    if (index != self.hoverIndex || self.burstOpen || index < 0 || index >= (NSInteger)self.items.count) return;
    CDWItem *item = self.items[index];
    CDWCell *cell = self.live[@(index)];
    if (item.albums.count < 2 || !cell || [self.prefetchedKey isEqual:item.key]) return;
    self.prefetchedKey = item.key;
    CDWBurstGeometry geo;
    [self burstSpotsFor:item origin:[self.surface.layer convertPoint:cell.plates.lastObject.position fromLayer:cell.root] geometry:&geo];
    NSMutableArray *layers = [NSMutableArray new];
    for (NSDictionary *album in item.albums) {
        CDWLayer *sink = [CDWLayer layer];
        [self loadAlbum:album item:item into:sink px:[self pxForSide:geo.side] caption:self.pixelStyle || geo.caption > 0 ? nil : CDWString(album[@"album"])];
        [layers addObject:sink];
    }
    self.prefetchLayers = layers;
}
- (void)burst:(NSInteger)index { [self burst:index returning:nil]; }
/// `back` is nil for a click on the stack. Coming back from a player page it carries the album that was playing
/// ("album"), a picture of that page ("page") and where the page showed the cover ("cover", wall coordinates):
/// the page then shrinks back into its CD while the ripple closes in on the stack and the other CDs drift home.
- (void)burst:(NSInteger)index returning:(NSDictionary *)back {
    CDWItem *item = self.items[index];
    CDWCell *cell = self.live[@(index)];
    if (!cell || self.burstOpen) return;
    self.hoverIndex = -1;
    self.burstOpen = YES; self.burstIndex = index;
    NSUInteger token = ++self.token;
    CGFloat W = NSWidth(self.bounds), H = NSHeight(self.bounds);
    CDWPlate *face = cell.plates.lastObject;
    CGPoint origin = [self.surface.layer convertPoint:face.position fromLayer:cell.root];
    self.burstOrigin = origin;

    // Everything but the stack goes into the blur; the stack itself becomes the cards.
    cell.root.hidden = YES;
    NSDictionary *gathered = [self gatherSnapshot];
    if (back) [self startInwardWave:origin]; else [self startWave:origin];
    {
        CGFloat q = [self captureScale];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
            CGImageRef snapshot = CDWDrawSnapshot(gathered);
            NSArray *levels = snapshot ? [self blurLevelsOf:snapshot scale:q] : @[];
            if (snapshot) CGImageRelease(snapshot);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.token != token) return;
                NSArray *layers = [self.blurHost valueForKey:@"cdwLevels"];
                for (NSUInteger i = 0; i < layers.count && i < levels.count; i++) ((CALayer *)layers[i]).contents = levels[i];
            });
        });
    }
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = .2;
        for (CDSoftButton *b in self.headerButtons) b.animator.alphaValue = 0;
    }];

    // Title in the middle of the burst.
    NSFont *titleFont = [self headingFont:28];
    [self setText:self.burstTitle string:item.title font:titleFont color:self.palette.ink];
    [self setText:self.burstDetail string:[NSString stringWithFormat:@"%lu 张唱片   ·   点唱片播放，点空白处收起", (unsigned long)item.albums.count] font:[self font:11.5 weight:NSFontWeightRegular] color:[self.palette ink:self.palette.secondary]];
    CDWBurstGeometry geo;
    NSArray<NSValue *> *spots = [self burstSpotsFor:item origin:origin geometry:&geo];
    CGRect tr = geo.titleRect;
    self.burstTitle.frame = CGRectMake(tr.origin.x - 20, tr.origin.y + 2, tr.size.width + 40, titleFont.pointSize * 1.35);
    self.burstDetail.frame = CGRectMake(tr.origin.x - 60, tr.origin.y + titleFont.pointSize * 1.35 + 10, tr.size.width + 120, 18);
    for (CDWText *t in @[self.burstTitle, self.burstDetail]) {
        if (back) {   // settles in once the page has made room
            CDWSpringFrom(t, @"transform.scale", @1.14, @1, 170, 16, .3);
            CDWFade(t, 1, .4, .28);
            continue;
        }
        CGPoint p = t.position;
        CDWSpringFrom(t, @"position", CDWPoint(CGPointMake(origin.x + (p.x - geo.center.x) * .3, origin.y + (p.y - geo.center.y) * .3)), CDWPoint(p), 150, 15, .08);
        CDWSpringFrom(t, @"transform.scale", @.6, @1, 190, 13, .08);
        CDWFade(t, 1, .35, .1);
    }

    CGFloat gridSide = self.cellSide, side = geo.side, cap = geo.caption;
    NSUInteger n = item.albums.count;
    CGFloat reach = 1;
    for (NSValue *v in spots) reach = MAX(reach, hypot(v.pointValue.x - geo.center.x, v.pointValue.y - geo.center.y));
    NSString *backID = CDWString(back[@"album"]);
    for (NSUInteger i = 0; i < n; i++) {
        NSDictionary *album = item.albums[i];
        CDWBurstCard *card = [self cardFor:album item:item side:side caption:cap];
        CGPoint home = spots[i].pointValue;
        card.home = home;
        CDWRandom rng = CDWSeeded([CDWString(album[@"id"]) stringByAppendingString:@"tilt"]);
        // Bounded randomness: every sleeve still faces the viewer.
        CGFloat sign = CDWNext(&rng) < .5 ? -1 : 1;
        card.tilt = self.pixelStyle ? 0 : sign * CDWRad(3 + CDWNext(&rng) * 9);
        CGFloat around = atan2(home.y - geo.center.y, home.x - geo.center.x);
        card.lean = self.pixelStyle ? CATransform3DIdentity : CATransform3DMakeRotation(CDWRad(8 + CDWNext(&rng) * 7), -sin(around), cos(around), 0);
        if (back) {
            CDWQuiet(^{ card.mover.position = home; });
            [self.burstHost addSublayer:card.mover];
            [self.cards addObject:card];
            if (backID.length && [CDWString(album[@"id"]) isEqualToString:backID]) { [self returnCard:card cover:[back[@"cover"] rectValue] page:back[@"page"]]; continue; }
            // The others drift in toward their places as the ripple closes in, the outermost first.
            CGFloat dx = home.x - geo.center.x, dy = home.y - geo.center.y;
            CFTimeInterval delay = .1 + (1 - CDWClamp(hypot(dx, dy) / reach, 0, 1)) * .3;
            CDWSpringFrom(card.mover, @"position", CDWPoint(CGPointMake(home.x + dx * .3, home.y + dy * .3)), CDWPoint(home), 150, 14.5, delay);
            CDWSpringFrom(card.scaler, @"transform.scale", @1.1, @1, 190, 13, delay);
            CDWSpringFrom(card.spinner, @"transform.rotation.z", @(card.tilt * 1.8), @(card.tilt), 120, 9, delay);
            CDWSpringFrom(card.tilter, @"transform", CDWT(CATransform3DIdentity), CDWT(card.lean), 110, 8, delay + .04);
            card.mover.opacity = 0; CDWFade(card.mover, 1, .24, delay);
            if (cap > 0) { card.caption.opacity = 0; CDWFade(card.caption, 1, .3, delay + .22); }
            continue;
        }
        // Start as the matching sleeve of the stack (or tucked behind it) and fly out.
        NSUInteger depth = [item.faces indexOfObject:album];
        CATransform3D pose = depth != NSNotFound ? [self stackPose:depth hover:NO faces:MIN(3, item.faces.count)] : [self stackPose:2 hover:NO faces:3];
        CGFloat startScale = gridSide / side * (depth != NSNotFound ? sqrt(pose.m11 * pose.m11 + pose.m12 * pose.m12) : .8);
        CGFloat startAngle = atan2(pose.m12, pose.m11);
        CGPoint start = CGPointMake(origin.x + pose.m41, origin.y + pose.m42 + cap / 2 * startScale);
        card.mover.position = start;
        card.mover.zPosition = depth != NSNotFound ? 30 - depth : 0;
        [self.burstHost addSublayer:card.mover];
        [self.cards addObject:card];
        CFTimeInterval delay = MIN(i * .022, .3 * i / MAX(1, n - 1));
        CDWSpringFrom(card.mover, @"position", CDWPoint(start), CDWPoint(home), 150, 12.5, delay);
        CDWSpringFrom(card.scaler, @"transform.scale", @(startScale), @1, 200, 11.5, delay);
        CDWSpringFrom(card.spinner, @"transform.rotation.z", @(startAngle), @(card.tilt), 120, 8.5, delay);
        CDWSpringFrom(card.tilter, @"transform", CDWT(CATransform3DIdentity), CDWT(card.lean), 110, 7.5, delay + .04);
        if (depth == NSNotFound) { card.mover.opacity = 0; CDWFade(card.mover, 1, .16, delay); }
        if (cap > 0) { card.caption.opacity = 0; CDWFade(card.caption, 1, .3, delay + .25); }
    }
    for (CDWBurstCard *card in self.cards) {
        CFTimeInterval settle = .9;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(settle * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ if (self.token == token) card.mover.zPosition = 0; });
    }
    // Once the wave has passed, drop the masks so the finished blur costs nothing to draw.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(((back ? CDWReturnTotal : CDWWaveTotal) + .15) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.token != token) return;
        self.gridHost.hidden = YES;
        NSArray *layers = [self.blurHost valueForKey:@"cdwLevels"];
        for (NSUInteger i = 0; i < layers.count; i++) { CALayer *l = layers[i]; if (i + 1 < layers.count) l.hidden = YES; else l.mask = nil; }
        for (CALayer *l in [self.blurHost valueForKey:@"cdwTransient"]) [l removeFromSuperlayer];
    });
}
- (CGFloat)captureScale { return MIN(.5, 1100 / MAX(1, NSWidth(self.bounds))); }
/// What the grid looks like right now, as plain data: which sleeves, where, with which images.
/// Gathering is quick; drawing it (off the main thread) is -drawSnapshot:.
- (NSDictionary *)gatherSnapshot {
    NSMutableArray *plates = [NSMutableArray new], *texts = [NSMutableArray new];
    CGFloat W = NSWidth(self.bounds), H = NSHeight(self.bounds), top = self.clipTop;
    CGRect visible = CGRectMake(0, self.offset - self.rowPitch, W, self.clipHeight + self.rowPitch * 2);
    for (CDWCell *cell in self.live.allValues) {
        if (cell.root.hidden || !CGRectIntersectsRect(cell.root.frame, visible)) continue;
        CGPoint origin = CGPointMake(cell.root.frame.origin.x, top + cell.root.frame.origin.y - self.offset);
        for (CDWPlate *plate in cell.plates) {
            if (plate.hidden) continue;
            CATransform3D t = plate.transform;
            CGAffineTransform m = CGAffineTransformMake(t.m11, t.m12, t.m21, t.m22, origin.x + plate.position.x + t.m41, origin.y + plate.position.y + t.m42);
            NSMutableDictionary *d = [@{@"m": [NSValue valueWithBytes:&m objCType:@encode(CGAffineTransform)], @"size": [NSValue valueWithSize:plate.bounds.size],
                                        @"radius": @(plate.cornerRadius), @"art": [NSValue valueWithRect:plate.art.frame], @"artRadius": @(plate.art.cornerRadius),
                                        @"shade": @(plate.shade.opacity), @"shadow": @(plate.shadowOpacity)} mutableCopy];
            if (plate.backgroundColor) d[@"bg"] = (__bridge id)plate.backgroundColor;
            if (plate.art.contents) d[@"image"] = plate.art.contents;
            if (plate.skin.contents) d[@"skin"] = plate.skin.contents;
            [plates addObject:d];
        }
        for (CDWText *t in @[cell.title, cell.detail]) {
            CGRect f = CGRectOffset(t.frame, origin.x, origin.y);
            if (t.string) [texts addObject:@{@"string": t.string, @"font": (__bridge id)t.font, @"size": @(t.fontSize), @"color": (__bridge id)t.foregroundColor, @"frame": [NSValue valueWithRect:f], @"center": @YES}];
        }
    }
    for (CDWText *t in @[self.heading, self.subheading]) if (t.string && !t.hidden)
        [texts addObject:@{@"string": t.string, @"font": (__bridge id)t.font, @"size": @(t.fontSize), @"color": (__bridge id)t.foregroundColor, @"frame": [NSValue valueWithRect:t.frame], @"center": @NO}];
    return @{@"plates": plates, @"texts": texts, @"size": [NSValue valueWithSize:NSMakeSize(W, H)], @"clipTop": @(top), @"scale": @([self captureScale]), @"dark": @(!self.palette.light)};
}
static void CDWDrawImageFill(CGContextRef ctx, CGImageRef image, CGRect rect) {
    CGFloat iw = CGImageGetWidth(image), ih = CGImageGetHeight(image), k = MAX(rect.size.width / iw, rect.size.height / ih);
    CGRect fill = CGRectMake(CGRectGetMidX(rect) - iw * k / 2, CGRectGetMidY(rect) - ih * k / 2, iw * k, ih * k);
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, 0, CGRectGetMinY(fill) * 2 + fill.size.height); CGContextScaleCTM(ctx, 1, -1);   // images want y up
    CGContextDrawImage(ctx, fill, image);
    CGContextRestoreGState(ctx);
}
/// The snapshot only ever appears blurred (4 pt and more), so soft offsets stand in for real shadows.
static CGImageRef CDWDrawSnapshot(NSDictionary *snap) CF_RETURNS_RETAINED {
    NSSize size = [snap[@"size"] sizeValue];
    CGFloat q = [snap[@"scale"] doubleValue], top = [snap[@"clipTop"] doubleValue];
    size_t w = ceil(size.width * q), h = ceil(size.height * q);
    CGContextRef ctx = CDWBitmap(w, h, NO);
    if (!ctx) return NULL;
    CGContextTranslateCTM(ctx, 0, h); CGContextScaleCTM(ctx, q, -q);
    CGContextSetInterpolationQuality(ctx, kCGInterpolationLow);
    CGFloat shadowInk = [snap[@"dark"] boolValue] ? .55 : .2;
    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, CGRectMake(0, top, size.width, size.height - top));
    for (NSDictionary *d in snap[@"plates"]) {
        CGAffineTransform m; [d[@"m"] getValue:&m];
        NSSize ps = [d[@"size"] sizeValue];
        CGRect bounds = CGRectMake(-ps.width / 2, -ps.height / 2, ps.width, ps.height);
        CGFloat r = [d[@"radius"] doubleValue];
        CGContextSaveGState(ctx);
        CGContextConcatCTM(ctx, m);
        CGFloat shadow = [d[@"shadow"] doubleValue] * shadowInk;
        for (int k = 1; k <= 3; k++) {
            CGPathRef soft = CGPathCreateWithRoundedRect(CGRectInset(CGRectOffset(bounds, 0, ps.height * .02 * k), -k * 3, -k * 3), r + k * 3, r + k * 3, NULL);
            CGContextSetFillColorWithColor(ctx, CDWBlack(shadow / 3).CGColor); CGContextAddPath(ctx, soft); CGContextFillPath(ctx); CGPathRelease(soft);
        }
        CGPathRef outline = CGPathCreateWithRoundedRect(bounds, r, r, NULL);
        CGContextAddPath(ctx, outline); CGContextClip(ctx); CGPathRelease(outline);
        if (d[@"bg"]) { CGContextSetFillColorWithColor(ctx, (__bridge CGColorRef)d[@"bg"]); CGContextFillRect(ctx, bounds); }
        CGRect art = CGRectOffset([d[@"art"] rectValue], bounds.origin.x, bounds.origin.y);
        if (d[@"image"]) CDWDrawImageFill(ctx, (__bridge CGImageRef)d[@"image"], art);
        if (d[@"skin"]) CDWDrawImageFill(ctx, (__bridge CGImageRef)d[@"skin"], bounds);
        CGFloat shade = [d[@"shade"] doubleValue];
        if (shade > 0) { CGContextSetFillColorWithColor(ctx, CDWBlack(shade).CGColor); CGContextFillRect(ctx, bounds); }
        CGContextRestoreGState(ctx);
    }
    CGContextRestoreGState(ctx);
    NSGraphicsContext *previous = NSGraphicsContext.currentContext;
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:YES];
    for (NSDictionary *t in snap[@"texts"]) {
        NSFont *font = [NSFont fontWithDescriptor:((__bridge NSFont *)(__bridge CFTypeRef)t[@"font"]).fontDescriptor size:[t[@"size"] doubleValue]] ?: [NSFont systemFontOfSize:12];
        NSMutableParagraphStyle *p = [NSMutableParagraphStyle new];
        p.alignment = [t[@"center"] boolValue] ? NSTextAlignmentCenter : NSTextAlignmentLeft; p.lineBreakMode = NSLineBreakByTruncatingTail;
        NSColor *color = [NSColor colorWithCGColor:(__bridge CGColorRef)t[@"color"]] ?: NSColor.grayColor;
        [t[@"string"] drawWithRect:[t[@"frame"] rectValue] options:NSStringDrawingUsesLineFragmentOrigin attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: color, NSParagraphStyleAttributeName: p}];
    }
    NSGraphicsContext.currentContext = previous;
    // The same fades as the scrolling list's edges.
    CGContextSetBlendMode(ctx, kCGBlendModeDestinationIn);
    CGContextSaveGState(ctx); CGContextClipToRect(ctx, CGRectMake(0, top, size.width, 30));
    CDWGradientFill(ctx, CGPointMake(0, top), CGPointMake(0, top + 30), @[CDWWhite(0), CDWWhite(1)], @[@0, @1]);
    CGContextRestoreGState(ctx);
    CGContextSaveGState(ctx); CGContextClipToRect(ctx, CGRectMake(0, size.height - 70, size.width, 70));
    CDWGradientFill(ctx, CGPointMake(0, size.height - 70), CGPointMake(0, size.height), @[CDWWhite(1), CDWWhite(0)], @[@0, @1]);
    CGContextRestoreGState(ctx);
    CGImageRef image = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return image;
}
- (NSArray *)blurLevelsOf:(CGImageRef)snapshot scale:(CGFloat)q {
    static CIContext *context; static dispatch_once_t once;
    dispatch_once(&once, ^{ context = [CIContext contextWithOptions:@{kCIContextCacheIntermediates: @NO, kCIContextOutputColorSpace: (__bridge id)CDWSRGB()}]; });
    CIImage *input = [CIImage imageWithCGImage:snapshot];
    NSMutableArray *levels = [NSMutableArray new];
    for (int i = 0; i < 4; i++) {
        CIImage *blurred = [input imageByApplyingGaussianBlurWithSigma:CDWBlurSigma[i] * q];
        if (i >= 2) blurred = [blurred imageByApplyingFilter:@"CIColorControls" withInputParameters:@{kCIInputSaturationKey: @(1 + .12 * i), kCIInputBrightnessKey: @0}];
        CGImageRef out = [context createCGImage:blurred fromRect:input.extent format:kCIFormatRGBA8 colorSpace:CDWSRGB()];
        [levels addObject:out ? CFBridgingRelease(out) : NSNull.null];
    }
    return levels;
}
- (void)startWave:(CGPoint)o {
    for (CALayer *layer in [self.blurHost.sublayers copy]) [layer removeFromSuperlayer];
    self.blurHost.opacity = 1;
    CGFloat W = NSWidth(self.bounds), H = NSHeight(self.bounds);
    CGFloat reach = 4;
    for (NSValue *v in @[CDWPoint(CGPointZero), CDWPoint(CGPointMake(W, 0)), CDWPoint(CGPointMake(0, H)), CDWPoint(CGPointMake(W, H))])
        reach = MAX(reach, hypot(v.pointValue.x - o.x, v.pointValue.y - o.y) + 4);
    // Masks are placed in the masked layer's own, unflipped space; the ripple's rings are ordinary sublayers.
    CGPoint maskCenter = CGPointMake(o.x, H - o.y);
    CDWGradient *(^radialAt)(NSArray *, CGPoint) = ^CDWGradient *(NSArray *colors, CGPoint center) {
        CDWGradient *g = [CDWGradient layer];
        g.type = kCAGradientLayerRadial; g.startPoint = CGPointMake(.5, .5); g.endPoint = CGPointMake(1, 1);
        g.bounds = CGRectMake(0, 0, reach * 2, reach * 2); g.position = center; g.colors = colors;
        return g;
    };
    CDWGradient *(^radial)(NSArray *) = ^CDWGradient *(NSArray *colors) { return radialAt(colors, maskCenter); };
    id clear = (id)CDWWhite(0).CGColor, white = (id)CDWWhite(1).CGColor;
    CGFloat soft = .1;
    // The sharp grid gives way right behind the crest.
    CDWGradient *sharp = radial(@[clear, white]);
    CDWAnimateStops(sharp, ^NSArray *(CGFloat t) { CGFloat f = CDWFront(t, 0); return @[@(f - .06), @(f)]; });
    self.gridHost.mask = sharp;
    self.gridHost.hidden = NO;
    NSMutableArray *levels = [NSMutableArray new];
    for (NSUInteger k = 0; k < 4; k++) {
        CDWLayer *level = [CDWLayer layer];
        level.frame = self.bounds; level.contentsGravity = kCAGravityResize;
        CDWGradient *mask;
        if (k < 3) {
            mask = radial(@[clear, clear, white, white, clear, clear]);
            CDWAnimateStops(mask, ^NSArray *(CGFloat t) { CGFloat inner = CDWFront(t, k + 1), outer = CDWFront(t, k); return @[@0, @(inner - soft), @(inner), @(outer - soft), @(outer), @1]; });
        } else {
            mask = radial(@[white, white, clear, clear]);
            CDWAnimateStops(mask, ^NSArray *(CGFloat t) { CGFloat f = CDWFront(t, k); return @[@0, @(f - soft), @(f), @1]; });
        }
        level.mask = mask;
        [self.blurHost addSublayer:level];
        [levels addObject:level];
    }
    [self.blurHost setValue:levels forKey:@"cdwLevels"];
    // A veil deepens with the blur, so the burst reads clearly in any theme.
    CDWLayer *veil = [CDWLayer layer];
    veil.frame = self.bounds;
    veil.backgroundColor = (self.palette.light ? [self.palette.base colorWithAlphaComponent:.34] : CDWBlack(.3)).CGColor;
    CDWGradient *veilMask = radial(@[white, clear]);
    CDWAnimateStops(veilMask, ^NSArray *(CGFloat t) { CGFloat f = CDWFront(t, 0); return @[@(f - .3), @(f)]; });
    veil.mask = veilMask;
    veil.opacity = 0; CDWFade(veil, 1, CDWWaveTotal, 0);
    [self.blurHost addSublayer:veil];
    // The ripple itself: a bright crest with a faint trough, and a weaker second ring behind it.
    NSMutableArray *transient = [NSMutableArray new];
    NSColor *crestColor = self.palette.light ? CDWWhite(.9) : CDWWhite(.5);
    NSColor *troughColor = self.palette.light ? [self.palette ink:.07] : CDWBlack(.16);
    for (int ring = 0; ring < 2; ring++) {
        CGFloat strength = ring ? .5 : 1;
        CDWGradient *crest = radialAt(@[clear, clear, (id)[crestColor colorWithAlphaComponent:0].CGColor, (id)[crestColor colorWithAlphaComponent:crestColor.alphaComponent * strength].CGColor, (id)[crestColor colorWithAlphaComponent:0].CGColor, (id)[troughColor colorWithAlphaComponent:troughColor.alphaComponent * strength].CGColor, clear, clear], o);
        CGFloat lag = ring ? .09 : 0;
        CDWAnimateStops(crest, ^NSArray *(CGFloat t) {
            CGFloat f = CDWFront(MAX(0, t - lag), 0) * 1.02;
            return @[@0, @(f - .07), @(f - .045), @(f - .018), @(f - .006), @(f + .004), @(f + .02), @1];
        });
        CAKeyframeAnimation *fade = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
        fade.values = @[@0, @1, @.85, @0]; fade.keyTimes = @[@0, @.04, @.5, @.92]; fade.duration = CDWWaveTotal;
        crest.opacity = 0;
        [crest addAnimation:fade forKey:@"fade"];
        [self.blurHost addSublayer:crest];
        [transient addObject:crest];
    }
    // A soft flash where the stack bursts.
    CDWGradient *flash = [CDWGradient layer];
    flash.type = kCAGradientLayerRadial; flash.startPoint = CGPointMake(.5, .5); flash.endPoint = CGPointMake(1, 1);
    flash.colors = @[(id)CDWWhite(self.palette.light ? .7 : .35).CGColor, clear];
    flash.bounds = CGRectMake(0, 0, self.cellSide * 2.4, self.cellSide * 2.4); flash.position = o;
    CABasicAnimation *grow = [CABasicAnimation animationWithKeyPath:@"transform.scale"]; grow.fromValue = @.3; grow.toValue = @1.6; grow.duration = .55;
    grow.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    flash.opacity = 0;
    CAKeyframeAnimation *pulse = [CAKeyframeAnimation animationWithKeyPath:@"opacity"]; pulse.values = @[@0, @1, @0]; pulse.keyTimes = @[@0, @.18, @1]; pulse.duration = .55;
    [flash addAnimation:grow forKey:@"grow"]; [flash addAnimation:pulse forKey:@"pulse"];
    [self.blurHost addSublayer:flash];
    [transient addObject:flash];
    [self.blurHost setValue:transient forKey:@"cdwTransient"];
}
/// The ripple coming back: it starts beyond the window's edges and closes in on `o`. Everything it has crossed goes
/// from lightly to deeply blurred, as on the way out, so it ends in the same blur the open stack sits on.
- (void)startInwardWave:(CGPoint)o {
    for (CALayer *layer in [self.blurHost.sublayers copy]) [layer removeFromSuperlayer];
    self.blurHost.opacity = 1;
    CGFloat W = NSWidth(self.bounds), H = NSHeight(self.bounds), T = CDWReturnTotal;
    CGFloat reach = 4;
    for (NSValue *v in @[CDWPoint(CGPointZero), CDWPoint(CGPointMake(W, 0)), CDWPoint(CGPointMake(0, H)), CDWPoint(CGPointMake(W, H))])
        reach = MAX(reach, hypot(v.pointValue.x - o.x, v.pointValue.y - o.y) + 4);
    CGPoint maskCenter = CGPointMake(o.x, H - o.y);   // masks live in the masked layer's unflipped space
    CDWGradient *(^radialAt)(NSArray *, CGPoint) = ^CDWGradient *(NSArray *colors, CGPoint center) {
        CDWGradient *g = [CDWGradient layer];
        g.type = kCAGradientLayerRadial; g.startPoint = CGPointMake(.5, .5); g.endPoint = CGPointMake(1, 1);
        g.bounds = CGRectMake(0, 0, reach * 2, reach * 2); g.position = center; g.colors = colors;
        return g;
    };
    id clear = (id)CDWWhite(0).CGColor, white = (id)CDWWhite(1).CGColor;
    CGFloat soft = .1;
    // Inside the front the grid is still sharp; outside it the blur levels follow one another inward.
    CDWGradient *sharp = radialAt(@[white, clear], maskCenter);
    CDWAnimateStopsFor(sharp, T, ^NSArray *(CGFloat t) { CGFloat f = CDWInFront(t, 0); return @[@(f), @(f + .06)]; });
    self.gridHost.mask = sharp;
    self.gridHost.hidden = NO;
    NSMutableArray *levels = [NSMutableArray new];
    for (NSUInteger k = 0; k < 4; k++) {
        CDWLayer *level = [CDWLayer layer];
        level.frame = self.bounds; level.contentsGravity = kCAGravityResize;
        CDWGradient *mask;
        if (k < 3) {
            mask = radialAt(@[clear, clear, white, white, clear, clear], maskCenter);
            CDWAnimateStopsFor(mask, T, ^NSArray *(CGFloat t) { CGFloat inner = CDWInFront(t, k), outer = CDWInFront(t, k + 1); return @[@0, @(inner), @(inner + soft), @(outer), @(outer + soft), @1]; });
        } else {
            mask = radialAt(@[clear, clear, white, white], maskCenter);
            CDWAnimateStopsFor(mask, T, ^NSArray *(CGFloat t) { CGFloat f = CDWInFront(t, k); return @[@0, @(f), @(f + soft), @1]; });
        }
        level.mask = mask;
        [self.blurHost addSublayer:level];
        [levels addObject:level];
    }
    [self.blurHost setValue:levels forKey:@"cdwLevels"];
    CDWLayer *veil = [CDWLayer layer];
    veil.frame = self.bounds;
    veil.backgroundColor = (self.palette.light ? [self.palette.base colorWithAlphaComponent:.34] : CDWBlack(.3)).CGColor;
    CDWGradient *veilMask = radialAt(@[clear, white], maskCenter);
    CDWAnimateStopsFor(veilMask, T, ^NSArray *(CGFloat t) { CGFloat f = CDWInFront(t, 0); return @[@(f), @(f + .3)]; });
    veil.mask = veilMask;
    veil.opacity = 0; CDWFade(veil, 1, T, 0);
    [self.blurHost addSublayer:veil];
    // The crest runs inward: bright on its outer side, a faint trough ahead of it, a weaker ring following.
    NSMutableArray *transient = [NSMutableArray new];
    NSColor *crestColor = self.palette.light ? CDWWhite(.9) : CDWWhite(.5);
    NSColor *troughColor = self.palette.light ? [self.palette ink:.07] : CDWBlack(.16);
    for (int ring = 0; ring < 2; ring++) {
        CGFloat strength = ring ? .5 : 1;
        CDWGradient *crest = radialAt(@[clear, clear, (id)[troughColor colorWithAlphaComponent:troughColor.alphaComponent * strength].CGColor, (id)[crestColor colorWithAlphaComponent:0].CGColor, (id)[crestColor colorWithAlphaComponent:crestColor.alphaComponent * strength].CGColor, (id)[crestColor colorWithAlphaComponent:0].CGColor, clear, clear], o);
        CGFloat lag = ring ? .08 : 0;
        CDWAnimateStopsFor(crest, T, ^NSArray *(CGFloat t) {
            CGFloat f = CDWInFront(MAX(0, t - lag), 0);
            return @[@0, @(f - .02), @(f - .006), @(f + .004), @(f + .018), @(f + .045), @(f + .07), @1];
        });
        CAKeyframeAnimation *fade = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
        fade.values = @[@0, @1, @.85, @0]; fade.keyTimes = @[@0, @.06, @.62, @.95]; fade.duration = T;
        crest.opacity = 0;
        [crest addAnimation:fade forKey:@"fade"];
        [self.blurHost addSublayer:crest];
        [transient addObject:crest];
    }
    // Where it all closes in: a soft glow gathering onto the stack.
    CDWGradient *flash = [CDWGradient layer];
    flash.type = kCAGradientLayerRadial; flash.startPoint = CGPointMake(.5, .5); flash.endPoint = CGPointMake(1, 1);
    flash.colors = @[(id)CDWWhite(self.palette.light ? .6 : .3).CGColor, clear];
    flash.bounds = CGRectMake(0, 0, self.cellSide * 2.4, self.cellSide * 2.4); flash.position = o;
    CABasicAnimation *gather = [CABasicAnimation animationWithKeyPath:@"transform.scale"]; gather.fromValue = @1.8; gather.toValue = @.4; gather.duration = .5;
    gather.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn];
    CAKeyframeAnimation *pulse = [CAKeyframeAnimation animationWithKeyPath:@"opacity"]; pulse.values = @[@0, @1, @0]; pulse.keyTimes = @[@0, @.7, @1]; pulse.duration = .5;
    for (CAAnimation *a in @[gather, pulse]) { a.beginTime = CACurrentMediaTime() + T - .55; a.fillMode = kCAFillModeBackwards; }
    flash.opacity = 0;
    [flash addAnimation:gather forKey:@"gather"]; [flash addAnimation:pulse forKey:@"pulse"];
    [self.blurHost addSublayer:flash];
    [transient addObject:flash];
    [self.blurHost setValue:transient forKey:@"cdwTransient"];
}
/// The CD whose player page we are leaving: the page shrinks back into it, the way the CD grew into the page.
/// Page and CD ride one spring, so the cover on the page and the CD's art stay locked together while they cross-fade.
- (void)returnCard:(CDWBurstCard *)card cover:(NSRect)cover page:(id)page {
    CGFloat W = NSWidth(self.bounds), H = NSHeight(self.bounds);
    if (NSIsEmptyRect(cover)) cover = NSMakeRect(W / 2 - MIN(W, H) * .25, H * .47 - MIN(W, H) * .25, MIN(W, H) * .5, MIN(W, H) * .5);
    CGFloat coverSide = MIN(NSWidth(cover), NSHeight(cover)), startScale = coverSide / card.side;
    CGPoint cc = CGPointMake(NSMidX(cover), NSMidY(cover)), plateHome = CGPointMake(card.home.x, card.home.y - card.cap / 2);
    const CGFloat k = 130, d = 17;
    card.mover.zPosition = 500;
    CDWSpringFrom(card.mover, @"position", CDWPoint(CGPointMake(cc.x, cc.y + card.cap / 2 * startScale)), CDWPoint(card.home), k, d, 0);
    CDWSpringFrom(card.scaler, @"transform.scale", @(startScale), @1, k, d, 0);
    CDWSpringFrom(card.spinner, @"transform.rotation.z", @0, @(card.tilt), k, d, 0);
    CDWSpringFrom(card.tilter, @"transform", CDWT(CATransform3DIdentity), CDWT(card.lean), 110, 9, .18);
    card.caption.opacity = 0;
    if (card.cap > 0) CDWFade(card.caption, 1, .3, .55);
    if (!page) return;
    card.mover.opacity = 0; CDWFade(card.mover, 1, .26, .1);
    // The page turns about the cover's centre (mover) and shrinks about it (sheet), rounding its corners as it goes.
    CDWLayer *mover = [CDWLayer layer], *sheet = [CDWLayer layer];
    CGPoint anchor = CGPointMake(cc.x / W, cc.y / H);
    for (CDWLayer *l in @[mover, sheet]) { l.bounds = CGRectMake(0, 0, W, H); l.anchorPoint = anchor; }
    sheet.position = cc;
    sheet.contents = page; sheet.contentsGravity = kCAGravityResize;
    sheet.masksToBounds = YES;
    [mover addSublayer:sheet];
    mover.zPosition = 499;
    [self.burstHost addSublayer:mover];
    CGFloat endScale = 1 / startScale;
    CDWSpringFrom(mover, @"position", CDWPoint(cc), CDWPoint(plateHome), k, d, 0);
    CDWSpringFrom(mover, @"transform.rotation.z", @0, @(card.tilt), k, d, 0);
    CDWSpringFrom(sheet, @"transform.scale", @1, @(endScale), k, d, 0);
    CABasicAnimation *round = [CABasicAnimation animationWithKeyPath:@"cornerRadius"];
    round.fromValue = @0; round.toValue = @(MAX(card.plate.cornerRadius, card.side * .06) / endScale); round.duration = .45;
    round.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    CDWQuiet(^{ sheet.cornerRadius = [round.toValue doubleValue]; });
    [sheet addAnimation:round forKey:@"cornerRadius"];
    CAKeyframeAnimation *fade = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
    fade.values = @[@1, @1, @0]; fade.keyTimes = @[@0, @.4, @1]; fade.duration = .6;
    fade.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn];
    CDWQuiet(^{ mover.opacity = 0; });
    [mover addAnimation:fade forKey:@"opacity"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(.7 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [mover removeFromSuperlayer]; });
}
- (BOOL)dismissExpansion {
    if (!self.burstOpen || self.leaving) return NO;
    [self collapse];
    return YES;
}
- (void)collapse {
    if (!self.burstOpen || self.leaving) return;
    NSUInteger token = ++self.token;
    self.hoverCard = nil;
    NSInteger index = self.burstIndex;
    CDWItem *item = index >= 0 && index < (NSInteger)self.items.count ? self.items[index] : nil;
    CDWCell *cell = self.live[@(index)];
    CGPoint origin = self.burstOrigin;
    // The sharp grid dissolves back in while the blur fades away.
    self.gridHost.mask = nil; self.gridHost.hidden = NO;
    self.gridHost.opacity = 0;
    CDWFade(self.gridHost, 1, .42, 0);
    CDWFade(self.blurHost, 0, .5, .05);
    CDWFade(self.burstTitle, 0, .18, 0); CDWFade(self.burstDetail, 0, .18, 0);
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = .35;
        for (CDSoftButton *b in self.headerButtons) b.animator.alphaValue = 1;
    }];
    for (CDWBurstCard *card in self.cards) {
        NSUInteger depth = [item.faces indexOfObject:card.album];
        CATransform3D pose = [self stackPose:depth != NSNotFound ? depth : 2 hover:NO faces:MIN(3, item.faces.count)];
        CGFloat endScale = self.cellSide / card.side * (depth != NSNotFound ? sqrt(pose.m11 * pose.m11 + pose.m12 * pose.m12) : .7);
        CGPoint end = CGPointMake(origin.x + pose.m41, origin.y + pose.m42 + card.cap / 2 * endScale);
        card.mover.zPosition = depth != NSNotFound ? 30 - depth : 0;
        CDWSpring(card.mover, @"position", CDWPoint(end), 230, 21, 0);
        CDWSpring(card.scaler, @"transform.scale", @(endScale), 260, 21, 0);
        CDWSpring(card.spinner, @"transform.rotation.z", @(atan2(pose.m12, pose.m11)), 240, 20, 0);
        CDWSpring(card.tilter, @"transform", CDWT(CATransform3DIdentity), 260, 22, 0);
        CDWFade(card.caption, 0, .15, 0);
        if (depth == NSNotFound) CDWFade(card.mover, 0, .22, .12);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(.56 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.token != token) return;
        for (CDWBurstCard *card in self.cards) [card.mover removeFromSuperlayer];
        [self.cards removeAllObjects];
        for (CALayer *layer in [self.blurHost.sublayers copy]) [layer removeFromSuperlayer];
        self.blurHost.opacity = 1;
        if (cell) {
            cell.root.hidden = NO;
            CDWSpringFrom(cell.root, @"transform.scale", @1.05, @1, 380, 14, 0);
        }
        self.burstOpen = NO; self.burstIndex = -1;
        if (self.needsItems) [self refresh];
    });
}
- (void)enterFromCell:(CDWCell *)cell item:(CDWItem *)item {
    CDWPlate *face = cell.plates.lastObject;
    CGPoint center = [self.surface.layer convertPoint:face.position fromLayer:cell.root];
    CDWBurstCard *card = [self cardFor:item.albums.firstObject item:item side:self.cellSide caption:0];
    card.caption.hidden = YES;
    card.home = center; card.lean = CATransform3DIdentity;
    CDWQuiet(^{ card.mover.position = center; });
    [self.burstHost addSublayer:card.mover];
    [self.cards addObject:card];
    cell.root.hidden = YES;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = .2;
        for (CDSoftButton *b in self.headerButtons) b.animator.alphaValue = 0;
    }];
    CDWFade(self.gridHost, 0, .3, 0);
    [self launch:card];
}
/// Picking a CD: it straightens and lifts, the player loads it underneath, and the card then flies into the
/// spot where the player shows the cover (-landLaunchIn:) while the wall hands over.
- (void)launch:(CDWBurstCard *)card {
    if (self.leaving) return;
    self.hoverCard = nil;
    self.leaving = YES;
    self.launchCard = card;
    card.mover.zPosition = 500;
    CGFloat W = NSWidth(self.bounds), H = NSHeight(self.bounds);
    CGPoint middle = card.mover.position;
    // Already on its way to the middle while the player loads the album.
    CGPoint lead = CGPointMake(middle.x + (W / 2 - middle.x) * .45, middle.y + (H * .45 - middle.y) * .45);
    CDWSpring(card.mover, @"position", CDWPoint(lead), 120, 16, 0);
    CDWSpring(card.spinner, @"transform.rotation.z", @0, 220, 15, 0);
    CDWSpring(card.tilter, @"transform", CDWT(CATransform3DIdentity), 220, 17, 0);
    CDWSpring(card.scaler, @"transform.scale", @1.3, 160, 15, 0);
    CDWFade(card.caption, 0, .12, 0);
    for (CDWBurstCard *other in self.cards) {
        if (other == card) continue;
        CGPoint p = other.mover.position;
        CGFloat dx = p.x - middle.x, dy = p.y - middle.y, d = MAX(1, hypot(dx, dy));
        CDWSpring(other.mover, @"position", CDWPoint(CGPointMake(p.x + dx / d * 80, p.y + dy / d * 80)), 170, 18, 0);
        CDWSpring(other.scaler, @"transform.scale", @.8, 200, 20, 0);
        CDWFade(other.mover, 0, .26, 0);
    }
    CDWFade(self.burstTitle, 0, .16, 0); CDWFade(self.burstDetail, 0, .16, 0);
    NSDictionary *album = card.album;
    NSUInteger token = self.token;
    // Let this frame's animations reach the screen before the player starts loading. The player then either lands
    // the card (-landLaunchIn:) or, when the CD's disk does not answer, sends it back (-cancelLaunch).
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.token != token) return;
        if (self.onPlay) self.onPlay(album);
        else if (self.launchCard == card) [self landLaunchIn:NSZeroRect];     // nobody to play it: the middle
    });
    // Should nobody answer at all, the wall must not stay stuck mid-launch.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.token == token && self.launchCard == card) [self cancelLaunch];
    });
}
- (void)cancelLaunch {
    CDWBurstCard *card = self.launchCard;
    if (!card) return;
    self.launchCard = nil;
    self.leaving = NO;
    NSUInteger token = self.token;
    CDWSpring(card.mover, @"position", CDWPoint(card.home), 170, 17, 0);
    CDWSpring(card.scaler, @"transform.scale", @1, 220, 17, 0);
    CDWSpring(card.spinner, @"transform.rotation.z", @(card.tilt), 220, 16, 0);
    CDWSpring(card.tilter, @"transform", CDWT(card.lean), 220, 17, 0);
    if (!self.burstOpen) {
        // A single CD picked straight from the grid goes back into its cell.
        CDWFade(self.gridHost, 1, .3, .05);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ if (self.token == token) [self resetTransients]; });
        return;
    }
    if (card.cap > 0) CDWFade(card.caption, 1, .2, .12);
    for (CDWBurstCard *other in self.cards) {
        if (other == card) continue;
        CDWSpring(other.mover, @"position", CDWPoint(other.home), 170, 18, 0);
        CDWSpring(other.scaler, @"transform.scale", @1, 200, 18, 0);
        CDWFade(other.mover, 1, .25, 0);
    }
    CDWFade(self.burstTitle, 1, .25, .05); CDWFade(self.burstDetail, 1, .25, .05);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ if (self.token == token) card.mover.zPosition = 0; });
}
- (void)landLaunchIn:(NSRect)rect {
    CDWBurstCard *card = self.launchCard;
    if (!card) return;
    self.launchCard = nil;
    CGFloat W = NSWidth(self.bounds), H = NSHeight(self.bounds);
    if (NSIsEmptyRect(rect)) rect = NSMakeRect(W / 2 - MIN(W, H) * .25, H * .47 - MIN(W, H) * .25, MIN(W, H) * .5, MIN(W, H) * .5);
    CGFloat side = MIN(NSWidth(rect), NSHeight(rect));
    CGPoint target = CGPointMake(NSMidX(rect), NSMidY(rect) + card.cap / 2 * side / card.side);
    CDWSpring(card.mover, @"position", CDWPoint(target), 140, 17, 0);
    CDWSpring(card.scaler, @"transform.scale", @(side / card.side), 140, 16, 0);
}

#pragma mark Disks

/// Every disk the CDs live on, by mount point (the internal disk has none).
- (NSArray<NSString *> *)albumDisks {
    NSMutableOrderedSet *roots = [NSMutableOrderedSet new];
    for (NSDictionary *album in self.albums) { NSString *root = CDVolumeRoot(CDWString(album[@"sourcePath"])); if (root) [roots addObject:root]; }
    return roots.array;
}
/// Asks each mounted disk whether it answers (quietly, in the background). One that does not is named in the notice.
- (void)checkVolumes {
    for (NSString *root in self.albumDisks) {
        if (CDVolumeIsSilent(root) || [self.probing containsObject:root]) continue;
        [self.probing addObject:root];
        __weak typeof(self) weakSelf = self;
        CDVolumeRead(root, CDWDiskPatience, ^id{ return [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil]; }, ^(id listing, NSString *silent) {
            [weakSelf.probing removeObject:root];
            [weakSelf refreshNotice];
        });
    }
    [self refreshNotice];
}
- (void)refreshNotice {
    CDPalette *p = self.palette;
    if (!p) return;
    NSArray<NSString *> *silent = CDVolumesSilentAmong(self.albumDisks);
    NSMutableArray *parts = [NSMutableArray new], *waiting = [NSMutableArray new];
    if (self.noticeFlash.length) [parts addObject:self.noticeFlash];
    for (NSString *root in silent) {
        NSString *name = [NSString stringWithFormat:@"「%@」", CDVolumeName(root)];
        if ([self.probing containsObject:root]) [waiting addObject:name];
        else [parts addObject:[name stringByAppendingString:CDVolumeMounted(root) ? @"没有响应，连接可能已中断" : @"未连接"]];
    }
    if (waiting.count) [parts addObject:[NSString stringWithFormat:@"正在重新连接%@…", [waiting componentsJoinedByString:@"、"]]];
    NSString *text = [parts componentsJoinedByString:@"，"];
    BOOL trouble = silent.count > waiting.count;
    if (trouble) text = [text stringByAppendingString:@" · 这些 CD 暂时只能看已缓存的封面，不能播放"];
    self.retryButton.hidden = !trouble;
    self.notice.hidden = !text.length;
    [self setText:self.notice string:text font:[self font:12 weight:NSFontWeightMedium] color:trouble ? [p ink:.86] : [p ink:p.secondary]];
    self.needsLayout = YES;
}
- (void)retryVolumes:(id)sender {
    NSArray<NSString *> *silent = CDVolumesSilentAmong(self.albumDisks);
    if (!silent.count) { [self refreshNotice]; return; }
    for (NSString *root in silent) {
        if ([self.probing containsObject:root]) continue;
        [self.probing addObject:root];
        CDVolumeRetry(root);
        __weak typeof(self) weakSelf = self;
        CDVolumeRead(root, CDWDiskPatience, ^id{ return [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil]; }, ^(id listing, NSString *stillSilent) {
            typeof(self) wall = weakSelf;
            if (!wall) return;
            [wall.probing removeObject:root];
            // Answered but empty or unreadable (the disk is not really there) counts as not answering.
            if (!stillSilent && !listing) CDVolumeMarkSilent(root);
            if (!stillSilent && listing) {
                wall.noticeFlash = [NSString stringWithFormat:@"「%@」已重新连接", CDVolumeName(root)];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ weakSelf.noticeFlash = nil; [weakSelf refreshNotice]; });
            }
            [wall refreshNotice];
        });
    }
    [self refreshNotice];
}
- (void)volumesChanged:(NSNotification *)note {
    [self refreshNotice];
    // Sleeves that fell back to a placeholder while their disk was away are loaded again (on a disk still away
    // that costs nothing: nothing is sent to it).
    BOOL again = NO;
    for (CDWCell *cell in self.live.allValues) for (CDWPlate *plate in cell.plates)
        if ([[plate.art valueForKey:@"cdwMissing"] boolValue]) { [plate.art setValue:nil forKey:@"cdwKey"]; again = YES; }
    if (again) for (CDWCell *cell in self.live.allValues) [self configureCell:cell index:cell.index];
}

#pragma mark Actions

- (void)scan:(id)sender { if (self.onScan) self.onScan(); }
- (void)archive:(id)sender { if (self.onArchive && self.albums.count) self.onArchive(self.albums); }
- (void)toggleGrouped:(id)sender {
    self.grouped = !self.grouped;
    if (self.onGroupedChange) self.onGroupedChange(self.grouped);
}

#pragma mark Test hooks (tests/snapshot.m)

- (void)snapshotExpandGroup:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.items.count) return;
    NSInteger row = index / self.columns;
    CGFloat top = self.contentPad + row * self.rowPitch;
    if (top < self.offset || top + self.rowPitch > self.offset + self.clipHeight) [self setOffset:CDWClamp(top - self.clipHeight * .3, 0, self.maxOffset)];
    [self activate:index];
}
- (void)snapshotExpandTitle:(NSString *)title {
    for (NSUInteger i = 0; i < self.items.count; i++) if ([self.items[i].title containsString:title]) { [self snapshotExpandGroup:i]; return; }
}
- (NSInteger)snapshotRevealTitle:(NSString *)title {
    for (NSUInteger i = 0; i < self.items.count; i++) if ([self.items[i].title containsString:title]) {
        NSInteger row = (NSInteger)i / self.columns;
        CGFloat top = self.contentPad + row * self.rowPitch;
        if (top < self.offset || top + self.rowPitch > self.offset + self.clipHeight) [self setOffset:CDWClamp(top - self.clipHeight * .3, 0, self.maxOffset)];
        return (NSInteger)i;
    }
    return -1;
}
- (void)snapshotHoverItem:(NSInteger)index {
    if (self.burstOpen) self.hoverCard = index >= 0 && index < (NSInteger)self.cards.count ? self.cards[index] : nil;
    else self.hoverIndex = index;
}
- (void)snapshotPickItem:(NSInteger)index { if (self.burstOpen && index >= 0 && index < (NSInteger)self.cards.count) [self launch:self.cards[index]]; }
- (void)snapshotScrollBy:(CGFloat)delta { [self setOffset:CDWClamp(self.offset + delta, 0, self.maxOffset)]; }
@end
