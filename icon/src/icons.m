// CD Glass 图标方案 — renders five 1024² icon studies and a contact sheet.
// clang -fobjc-arc -O2 icons.m -o icons -framework AppKit -framework CoreImage && ./icons <outdir> [letters]
#import <AppKit/AppKit.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>

#define S 1024
static const CGRect kBody = {{100, 100}, {824, 824}};
static const CGFloat kRadius = 185.4;
static const CGRect kFull = {{0, 0}, {S, S}};

#pragma mark - Maths and colour

static inline float clampf(float x, float a, float b) { return x < a ? a : (x > b ? b : x); }
static inline float mixf(float a, float b, float t) { return a + (b - a) * t; }
static inline float smoothf(float e0, float e1, float x) { float t = clampf((x - e0) / (e1 - e0), 0, 1); return t * t * (3 - 2 * t); }
static inline float gauss(float x, float w) { float t = x / w; return expf(-t * t); }
static inline float angdiff(float a, float b) { float d = fmodf(fabsf(a - b), 2 * (float)M_PI); return d > M_PI ? 2 * (float)M_PI - d : d; }
static inline float axisdiff(float a, float b) { float d = fmodf(fabsf(a - b), (float)M_PI); return d > M_PI_2 ? (float)M_PI - d : d; }
static inline float knee(float v) { return v < .82f ? v : .82f + .18f * (1 - expf(-(v - .82f) / .18f)); }

typedef struct { float r, g, b; } RGB;
static inline RGB rgb(float r, float g, float b) { return (RGB){r, g, b}; }
static inline RGB gray(float v) { return (RGB){v, v, v}; }
static inline RGB hex(uint32_t h) { return rgb(((h >> 16) & 255) / 255.f, ((h >> 8) & 255) / 255.f, (h & 255) / 255.f); }
static inline RGB mixc(RGB a, RGB b, float t) { return rgb(mixf(a.r, b.r, t), mixf(a.g, b.g, t), mixf(a.b, b.b, t)); }
static inline RGB mulc(RGB a, RGB b) { return rgb(a.r * b.r, a.g * b.g, a.b * b.b); }
static inline RGB scalec(RGB a, float k) { return rgb(a.r * k, a.g * k, a.b * k); }
static inline RGB addc(RGB a, RGB b) { return rgb(a.r + b.r, a.g + b.g, a.b + b.b); }
static inline RGB screenc(RGB a, RGB b) { return rgb(1 - (1 - a.r) * (1 - b.r), 1 - (1 - a.g) * (1 - b.g), 1 - (1 - a.b) * (1 - b.b)); }
static RGB hsv(float h, float s, float v) {
    h -= floorf(h);
    float f = h * 6; int i = (int)f; f -= i;
    float p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f));
    switch (i % 6) {
        case 0: return rgb(v, t, p);
        case 1: return rgb(q, v, p);
        case 2: return rgb(p, v, t);
        case 3: return rgb(p, q, v);
        case 4: return rgb(t, p, v);
        default: return rgb(v, p, q);
    }
}
/// The housing plastic (#BAA98C by default) and colours derived from it, so the whole shell can be recoloured.
static RGB gShell = {186 / 255.f, 169 / 255.f, 140 / 255.f};
static BOOL ShellDark(void) { return gShell.r * .3f + gShell.g * .59f + gShell.b * .11f < .45f; }
/// t < 0 toward the shell's shadow colour, t > 0 toward its highlight.
static RGB ShellTone(float t) { return t < 0 ? mixc(gShell, rgb(.169f, .129f, .086f), -t) : mixc(gShell, rgb(1, .976f, .933f), t); }
/// I's pale ground inside the window, and the cover sleeve's paper (lit side, far side).
static RGB gGround[2] = {{241 / 255.f, 236 / 255.f, 226 / 255.f}, {217 / 255.f, 208 / 255.f, 191 / 255.f}};
static RGB gPaper[2] = {{242 / 255.f, 237 / 255.f, 227 / 255.f}, {226 / 255.f, 217 / 255.f, 201 / 255.f}};
/// Smoke in the clear case's plastic (0 = water clear), and the disc's rainbow strength for T.
static float gCaseTint = 0, gRainbow = 1;
/// T's slim housing: a thin even bezel all round instead of C's window-and-chin (with an optional small LED under the window).
static BOOL gSlim = NO;
/// How the "01" logo in the bottom bezel is printed: 0 — a pale sage square with dark dots, 1 — one dark ink with the dots left open.
static int gBadge = 1;
/// The ground inside T's window: 0 — plain pale cream, 1 — a pool of light behind the case, 2 — sage LCD backlight with a faint dot grid,
/// 3 — a deeper warm grey a shade off the shell, 4 — the cream with a faint dot grid.
static int gGroundStyle = 2;

static CGColorRef cg(RGB c, CGFloat a) { return (CGColorRef)CFAutorelease(CGColorCreateSRGB(c.r, c.g, c.b, a)); }
static NSColor *ns(RGB c, CGFloat a) { return [NSColor colorWithSRGBRed:c.r green:c.g blue:c.b alpha:a]; }

static inline float hash2(int x, int y, int seed) {
    uint32_t h = (uint32_t)x * 374761393u + (uint32_t)y * 668265263u + (uint32_t)seed * 2246822519u;
    h = (h ^ (h >> 13)) * 1274126177u;
    h ^= h >> 16;
    return (h & 0xffffff) / 16777215.f;
}
static float vnoise(float x, float y, int seed) {
    int xi = (int)floorf(x), yi = (int)floorf(y);
    float fx = x - xi, fy = y - yi;
    fx = fx * fx * (3 - 2 * fx); fy = fy * fy * (3 - 2 * fy);
    return mixf(mixf(hash2(xi, yi, seed), hash2(xi + 1, yi, seed), fx), mixf(hash2(xi, yi + 1, seed), hash2(xi + 1, yi + 1, seed), fx), fy);
}
static float fbm(float x, float y, int seed) {
    float s = 0, a = .5f, n = 0;
    for (int i = 0; i < 5; i++) { s += a * vnoise(x, y, seed + i * 131); n += a; x *= 2.03f; y *= 2.03f; a *= .5f; }
    return s / n;
}

#pragma mark - Bitmaps

/// Premultiplied float RGBA, row 0 at the top (CoreGraphics bitmap order).
typedef struct { int w, h; float *p; } Img;
static Img ImgNew(int w, int h) { return (Img){w, h, calloc((size_t)w * h * 4, sizeof(float))}; }
static void ImgFree(Img im) { free(im.p); }
static inline float *Px(Img im, int i, int j) { return im.p + ((size_t)j * im.w + i) * 4; }
static dispatch_queue_t Q(void) { return dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0); }

/// Pixels per icon unit. Everything is laid out on the 1024 grid; 2 draws the same icon at 2048 px (the app's idle cover).
static CGFloat gScale = 1;
/// A bitmap measured in pixels, for the per-pixel passes.
static CGContextRef NewPx(int w, int h) {
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, w * 4, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    return ctx;
}
/// A canvas measured in icon units.
static CGContextRef NewCtx(int w, int h) {
    CGContextRef ctx = NewPx((int)lround(w * gScale), (int)lround(h * gScale));
    CGContextScaleCTM(ctx, gScale, gScale);
    return ctx;
}
/// Shadows are given in icon units too (Core Graphics takes them in pixels, whatever the transform).
static void ShadowInUnits(CGContextRef ctx, CGSize offset, CGFloat blur, CGColorRef color) {
    CGContextSetShadowWithColor(ctx, CGSizeMake(offset.width * gScale, offset.height * gScale), blur * gScale, color);
}
#define CGContextSetShadowWithColor ShadowInUnits
static CGImageRef CtxImage(CGContextRef ctx) { CGImageRef im = CGBitmapContextCreateImage(ctx); CGContextRelease(ctx); return im; }

static Img ImgFromCG(CGImageRef image) {
    int w = (int)CGImageGetWidth(image), h = (int)CGImageGetHeight(image);
    CGContextRef ctx = NewPx(w, h);
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), image);
    uint8_t *d = CGBitmapContextGetData(ctx);
    Img im = ImgNew(w, h);
    for (size_t i = 0; i < (size_t)w * h * 4; i++) im.p[i] = d[i] / 255.f;
    CGContextRelease(ctx);
    return im;
}
static CGImageRef ImgToCG(Img im) {
    CGContextRef ctx = NewPx(im.w, im.h);
    uint8_t *d = CGBitmapContextGetData(ctx);
    dispatch_apply((size_t)im.h, Q(), ^(size_t j) {
        for (int i = 0; i < im.w; i++) {
            size_t k = (j * im.w + i) * 4;
            float dither = hash2(i, (int)j, 99) - .5f;
            uint8_t a = (uint8_t)roundf(clampf(im.p[k + 3], 0, 1) * 255);
            for (int c = 0; c < 3; c++) d[k + c] = (uint8_t)clampf(roundf(im.p[k + c] * 255 + dither), 0, a);
            d[k + 3] = a;
        }
    });
    return CtxImage(ctx);
}
static void Sample(Img im, float x, float y, float o[4]) {   // CG coordinates, y up
    float fx = clampf(x - .5f, 0, im.w - 1.001f), fy = clampf((im.h - y) - .5f, 0, im.h - 1.001f);
    int x0 = (int)fx, y0 = (int)fy;
    float tx = fx - x0, ty = fy - y0;
    const float *a = Px(im, x0, y0), *b = a + 4, *c = a + (size_t)im.w * 4, *d = c + 4;
    for (int k = 0; k < 4; k++) o[k] = mixf(mixf(a[k], b[k], tx), mixf(c[k], d[k], tx), ty);
}

static CIContext *CICtx(void) {
    static CIContext *c;
    if (!c) {
        CGColorSpaceRef sp = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        c = [CIContext contextWithOptions:@{kCIContextOutputColorSpace: (__bridge id)sp}];
        CGColorSpaceRelease(sp);
    }
    return c;
}
static CGImageRef Blur(CGImageRef image, CGFloat sigma) {
    CIImage *ci = [CIImage imageWithCGImage:image];
    CGRect extent = ci.extent;
    CIImage *out = [[[ci imageByClampingToExtent] imageByApplyingGaussianBlurWithSigma:sigma * gScale] imageByCroppingToRect:extent];
    return [CICtx() createCGImage:out fromRect:extent];
}
static CGImageRef Adjust(CGImageRef image, CGFloat saturation, CGFloat brightness, CGFloat contrast) {
    CIFilter *f = [CIFilter filterWithName:@"CIColorControls"];
    CIImage *ci = [CIImage imageWithCGImage:image];
    [f setValue:ci forKey:kCIInputImageKey];
    [f setValue:@(saturation) forKey:kCIInputSaturationKey];
    [f setValue:@(brightness) forKey:kCIInputBrightnessKey];
    [f setValue:@(contrast) forKey:kCIInputContrastKey];
    return [CICtx() createCGImage:f.outputImage fromRect:ci.extent];
}
static CGImageRef Grain(CGImageRef image, float amount, int seed) {
    Img im = ImgFromCG(image);
    dispatch_apply((size_t)im.h, Q(), ^(size_t j) {
        for (int i = 0; i < im.w; i++) {
            float *p = Px(im, i, (int)j);
            float n = (hash2(i, (int)j, seed) - .5f) * amount + (hash2(i >> 1, (int)j >> 1, seed + 1) - .5f) * amount * .6f;
            for (int c = 0; c < 3; c++) p[c] += n * p[3];
        }
    });
    CGImageRef out = ImgToCG(im);
    ImgFree(im);
    return out;
}
static CGImageRef Downscale(CGImageRef image, int size) {
    CGImageRef cur = CGImageRetain(image);
    int w = (int)CGImageGetWidth(image);
    while (w / 2 >= size * 2) {
        w /= 2;
        CGContextRef ctx = NewPx(w, w);
        CGContextDrawImage(ctx, CGRectMake(0, 0, w, w), cur);
        CGImageRelease(cur);
        cur = CtxImage(ctx);
    }
    CGContextRef ctx = NewPx(size, size);
    CGContextDrawImage(ctx, CGRectMake(0, 0, size, size), cur);
    CGImageRelease(cur);
    return CtxImage(ctx);
}
static void SavePNG(CGImageRef image, NSString *path) {
    CGImageDestinationRef d = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], CFSTR("public.png"), 1, NULL);
    CGImageDestinationAddImage(d, image, NULL);
    CGImageDestinationFinalize(d);
    CFRelease(d);
}

#pragma mark - Drawing helpers

static void Corner(CGMutablePathRef p, CGPoint c, CGPoint u, CGPoint v, CGFloat r) {
#define CP(a, b) CGPointMake(c.x + (u.x * (a) + v.x * (b)) * r, c.y + (u.y * (a) + v.y * (b)) * r)
    CGPoint s = CP(-1.52866483, 0);
    CGPathAddLineToPoint(p, NULL, s.x, s.y);
    CGPoint a1 = CP(-1.08849323, 0), a2 = CP(-0.86840689, 0), a3 = CP(-0.66993427, 0.06549600);
    CGPathAddCurveToPoint(p, NULL, a1.x, a1.y, a2.x, a2.y, a3.x, a3.y);
    CGPoint b1 = CP(-0.36745881, 0.17546665), b2 = CP(-0.17546665, 0.36745881), b3 = CP(-0.06549600, 0.66993427);
    CGPathAddCurveToPoint(p, NULL, b1.x, b1.y, b2.x, b2.y, b3.x, b3.y);
    CGPoint c1 = CP(0, 0.86840689), c2 = CP(0, 1.08849323), c3 = CP(0, 1.52866483);
    CGPathAddCurveToPoint(p, NULL, c1.x, c1.y, c2.x, c2.y, c3.x, c3.y);
#undef CP
}
/// Rounded rect with Apple's continuous corners.
static CGPathRef Squircle(CGRect r, CGFloat rad) {
    rad = MIN(rad, MIN(r.size.width, r.size.height) / 2 / 1.52866483);
    CGFloat x0 = CGRectGetMinX(r), x1 = CGRectGetMaxX(r), y0 = CGRectGetMinY(r), y1 = CGRectGetMaxY(r);
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, x0 + 1.52866483 * rad, y1);
    Corner(p, CGPointMake(x1, y1), CGPointMake(1, 0), CGPointMake(0, -1), rad);
    Corner(p, CGPointMake(x1, y0), CGPointMake(0, -1), CGPointMake(-1, 0), rad);
    Corner(p, CGPointMake(x0, y0), CGPointMake(-1, 0), CGPointMake(0, 1), rad);
    Corner(p, CGPointMake(x0, y1), CGPointMake(0, 1), CGPointMake(1, 0), rad);
    CGPathCloseSubpath(p);
    return p;
}
static CGPathRef Circle(CGPoint c, CGFloat r) { return CGPathCreateWithEllipseInRect(CGRectMake(c.x - r, c.y - r, r * 2, r * 2), NULL); }

static CGGradientRef MakeGradient(int n, const RGB *cols, const float *alphas, const CGFloat *locs) {
    CGFloat comps[64];
    for (int i = 0; i < n; i++) { comps[i * 4] = cols[i].r; comps[i * 4 + 1] = cols[i].g; comps[i * 4 + 2] = cols[i].b; comps[i * 4 + 3] = alphas[i]; }
    CGColorSpaceRef sp = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGGradientRef g = CGGradientCreateWithColorComponents(sp, comps, locs, n);
    CGColorSpaceRelease(sp);
    return g;
}
static void Linear(CGContextRef ctx, CGPoint a, CGPoint b, int n, const RGB *cols, const float *alphas, const CGFloat *locs) {
    CGGradientRef g = MakeGradient(n, cols, alphas, locs);
    CGContextDrawLinearGradient(ctx, g, a, b, kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
    CGGradientRelease(g);
}
static void Grad2(CGContextRef ctx, CGPoint a, CGPoint b, RGB c0, float a0, RGB c1, float a1) {
    RGB cols[2] = {c0, c1}; float al[2] = {a0, a1}; CGFloat locs[2] = {0, 1};
    Linear(ctx, a, b, 2, cols, al, locs);
}
static void Radial(CGContextRef ctx, CGPoint c, CGFloat r, RGB c0, float a0, RGB c1, float a1) {
    RGB cols[2] = {c0, c1}; float al[2] = {a0, a1}; CGFloat locs[2] = {0, 1};
    CGGradientRef g = MakeGradient(2, cols, al, locs);
    CGContextDrawRadialGradient(ctx, g, c, 0, c, r, kCGGradientDrawsAfterEndLocation);
    CGGradientRelease(g);
}
static void Blob(CGContextRef ctx, CGPoint c, CGFloat r, RGB col, float alpha) {
    RGB cols[3] = {col, col, col}; float al[3] = {alpha, alpha * .45f, 0}; CGFloat locs[3] = {0, .55, 1};
    CGGradientRef g = MakeGradient(3, cols, al, locs);
    CGContextDrawRadialGradient(ctx, g, c, 0, c, r, 0);
    CGGradientRelease(g);
}
static void FillPath(CGContextRef ctx, CGPathRef path, RGB c, CGFloat a) {
    CGContextAddPath(ctx, path); CGContextSetFillColorWithColor(ctx, cg(c, a)); CGContextFillPath(ctx);
}
static void StrokePath(CGContextRef ctx, CGPathRef path, RGB c, CGFloat a, CGFloat width) {
    CGContextAddPath(ctx, path); CGContextSetLineWidth(ctx, width); CGContextSetStrokeColorWithColor(ctx, cg(c, a)); CGContextStrokePath(ctx);
}
/// Where the key light comes from: NO — the top (all studies up to U), YES — the left (T and U after the relight).
static BOOL gLeft = NO;

/// Shadow (or light) cast inward from the edge of `path`, offset (dx, dy): negative dy lines the top edge, positive dx the left.
static void InnerShadowXY(CGContextRef ctx, CGPathRef path, CGFloat dx, CGFloat dy, CGFloat blur, CGColorRef color) {
    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, path);
    CGContextClip(ctx);
    CGMutablePathRef outside = CGPathCreateMutable();
    CGFloat pad = blur * 4 + fabs(dx) + fabs(dy) + 20;
    CGPathAddRect(outside, NULL, CGRectInset(CGPathGetBoundingBox(path), -pad, -pad));
    CGPathAddPath(outside, NULL, path);
    CGContextSetShadowWithColor(ctx, CGSizeMake(dx, dy), blur, color);
    CGContextAddPath(ctx, outside);
    CGContextSetFillColorWithColor(ctx, cg(gray(0), 1));
    CGContextEOFillPath(ctx);
    CGPathRelease(outside);
    CGContextRestoreGState(ctx);
}
static void InnerShadow(CGContextRef ctx, CGPathRef path, CGFloat dy, CGFloat blur, CGColorRef color) {
    InnerShadowXY(ctx, path, 0, dy, blur, color);
}
/// The same inner shadow, turned to follow the key light: `dy` is given as if lit from the top.
static void InnerShadowLit(CGContextRef ctx, CGPathRef path, CGFloat dy, CGFloat blur, CGColorRef color) {
    if (gLeft) InnerShadowXY(ctx, path, -dy, 0, blur, color); else InnerShadowXY(ctx, path, 0, dy, blur, color);
}
/// A gradient across `r` from the lit side (c0) to the far side (c1).
static void LitGrad(CGContextRef ctx, CGRect r, RGB c0, float a0, RGB c1, float a1) {
    if (gLeft) Grad2(ctx, CGPointMake(r.origin.x, 0), CGPointMake(CGRectGetMaxX(r), 0), c0, a0, c1, a1);
    else Grad2(ctx, CGPointMake(0, CGRectGetMaxY(r)), CGPointMake(0, r.origin.y), c0, a0, c1, a1);
}
static CGSize DrawText(CGContextRef ctx, NSString *s, NSFont *font, NSColor *color, CGFloat kern, CGPoint center) {
    NSGraphicsContext *prev = NSGraphicsContext.currentContext;
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:NO];
    NSAttributedString *a = [[NSAttributedString alloc] initWithString:s attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: color, NSKernAttributeName: @(kern)}];
    CGFloat w = a.size.width - kern;
    [a drawAtPoint:NSMakePoint(center.x - w / 2, center.y - font.capHeight / 2 + font.descender)];
    NSGraphicsContext.currentContext = prev;
    return CGSizeMake(w, font.capHeight);
}

/// The squircle with its drop shadow and a thin rim light.
static CGImageRef Finish(CGImageRef content, BOOL light) {
    CGContextRef ctx = NewCtx(S, S);
    CGPathRef shape = Squircle(kBody, kRadius);
    CGContextSaveGState(ctx);
    CGContextSetShadowWithColor(ctx, CGSizeMake(0, -10), 22, cg(gray(0), light ? .24 : .34));
    FillPath(ctx, shape, gray(.5), 1);
    CGContextRestoreGState(ctx);
    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, shape);
    CGContextClip(ctx);
    CGContextDrawImage(ctx, kFull, content);
    CGContextAddPath(ctx, shape);
    CGContextSetLineWidth(ctx, 4);
    CGContextReplacePathWithStrokedPath(ctx);
    CGContextClip(ctx);
    LitGrad(ctx, kBody, gray(1), light ? .62 : .30, gray(1), light ? .14 : .05);
    CGContextRestoreGState(ctx);
    if (light) StrokePath(ctx, shape, gray(0), .10, 1.2);
    CGPathRelease(shape);
    return CtxImage(ctx);
}

#pragma mark - The silver disc (A, D)

/// `rainbow`: strength of the diffraction colours; 0 means the full default strength.
typedef struct { float R, lobe, sheen, light, rainbow; } DiscSpec;

static void DiscSample(DiscSpec s, float x, float y, float o[4]) {
    o[0] = o[1] = o[2] = o[3] = 0;
    float d = hypotf(x, y), r = d / s.R;
    if (r > 1 || r < .148f) return;
    float th = atan2f(y, x);
    float sh = .5f + .5f * cosf(2 * (th - s.sheen));
    float L = .64f + .22f * sh + .035f * cosf(4 * (th - s.sheen) + .9f);
    float rb = s.rainbow > 0 ? s.rainbow : 1;
    float lobeA = gauss(axisdiff(th, s.lobe), .40f) * rb;
    float lobeB = gauss(axisdiff(th, s.lobe + (float)M_PI_2), .20f) * .35f * rb;
    RGB c; float a = 1;
    if (r < .282f) {                                   // clear hub
        c = gray(.96f);
        a = .16f + .10f * sh + .55f * gauss(r - .154f, .007f) + .35f * gauss(r - .276f, .006f);
    } else if (r < .300f) {                            // stacking ring
        float lit = .5f + .5f * cosf(th - s.light);
        c = gray(.50f + .32f * lit); a = .96f;
    } else if (r < .392f) {                            // mirror band
        float L2 = .72f + .25f * sh;
        c = rgb(L2 * .97f, L2 * .98f, L2);
        c = mixc(c, hsv(.62f - (r - .3f) * 2.f + .05f * sinf(th * 2), .45f, 1), .22f * lobeA);
    } else if (r < .404f) {                            // where the data starts
        c = gray(.50f + .12f * sh);
    } else if (r < .968f) {                            // data
        float t = (r - .404f) / (.968f - .404f);
        float ring = (hash2((int)(d / gScale * 1.7f), 7, 3) - .5f) * .03f;   // the same rings at any scale
        c = rgb(L * .95f + ring, L * .965f + ring, L * .99f + ring);
        RGB rain = hsv(.82f - t * .98f + .05f * sinf(th * 3), .72f, 1);
        c = mixc(c, scalec(rain, .55f + .45f * L), .62f * lobeA);
        c = mixc(c, hsv(.36f + t * .9f, .55f, .95f), .5f * lobeB);
        c = mixc(c, mulc(c, hsv(th / (2 * (float)M_PI) * 2 + r * .7f, .22f, 1)), .5f * rb);
        c = addc(c, gray(.32f * gauss(axisdiff(th, s.lobe), .09f) * gauss(r - .64f, .2f) * (.5f + .5f * rb)));
    } else {                                           // clear outer rim
        c = gray(.93f);
        a = .30f + .22f * sh + .6f * gauss(r - .996f, .004f) * (.5f + .5f * cosf(th - s.light));
    }
    a = clampf(a, 0, 1);
    o[0] = clampf(c.r, 0, 1) * a; o[1] = clampf(c.g, 0, 1) * a; o[2] = clampf(c.b, 0, 1) * a; o[3] = a;
}

static CGImageRef RenderDisc(DiscSpec spec, int *size) {
    int units = (int)ceilf(spec.R * 2) + 4, n = (int)lround(units * gScale);
    DiscSpec s = spec; s.R *= gScale;
    Img im = ImgNew(n, n);
    float c0 = n / 2.f;
    dispatch_apply((size_t)n, Q(), ^(size_t j) {
        for (int i = 0; i < n; i++) {
            float acc[4] = {0}, o[4];
            for (int sy = 0; sy < 3; sy++) for (int sx = 0; sx < 3; sx++) {
                DiscSample(s, i + (sx + .5f) / 3 - c0, (n - (float)j) - (sy + .5f) / 3 - c0, o);
                for (int k = 0; k < 4; k++) acc[k] += o[k];
            }
            float *p = Px(im, i, (int)j);
            for (int k = 0; k < 4; k++) p[k] = acc[k] / 9;
        }
    });
    CGImageRef out = ImgToCG(im);
    ImgFree(im);
    *size = units;
    return out;
}

#pragma mark - A 玻璃槽: a disc standing in a frosted glass block

static CGImageRef IconA(void) {
    CGContextRef ctx = NewCtx(S, S);
    Grad2(ctx, CGPointMake(0, S), CGPointMake(0, 0), hex(0x1f1a38), 1, hex(0x0a0b15), 1);
    Blob(ctx, CGPointMake(280, 820), 330, hex(0xd8467c), .62);
    Blob(ctx, CGPointMake(800, 760), 300, hex(0x22a8c4), .52);
    Blob(ctx, CGPointMake(660, 360), 280, hex(0xf3a04a), .40);
    Blob(ctx, CGPointMake(320, 330), 320, hex(0x6a45da), .48);
    CGImageRef bg = Blur(CtxImage(ctx), 50);

    DiscSpec spec = {296, 2.25f, .55f, 2.3f};
    int n; CGImageRef disc = RenderDisc(spec, &n);
    CGPoint dc = CGPointMake(512, 508);
    CGRect dr = CGRectMake(dc.x - n / 2.0, dc.y - n / 2.0, n, n);

    ctx = NewCtx(S, S);
    CGContextDrawImage(ctx, kFull, bg);
    CGContextSaveGState(ctx);
    CGContextSetShadowWithColor(ctx, CGSizeMake(0, -24), 50, cg(gray(0), .6));
    CGContextDrawImage(ctx, dr, disc);
    CGContextRestoreGState(ctx);
    CGImageRef scene = CtxImage(ctx);
    CGImageRef frost = Adjust(Blur(scene, 24), 1.35, -.05, 1);

    CGFloat top = 396, face = 16, slot = top + face * .55;
    ctx = NewCtx(S, S);
    CGContextDrawImage(ctx, kFull, scene);
    // front face: the disc seen through smoked, frosted glass
    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, CGRectMake(0, 0, S, top));
    CGContextDrawImage(ctx, CGRectOffset(kFull, 0, 10), frost);
    CGContextSetFillColorWithColor(ctx, cg(hex(0x141222), .26)); CGContextFillRect(ctx, kFull);
    Grad2(ctx, CGPointMake(0, top), CGPointMake(0, top - 60), gray(1), .12, gray(1), 0);
    Grad2(ctx, CGPointMake(0, 100), CGPointMake(0, 280), gray(0), .30, gray(0), 0);
    { RGB w[5] = {gray(1), gray(1), gray(1), gray(1), gray(1)}; float al[5] = {0, 0, .07, 0, 0}; CGFloat lc[5] = {0, .40, .47, .56, 1};
      Linear(ctx, CGPointMake(100, 100), CGPointMake(924, 600), 5, w, al, lc); }
    CGContextRestoreGState(ctx);
    // top face; the disc stands in a slot and hides the back half of it
    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, CGRectMake(0, top, S, face));
    CGContextDrawImage(ctx, kFull, frost);
    CGContextSetFillColorWithColor(ctx, cg(gray(1), .24)); CGContextFillRect(ctx, kFull);
    CGContextSetFillColorWithColor(ctx, cg(gray(1), .32)); CGContextFillRect(ctx, CGRectMake(0, top + face - .6, S, 1.2));
    CGContextClipToRect(ctx, CGRectMake(0, slot, S, top + face - slot));
    CGContextDrawImage(ctx, dr, disc);
    CGContextRestoreGState(ctx);
    CGFloat half = sqrt(MAX(0, pow(spec.R - 3, 2) - pow(slot - dc.y, 2)));
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextMoveToPoint(ctx, dc.x - half, slot); CGContextAddLineToPoint(ctx, dc.x + half, slot);
    CGContextSetLineWidth(ctx, 4); CGContextSetStrokeColorWithColor(ctx, cg(gray(0), .5)); CGContextStrokePath(ctx);
    CGContextMoveToPoint(ctx, dc.x - half + 4, slot - 2.6); CGContextAddLineToPoint(ctx, dc.x + half - 4, slot - 2.6);
    CGContextSetLineWidth(ctx, 1.2); CGContextSetStrokeColorWithColor(ctx, cg(gray(1), .45)); CGContextStrokePath(ctx);
    // the front edge catches the light
    { RGB w[3] = {gray(1), gray(1), gray(1)}; float al[3] = {.35, .85, .35}; CGFloat lc[3] = {0, .5, 1};
      CGContextSaveGState(ctx); CGContextClipToRect(ctx, CGRectMake(0, top - 1.2, S, 2.2));
      Linear(ctx, CGPointMake(100, 0), CGPointMake(924, 0), 3, w, al, lc); CGContextRestoreGState(ctx); }
    return Finish(Grain(CtxImage(ctx), .02f, 11), NO);
}

#pragma mark - B 玻璃唱片: a frosted glass disc in the macOS 26 Liquid Glass manner

static RGB GlassColor(Img B, Img Bb, CGPoint dc, float R, float x, float y) {
    float dx = x - dc.x, dy = y - dc.y, d = hypotf(dx, dy), r = d / R, px[4];
    if (r > 1 || r < .16f) { Sample(B, x, y, px); return rgb(px[0], px[1], px[2]); }
    float ux = dx / d, uy = dy / d, th = atan2f(dy, dx);
    float slope = 0;
    if (r > .84f) { float t = (r - .84f) / .16f; slope = t * t; }
    else if (r < .25f) { float t = (.25f - r) / .09f; slope = -t * t; }
    const float disp[3] = {1.0f, 1.10f, 1.22f};
    float ch[3];
    for (int k = 0; k < 3; k++) { float o = slope * 70 * disp[k]; Sample(Bb, x - ux * o, y - uy * o, px); ch[k] = px[k]; }
    RGB c = rgb(ch[0], ch[1], ch[2]);
    BOOL data = r > .315f && r < .835f;
    c = mixc(c, gray(1), data ? .46f : r < .315f ? .30f : .36f);
    if (data) {
        float t = (r - .315f) / (.835f - .315f);
        c = mixc(c, hsv(.86f - t * .95f, .55f, 1), .40f * gauss(axisdiff(th, 2.25f), .42f));
        c = mixc(c, hsv(.36f + t * .8f, .45f, 1), .14f * gauss(axisdiff(th, 2.25f + (float)M_PI_2), .22f));
    }
    c = scalec(c, 1 - .16f * gauss(r - .972f, .014f) - .10f * gauss(r - .19f, .012f));
    c = mixc(c, gray(1), .45f * gauss((r - .315f) * R, 1.2f) + .45f * gauss((r - .835f) * R, 1.2f));
    const float L = 2.3f;
    float facing = .5f + .5f * cosf(th - L), back = .5f + .5f * cosf(th - L - (float)M_PI);
    float spec = gauss((r - .993f) * R, 1.8f) * (.35f + .65f * facing)
               + .85f * gauss(angdiff(th, L), .55f) * gauss(r - .945f, .02f)
               + .40f * gauss(angdiff(th, L + (float)M_PI), .45f) * gauss(r - .95f, .018f)
               + gauss((r - .166f) * R, 1.6f) * (.3f + .6f * back);
    return mixc(c, gray(1), clampf(spec, 0, 1));
}

static CGImageRef IconB(void) {
    CGContextRef ctx = NewCtx(S, S);
    Grad2(ctx, CGPointMake(160, 930), CGPointMake(880, 100), hex(0x7fb0ff), 1, hex(0xa77ff0), 1);
    Blob(ctx, CGPointMake(860, 860), 380, hex(0x7fe6ff), .85);
    Blob(ctx, CGPointMake(200, 180), 400, hex(0xff9fd0), .85);
    Blob(ctx, CGPointMake(820, 200), 320, hex(0x8a6cf0), .60);
    Blob(ctx, CGPointMake(260, 760), 300, hex(0xa9c8ff), .55);
    Img B = ImgFromCG(Blur(CtxImage(ctx), 50));
    CGPoint dc = {512, 530}; float R = 292; CGPoint sc = {dc.x + 10, dc.y - 38};
    // the disc's soft shadow on the backdrop
    dispatch_apply(S, Q(), ^(size_t j) {
        for (int i = 0; i < S; i++) {
            float x = i + .5f, y = S - (float)j - .5f, ds = hypotf(x - sc.x, y - sc.y) / R;
            float shade = .34f * (1 - smoothf(.80f, 1.16f, ds));
            float *p = Px(B, i, (int)j);
            RGB c = rgb(p[0], p[1], p[2]);
            c = mixc(c, mulc(c, rgb(.42f, .36f, .66f)), shade);
            p[0] = c.r; p[1] = c.g; p[2] = c.b;
        }
    });
    Img Bb = ImgFromCG(Blur(ImgToCG(B), 16));
    Img out = ImgNew(S, S);
    memcpy(out.p, B.p, sizeof(float) * S * S * 4);
    int x0 = (int)(dc.x - R - 3), x1 = (int)(dc.x + R + 3), y0 = (int)(dc.y - R - 3), y1 = (int)(dc.y + R + 3);
    dispatch_apply((size_t)(y1 - y0), Q(), ^(size_t k) {
        int j = S - y1 + (int)k;
        for (int i = x0; i < x1; i++) {
            RGB acc = gray(0);
            for (int sy = 0; sy < 3; sy++) for (int sx = 0; sx < 3; sx++)
                acc = addc(acc, GlassColor(B, Bb, dc, R, i + (sx + .5f) / 3, (S - j) - (sy + .5f) / 3));
            acc = scalec(acc, 1 / 9.f);
            float *p = Px(out, i, j);
            p[0] = acc.r; p[1] = acc.g; p[2] = acc.b; p[3] = 1;
        }
    });
    CGImageRef content = ImgToCG(out);
    ImgFree(B); ImgFree(Bb); ImgFree(out);
    return Finish(Grain(content, .016f, 12), YES);
}

#pragma mark - C 点阵屏: the 0.12.1 housing as the whole icon

/// A cassette in the middle of the screen: 20 × 12 dots, a window with two reels, the head area below.
static BOOL LCDCassette(int col, int row) {
    if (row < 10 || row > 21 || col < 8 || col > 27) return NO;
    BOOL edgeRow = row == 10 || row == 21, edgeCol = col == 8 || col == 27;
    if (edgeRow && edgeCol) return NO;                                            // rounded corners
    if (edgeRow || edgeCol) return YES;
    if ((row == 12 || row == 17) && col >= 11 && col <= 24) return YES;           // tape window
    if ((col == 11 || col == 24) && row >= 12 && row <= 17) return YES;
    for (int k = 0; k < 2; k++) {                                                 // reels
        float d = hypotf(col - (k ? 20.5f : 14.5f), row - 14.5f);
        if (d >= .9f && d <= 1.9f) return YES;
    }
    if (row == 19 && col >= 12 && col <= 23) return YES;                          // head area
    if (row == 20 && (col == 11 || col == 24 || col == 15 || col == 20)) return YES;
    if ((row == 11 || row == 20) && (col == 9 || col == 26)) return YES;          // screws
    return NO;
}

static BOOL LCDOn(int col, int row, BOOL cassette) {   // 36 × 26, row 0 at the top
    if (cassette && LCDCassette(col, row)) return YES;
    if (row >= 2 && row <= 6) {
        int w = 3 - abs(row - 4);
        if (col >= 2 && col < 2 + w) return YES;                                  // ▶
        static const char *digits[2][5] = {{"111", "101", "101", "101", "111"}, {"010", "110", "010", "010", "111"}};
        for (int k = 0; k < 2; k++) {                                             // 01
            int c0 = 7 + k * 4;
            if (col >= c0 && col < c0 + 3 && digits[k][row - 2][col - c0] == '1') return YES;
        }
        for (int k = 0; k < 4; k++) if (col == 26 + k * 2 && row > 6 - (2 + k)) return YES;   // volume
    }
    if (row == 8 && col >= 2 && col <= 33) return YES;
    float dx = col - 17.5f, dy = 15.5f - row, d = hypotf(dx, dy);
    if (!cassette && d <= 6.3f && d >= 1.0f) {
        float a = atan2f(dy, dx) * 180 / (float)M_PI;
        return !(d >= 2.6f && d <= 5.3f && a >= 120 && a <= 150);                 // the disc and its glint
    }
    if (row == 24 && col >= 2 && col <= 33) return col <= 13 || col % 2 == 1;     // progress
    return NO;
}

/// The khaki shell filling the squircle: bead-blasted texture, rolled edge, parting line.
static void DrawShellBody(CGContextRef ctx) {
    RGB base = gShell, warmLight = mixc(hex(0xFFF4E2), gShell, .1f), warmShade = mixc(hex(0x2B2116), scalec(gShell, .22f), .5f);
    const int P = (int)lround(S * gScale);
    const float u = 1 / gScale;
    Img sh = ImgNew(P, P);
    BOOL left = gLeft;
    dispatch_apply(P, Q(), ^(size_t j) {
        for (int i = 0; i < P; i++) {
            float x = (i + .5f) * u, y = S - ((float)j + .5f) * u;
            float yn = clampf((y - 100) / 824, 0, 1), xn = clampf((x - 100) / 824, 0, 1);
            float lit = left ? (.5f - xn) * .16f + (yn - .5f) * .04f : (yn - .5f) * .16f + (.5f - xn) * .05f;
            lit += (fbm(x / 170, y / 170, 5) - .5f) * .06f;
            lit += (hash2(i, (int)j, 7) - .5f) * .05f + (hash2(i / 2, (int)j / 2, 8) - .5f) * .025f;
            RGB c = lit > 0 ? mixc(base, warmLight, lit * 1.3f) : mixc(base, warmShade, -lit * .9f);
            float *p = Px(sh, i, (int)j);
            p[0] = c.r; p[1] = c.g; p[2] = c.b; p[3] = 1;
        }
    });
    CGContextDrawImage(ctx, kFull, ImgToCG(sh));
    ImgFree(sh);
    CGPathRef body = Squircle(kBody, kRadius);
    InnerShadowLit(ctx, body, -5, 8, cg(gray(1), .5));
    InnerShadowLit(ctx, body, 10, 18, cg(warmShade, .35));
    InnerShadowLit(ctx, body, -1.5, 1.5, cg(gray(1), .55));
    CGFloat partInset = gSlim ? 17 : 22;
    CGPathRef part = Squircle(CGRectInset(kBody, partInset, partInset), kRadius - partInset * .8);
    StrokePath(ctx, part, warmShade, .18, 2);
    CGContextSaveGState(ctx);
    if (left) CGContextTranslateCTM(ctx, 1.6, 0); else CGContextTranslateCTM(ctx, 0, -1.6);   // the groove's lit wall
    StrokePath(ctx, part, warmLight, .30, 1.2);
    CGContextRestoreGState(ctx);
    CGPathRelease(body); CGPathRelease(part);
}

static void DrawChin(CGContextRef ctx, CGFloat cy, CGFloat pull, CGFloat textSize);

static CGImageRef IconCScreen(BOOL cassette) {
    CGContextRef ctx = NewCtx(S, S);
    DrawShellBody(ctx);
    const int cols = 36, rows = 26; const CGFloat pitch = 16, dot = 13.4;
    CGRect grid = CGRectMake(512 - cols * pitch / 2, 378, cols * pitch, rows * pitch);
    CGRect L = CGRectInset(grid, -8, -8);
    CGRect W1 = CGRectMake(L.origin.x - 40, L.origin.y - 40, L.size.width + 80, L.size.height + 95);
    CGRect W0 = CGRectInset(W1, -13, -13);
    CGPathRef w0 = Squircle(W0, 118), w1 = Squircle(W1, 105), lp = Squircle(L, 34);
    // chamfered recess
    CGContextSaveGState(ctx); CGContextAddPath(ctx, w0); CGContextClip(ctx);
    Grad2(ctx, CGPointMake(0, CGRectGetMaxY(W0)), CGPointMake(0, W0.origin.y), hex(0x7a6b52), 1, hex(0xe6dac2), 1);
    CGContextRestoreGState(ctx);
    StrokePath(ctx, w0, hex(0x5a4d3a), .35, 1.5);
    // smoked glass
    CGContextSaveGState(ctx); CGContextAddPath(ctx, w1); CGContextClip(ctx);
    Grad2(ctx, CGPointMake(0, CGRectGetMaxY(W1)), CGPointMake(0, W1.origin.y), hex(0x2a2721), 1, hex(0x151411), 1);
    CGContextRestoreGState(ctx);
    InnerShadow(ctx, w1, -8, 12, cg(gray(0), .7));
    CGFloat legendY = (CGRectGetMaxY(L) + CGRectGetMaxY(W1)) / 2;
    NSFont *lf = [NSFont systemFontOfSize:15 weight:NSFontWeightMedium];
    CGSize ls = DrawText(ctx, @"DOT MATRIX · 300 × 195", lf, ns(hex(0xa39d91), .8), 3.5, CGPointMake(512, legendY));
    CGContextSetFillColorWithColor(ctx, cg(hex(0xa39d91), .35));
    CGContextFillRect(ctx, CGRectMake(L.origin.x + 6, legendY, 512 - ls.width / 2 - 16 - (L.origin.x + 6), 1.2));
    CGContextFillRect(ctx, CGRectMake(512 + ls.width / 2 + 16, legendY, CGRectGetMaxX(L) - 6 - (512 + ls.width / 2 + 16), 1.2));
    // the lit LCD
    CGContextSaveGState(ctx); CGContextAddPath(ctx, lp); CGContextClip(ctx);
    Radial(ctx, CGPointMake(512, 610), 430, hex(0xd6ddc6), 1, hex(0xaab597), 1);
    RGB ink = hex(0x1e281b);
    CGMutablePathRef on = CGPathCreateMutable(), off = CGPathCreateMutable();
    for (int row = 0; row < rows; row++) for (int col = 0; col < cols; col++) {
        CGRect d = CGRectMake(grid.origin.x + col * pitch + (pitch - dot) / 2, CGRectGetMaxY(grid) - (row + 1) * pitch + (pitch - dot) / 2, dot, dot);
        CGPathAddRoundedRect(LCDOn(col, row, cassette) ? on : off, NULL, d, 2.6, 2.6);
    }
    FillPath(ctx, off, ink, .06);
    CGContextSetShadowWithColor(ctx, CGSizeMake(3, -3), 2, cg(gray(0), .20));
    FillPath(ctx, on, ink, .88);
    CGContextRestoreGState(ctx);
    InnerShadow(ctx, lp, -7, 10, cg(gray(0), .5));
    // glare on the glass
    CGContextSaveGState(ctx); CGContextAddPath(ctx, w1); CGContextClip(ctx);
    { RGB w[3] = {gray(1), gray(1), gray(1)}; float al[3] = {.13, .03, 0}; CGFloat lc[3] = {0, .5, 1};
      Linear(ctx, CGPointMake(W1.origin.x, CGRectGetMaxY(W1)), CGPointMake(600, 440), 3, w, al, lc); }
    CGContextRestoreGState(ctx);
    StrokePath(ctx, w1, gray(1), .10, 1.5);

    DrawChin(ctx, (100 + W0.origin.y) / 2, 0, 40);
    return Finish(CtxImage(ctx), NO);
}
static CGImageRef IconC(void) { return IconCScreen(NO); }

/// C's chin: status LED, debossed name, speaker grille.
static void DrawChin(CGContextRef ctx, CGFloat cy, CGFloat pull, CGFloat textSize) {   // pull: moves LED and grille toward the middle
    CGPoint lc = CGPointMake(240 + pull, cy);
    Radial(ctx, lc, 90, hex(0xFFA43A), .20, hex(0xFFA43A), 0);
    CGPathRef bezel = Circle(lc, 22), led = Circle(lc, 13);
    FillPath(ctx, bezel, ShellTone(-.75f), 1);
    InnerShadowLit(ctx, bezel, -3, 4, cg(gray(0), .6));
    CGContextSaveGState(ctx);
    CGContextSetShadowWithColor(ctx, CGSizeZero, 26, cg(hex(0xFFA43A), 1));
    FillPath(ctx, led, hex(0xFFA43A), 1);
    FillPath(ctx, led, hex(0xFFA43A), 1);
    CGContextRestoreGState(ctx);
    // highlights sit toward the light; the deboss's lit wall and the holes' lit lips sit away from it
    CGPoint toLight = gLeft ? CGPointMake(-1, .15) : CGPointMake(-.6, .8), away = gLeft ? CGPointMake(1, 0) : CGPointMake(0, -1);
    CGContextSaveGState(ctx); CGContextAddPath(ctx, led); CGContextClip(ctx);
    Radial(ctx, CGPointMake(lc.x + toLight.x * 5, lc.y + toLight.y * 5), 14, hex(0xFFE6B8), 1, hex(0xF28A22), 1);
    CGContextRestoreGState(ctx);
    CGPathRef glint = Circle(CGPointMake(lc.x + toLight.x * 6.4, lc.y + toLight.y * 6.4), 3.5);
    FillPath(ctx, glint, gray(1), .7);
    NSFont *tf = [NSFont systemFontOfSize:textSize weight:NSFontWeightSemibold];
    CGFloat deboss = textSize * .045;
    DrawText(ctx, @"CD GLASS", tf, ns(ShellTone(ShellDark() ? .34f : .55f), .85), textSize * .225, CGPointMake(512 + away.x * deboss, cy + away.y * deboss));
    DrawText(ctx, @"CD GLASS", tf, ns(ShellTone(ShellDark() ? -.55f : -.3f), 1), textSize * .225, CGPointMake(512, cy));
    for (int r = 0; r < 3; r++) for (int c = 0; c < 4; c++) {
        CGPoint hc = CGPointMake(784 - pull + (c - 1.5) * 24, cy + (1 - r) * 24);
        CGPathRef lip = Circle(CGPointMake(hc.x + away.x * 1.6, hc.y + away.y * 1.6), 6.5), hole = Circle(hc, 6.5);
        FillPath(ctx, lip, ShellTone(.6f), .8);
        FillPath(ctx, hole, ShellTone(-.85f), 1);
        InnerShadowLit(ctx, hole, -2.5, 2.5, cg(gray(0), .7));
        CGPathRelease(lip); CGPathRelease(hole);
    }
    CGPathRelease(bezel); CGPathRelease(led); CGPathRelease(glint);
}

#pragma mark - D 珠宝盒: a jewel case with the disc sliding out, over its own blurred cover

static CGImageRef CoverArt(int n) {
    Img im = ImgNew(n, n);
    dispatch_apply((size_t)n, Q(), ^(size_t j) {
        for (int i = 0; i < n; i++) {
            float u = (i + .5f) / n, v = (n - j - .5f) / n;
            const float h = .40f;
            RGB c;
            if (v >= h) {
                float t = (v - h) / (1 - h);
                RGB s0 = hex(0xffb36e), s1 = hex(0xf2747a), s2 = hex(0xa84d9a), s3 = hex(0x28336f);
                c = t < .22f ? mixc(s0, s1, t / .22f) : t < .55f ? mixc(s1, s2, (t - .22f) / .33f) : mixc(s2, s3, (t - .55f) / .45f);
                c = mixc(c, hex(0xffc9c4), smoothf(.55f, .78f, fbm(u * 3.2f, v * 10, 21)) * .45f * (1 - t * .6f));
            } else {
                float t = (h - v) / h;
                c = mixc(hex(0x6a3f7c), hex(0x16122e), powf(t, .7f));
                float stripe = hash2((int)(v * n / 5), 3, 17);
                float w = .13f * (1 - t * .5f) * (.6f + .8f * stripe);
                c = mixc(c, hex(0xffcf9c), .55f * (1 - t) * (.5f + .5f * stripe) * smoothf(w, w * .6f, fabsf(u - .5f)));
            }
            float sd = hypotf(u - .5f, v - .53f);
            if (v >= h) c = mixc(c, mixc(hex(0xfff3d6), hex(0xffd49a), clampf(sd / .15f, 0, 1)), smoothf(.15f, .147f, sd));
            c = screenc(c, scalec(hex(0xffc98a), .45f * expf(-fmaxf(0, sd - .15f) / .09f) * (v >= h ? 1 : .5f)));
            c = addc(c, gray(.35f * gauss(v - h, .003f)));
            float g = (hash2(i, (int)j, 5) - .5f) * .04f;
            float *p = Px(im, i, (int)j);
            p[0] = c.r + g; p[1] = c.g + g; p[2] = c.b + g; p[3] = 1;
        }
    });
    CGImageRef out = ImgToCG(im);
    ImgFree(im);
    return out;
}

/// A jewel case with the disc behind it. `clear`: a clear tray instead of the usual black one.
static void DrawCase(CGContextRef ctx, BOOL clear, void (^insert)(CGRect art)) {
    CGRect box = CGRectMake(0, 0, 470, 414), front = CGRectMake(44, 0, 426, 414);
    CGPathRef shape = CGPathCreateWithRoundedRect(box, 9, 9, NULL);
    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, shape); CGContextClip(ctx);
    // spine: the tray seen through the clear hinge
    if (clear) {
        CGContextSetFillColorWithColor(ctx, cg(gray(1), .16)); CGContextFillRect(ctx, CGRectMake(0, 0, 44, 414));
        Grad2(ctx, CGPointMake(0, 0), CGPointMake(44, 0), gray(0), .10, gray(0), 0);
    } else {
        CGContextSetFillColorWithColor(ctx, cg(hex(0x17131c), .92)); CGContextFillRect(ctx, CGRectMake(0, 0, 44, 414));
    }
    for (int k = 0; k < 5; k++) {
        CGFloat x = 7 + k * 7;
        CGContextSetFillColorWithColor(ctx, cg(gray(1), clear ? .40 : .10)); CGContextFillRect(ctx, CGRectMake(x, 10, 1.6, 394));
        CGContextSetFillColorWithColor(ctx, cg(gray(0), clear ? .12 : .25)); CGContextFillRect(ctx, CGRectMake(x + 1.6, 10, 1.2, 394));
    }
    for (int k = 0; k < 2; k++) {
        CGPathRef knuckle = CGPathCreateWithRoundedRect(CGRectMake(4, k ? 370 : 18, 36, 26), 4, 4, NULL);
        FillPath(ctx, knuckle, gray(1), clear ? .22 : .06);
        StrokePath(ctx, knuckle, clear ? gray(0) : gray(1), clear ? .16 : .14, 1);
        CGPathRelease(knuckle);
    }
    // the tray around the insert, and the insert
    if (clear) {
        CGContextSetFillColorWithColor(ctx, cg(gray(1), .12)); CGContextFillRect(ctx, CGRectMake(456, 0, 14, 414));
        CGContextSetFillColorWithColor(ctx, cg(gray(1), .18));
    } else {
        CGContextSetFillColorWithColor(ctx, cg(hex(0x1a1620), .55)); CGContextFillRect(ctx, CGRectMake(456, 0, 14, 414));
        CGContextSetFillColorWithColor(ctx, cg(hex(0x1a1620), .85));
    }
    CGContextFillRect(ctx, CGRectMake(44, 410, 412, 4)); CGContextFillRect(ctx, CGRectMake(44, 0, 412, 4));
    insert(CGRectMake(50, 4, 406, 406));
    if (clear) {                                                                  // the paper's edge under the lid
        CGContextSetStrokeColorWithColor(ctx, cg(gray(0), .14)); CGContextSetLineWidth(ctx, 1);
        CGContextStrokeRect(ctx, CGRectMake(50.5, 4.5, 405, 405));
    }
    // clear lid
    CGContextClipToRect(ctx, front);
    CGContextSetFillColorWithColor(ctx, cg(gray(1), .035)); CGContextFillRect(ctx, front);
    { RGB w[3] = {gray(1), gray(1), gray(1)}; float al[3] = {.22, .06, 0}; CGFloat lc[3] = {0, .35, .7};
      if (gLeft) Linear(ctx, CGPointMake(44, 240), CGPointMake(330, 200), 3, w, al, lc);
      else Linear(ctx, CGPointMake(44, 414), CGPointMake(300, 150), 3, w, al, lc); }
    CGMutablePathRef band = CGPathCreateMutable();
    CGPathMoveToPoint(band, NULL, 250, 414); CGPathAddLineToPoint(band, NULL, 292, 414);
    CGPathAddLineToPoint(band, NULL, 44, 166); CGPathAddLineToPoint(band, NULL, 44, 124); CGPathCloseSubpath(band);
    FillPath(ctx, band, gray(1), .07);
    CGPathRelease(band);
    CGPathRef lip = CGPathCreateWithRoundedRect(CGRectInset(front, 5, 5), 5, 5, NULL);
    StrokePath(ctx, lip, gray(1), .12, 1);
    CGPathRelease(lip);
    CGContextRestoreGState(ctx);
    CGContextSetFillColorWithColor(ctx, cg(gray(1), clear ? .6 : .35)); CGContextFillRect(ctx, CGRectMake(43, 1, 1.5, 412));
    CGContextSetFillColorWithColor(ctx, cg(gray(0), clear ? .18 : .35)); CGContextFillRect(ctx, CGRectMake(44.5, 1, 1.5, 412));
    if (clear && gCaseTint > 0) {                                                 // a touch of smoke in the plastic
        CGContextSaveGState(ctx);
        CGContextAddPath(ctx, shape); CGContextClip(ctx);
        CGContextSetFillColorWithColor(ctx, cg(hex(0x6f6557), gCaseTint)); CGContextFillRect(ctx, box);
        CGContextRestoreGState(ctx);
    }
    if (clear) StrokePath(ctx, shape, gray(0), .22 + gCaseTint * 1.5, 2.4);      // clear plastic reads by its edges
    StrokePath(ctx, shape, gray(1), clear ? .75 : .5, clear ? 1.2 : 2);
    CGPathRelease(shape);
}

static CGImageRef IconD(void) {
    CGImageRef cover = CoverArt(512);
    CGContextRef ctx = NewCtx(S, S);
    CGContextDrawImage(ctx, CGRectMake(-300, -520, 1624, 1624), cover);   // mostly sky, the sun low behind the case
    CGImageRef bg = Adjust(Blur(CtxImage(ctx), 64), 1.15, -.06, 1.0);
    DiscSpec spec = {200, 2.25f, .6f, 2.3f};
    int n; CGImageRef disc = RenderDisc(spec, &n);

    ctx = NewCtx(S, S);
    CGContextDrawImage(ctx, kFull, bg);
    Radial(ctx, CGPointMake(512, 540), 640, gray(0), 0, gray(0), .26);
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, 512, 506);
    CGContextRotateCTM(ctx, -4 * M_PI / 180);
    CGContextTranslateCTM(ctx, -322, -207);
    CGContextSetShadowWithColor(ctx, CGSizeMake(0, -24), 44, cg(gray(0), .55));
    CGContextBeginTransparencyLayer(ctx, NULL);
    CGContextDrawImage(ctx, CGRectMake(445 - n / 2.0, 207 - n / 2.0, n, n), disc);
    DrawCase(ctx, NO, ^(CGRect art) { CGContextDrawImage(ctx, art, cover); });
    CGContextEndTransparencyLayer(ctx);
    CGContextRestoreGState(ctx);
    return Finish(Grain(CtxImage(ctx), .018f, 14), NO);
}

#pragma mark - F G H: D's case and disc, with C's dot-matrix screen as the cover, on a plain ground

/// D's sunset cover redrawn as 1-bit dots.
static BOOL SunsetOn(int col, int row, int cols, int rows) {
    int hr = (int)lroundf(rows * .58f);
    float cx = (cols - 1) / 2.f;
    if (row == hr) return YES;                                                    // horizon
    if (row < hr) {
        float r = cols * .22f, d = hypotf(col - cx, hr - row), a = atan2f(hr - row, col - cx) * 180 / (float)M_PI;
        if (d <= r) return YES;                                                   // the sun, half set
        if (d >= r + 1.3f && d <= r + 2.6f)                                        // its rays
            for (int k = 0; k < 5; k++) if (fabsf(a - (20 + k * 35)) < 7) return YES;
        if ((row == 3 && col >= 2 && col <= 6) || (row == 2 && col >= 3 && col <= 5)) return YES;              // clouds
        if ((row == 5 && col >= cols - 7 && col <= cols - 3) || (row == 4 && col >= cols - 6 && col <= cols - 4)) return YES;
        return NO;
    }
    int k = row - hr;
    if (k % 2 == 0 && k <= 8 && fabsf(col - cx) <= cols * (.19f - k * .02f)) return YES;                        // reflection
    if (k == 3 && ((col >= 2 && col <= 4) || (col >= cols - 5 && col <= cols - 3))) return YES;                 // waves
    if (k == 7 && ((col >= 4 && col <= 6) || (col >= cols - 7 && col <= cols - 5))) return YES;
    return NO;
}

/// C's lit LCD: sage backlight, faint unlit dots, inked dots with their shadow on the backlight.
static void DrawLCD(CGContextRef ctx, CGRect grid, int cols, int rows, CGFloat pitch, CGFloat inset, CGFloat radius, BOOL (^on)(int col, int row)) {
    CGRect L = CGRectInset(grid, -inset, -inset);
    CGPathRef lp = Squircle(L, radius);
    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, lp);
    CGContextClip(ctx);
    Radial(ctx, CGPointMake(CGRectGetMidX(L), CGRectGetMidY(L) + L.size.height * .06), MAX(L.size.width, L.size.height) * .75, hex(0xd6ddc6), 1, hex(0xaab597), 1);
    RGB ink = hex(0x1e281b);
    CGFloat dot = pitch * .84, corner = pitch * .16;
    CGMutablePathRef lit = CGPathCreateMutable(), unlit = CGPathCreateMutable();
    for (int row = 0; row < rows; row++) for (int col = 0; col < cols; col++) {
        CGRect d = CGRectMake(grid.origin.x + col * pitch + (pitch - dot) / 2, CGRectGetMaxY(grid) - (row + 1) * pitch + (pitch - dot) / 2, dot, dot);
        CGPathAddRoundedRect(on(col, row) ? lit : unlit, NULL, d, corner, corner);
    }
    FillPath(ctx, unlit, ink, .06);
    CGContextSetShadowWithColor(ctx, CGSizeMake(pitch * .18, -pitch * .18), pitch * .12, cg(gray(0), .20));
    FillPath(ctx, lit, ink, .88);
    CGContextRestoreGState(ctx);
    InnerShadow(ctx, lp, -pitch * .42, pitch * .6, cg(gray(0), .5));
    CGPathRelease(lit); CGPathRelease(unlit); CGPathRelease(lp);
}

static CGImageRef KhakiTexture(int w, int h, int seed) {
    RGB base = hex(0xBAA98C), warmLight = hex(0xFFF4E2), warmShade = hex(0x2B2116);
    Img im = ImgNew(w, h);
    dispatch_apply((size_t)h, Q(), ^(size_t j) {
        for (int i = 0; i < w; i++) {
            float x = i + .5f, y = h - (float)j - .5f;
            float lit = (y / h - .5f) * .14f + (.5f - x / w) * .05f;
            lit += (fbm(x / 120, y / 120, seed) - .5f) * .05f;
            lit += (hash2(i, (int)j, seed + 2) - .5f) * .05f + (hash2(i / 2, (int)j / 2, seed + 3) - .5f) * .025f;
            RGB c = lit > 0 ? mixc(base, warmLight, lit * 1.3f) : mixc(base, warmShade, -lit * .9f);
            float *p = Px(im, i, (int)j);
            p[0] = c.r; p[1] = c.g; p[2] = c.b; p[3] = 1;
        }
    });
    CGImageRef out = ImgToCG(im);
    ImgFree(im);
    return out;
}

/// The jewel case moulded in C's khaki plastic, its front a recessed smoked-glass window over the LCD.
static void DrawKhakiCase(CGContextRef ctx) {
    static CGImageRef tex;
    if (!tex) tex = KhakiTexture(470, 414, 31);
    RGB shade = hex(0x2B2116), light = hex(0xFFF4E2);
    CGRect box = CGRectMake(0, 0, 470, 414);
    CGPathRef shape = Squircle(box, 24);
    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, shape); CGContextClip(ctx);
    CGContextDrawImage(ctx, box, tex);
    Grad2(ctx, CGPointMake(0, 0), CGPointMake(44, 0), shade, .12, shade, 0);                    // the rounded spine
    for (int k = 0; k < 4; k++) {
        CGFloat x = 10 + k * 7;
        CGContextSetFillColorWithColor(ctx, cg(shade, .22)); CGContextFillRect(ctx, CGRectMake(x, 64, 1.4, 286));
        CGContextSetFillColorWithColor(ctx, cg(light, .35)); CGContextFillRect(ctx, CGRectMake(x + 1.4, 64, 1.2, 286));
    }
    for (int k = 0; k < 2; k++) {                                                                // hinge knuckles
        CGPathRef slot = Squircle(CGRectMake(9, k ? 364 : 18, 26, 32), 6);
        FillPath(ctx, slot, shade, .10);
        InnerShadow(ctx, slot, -2, 3, cg(shade, .5));
        CGPathRelease(slot);
    }
    CGContextSetFillColorWithColor(ctx, cg(shade, .30)); CGContextFillRect(ctx, CGRectMake(44, 6, 1.5, 402));
    CGContextSetFillColorWithColor(ctx, cg(light, .40)); CGContextFillRect(ctx, CGRectMake(45.5, 6, 1.2, 402));
    CGContextRestoreGState(ctx);
    InnerShadow(ctx, shape, -3, 5, cg(gray(1), .55));
    InnerShadow(ctx, shape, 6, 10, cg(shade, .35));
    StrokePath(ctx, shape, shade, .28, 1.2);
    CGPathRelease(shape);

    CGRect W0 = CGRectMake(58, 15, 398, 384), W1 = CGRectInset(W0, 8, 8);
    CGPathRef w0 = Squircle(W0, 30), w1 = Squircle(W1, 24);
    CGContextSaveGState(ctx); CGContextAddPath(ctx, w0); CGContextClip(ctx);
    Grad2(ctx, CGPointMake(0, CGRectGetMaxY(W0)), CGPointMake(0, W0.origin.y), hex(0x7a6b52), 1, hex(0xe6dac2), 1);
    CGContextRestoreGState(ctx);
    StrokePath(ctx, w0, hex(0x5a4d3a), .35, 1.2);
    CGContextSaveGState(ctx); CGContextAddPath(ctx, w1); CGContextClip(ctx);
    Grad2(ctx, CGPointMake(0, CGRectGetMaxY(W1)), CGPointMake(0, W1.origin.y), hex(0x2a2721), 1, hex(0x151411), 1);
    CGContextRestoreGState(ctx);
    InnerShadow(ctx, w1, -5, 8, cg(gray(0), .7));
    DrawLCD(ctx, CGRectMake(W1.origin.x + 23, W1.origin.y + 23, 24 * 14, 23 * 14), 24, 23, 14, 5, 12, ^BOOL(int c, int r) { return SunsetOn(c, r, 24, 23); });
    CGContextSaveGState(ctx); CGContextAddPath(ctx, w1); CGContextClip(ctx);
    { RGB w[3] = {gray(1), gray(1), gray(1)}; float al[3] = {.14, .03, 0}; CGFloat lc[3] = {0, .5, 1};
      Linear(ctx, CGPointMake(W1.origin.x, CGRectGetMaxY(W1)), CGPointMake(CGRectGetMidX(W1) + 40, CGRectGetMidY(W1) - 60), 3, w, al, lc); }
    CGContextRestoreGState(ctx);
    StrokePath(ctx, w1, gray(1), .10, 1.2);
    CGPathRelease(w0); CGPathRelease(w1);
}

static CGImageRef PlainGround(BOOL dark) {
    RGB top = dark ? hex(0x37322c) : gGround[0], bottom = dark ? hex(0x1c1916) : gGround[1];
    Img im = ImgNew(S, S);
    BOOL left = gLeft;
    dispatch_apply(S, Q(), ^(size_t j) {
        for (int i = 0; i < S; i++) {
            float x = i + .5f, y = S - (float)j - .5f;
            RGB c = left ? mixc(top, bottom, smoothf(100, 924, x)) : mixc(bottom, top, smoothf(100, 924, y));
            float spot = left ? hypotf(x - 150, y - 560) : hypotf(x - 470, y - 860);
            c = addc(c, gray(.035f * (1 - smoothf(0, 620, spot))));                          // soft light from the key side
            c = addc(c, gray((fbm(x / 140, y / 140, 41) - .5f) * .025f));
            float *p = Px(im, i, (int)j);
            p[0] = c.r; p[1] = c.g; p[2] = c.b; p[3] = 1;
        }
    });
    CGImageRef out = ImgToCG(im);
    ImgFree(im);
    return out;
}

static CGImageRef ComboIcon(BOOL khaki, BOOL dark) {
    DiscSpec spec = {200, 2.25f, .6f, 2.3f};
    int n; CGImageRef disc = RenderDisc(spec, &n);
    CGContextRef ctx = NewCtx(S, S);
    CGContextDrawImage(ctx, kFull, PlainGround(dark));
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, 512, 506);
    CGContextRotateCTM(ctx, -4 * M_PI / 180);
    CGContextTranslateCTM(ctx, -322, -207);
    if (dark) CGContextSetShadowWithColor(ctx, CGSizeMake(0, -24), 44, cg(gray(0), .6));
    else CGContextSetShadowWithColor(ctx, CGSizeMake(0, -20), 36, cg(hex(0x3b2a18), .36));
    CGContextBeginTransparencyLayer(ctx, NULL);
    CGContextDrawImage(ctx, CGRectMake(445 - n / 2.0, 207 - n / 2.0, n, n), disc);
    if (khaki) DrawKhakiCase(ctx);
    else DrawCase(ctx, NO, ^(CGRect art) {
        DrawLCD(ctx, CGRectInset(art, 7, 7), 28, 28, 14, 7, 4, ^BOOL(int c, int r) { return SunsetOn(c, r, 28, 28); });
    });
    CGContextEndTransparencyLayer(ctx);
    CGContextRestoreGState(ctx);
    return Finish(Grain(CtxImage(ctx), .014f, 15), !dark);
}
#pragma mark - I J K: the whole of C printed as the cover in D's case

/// A cover sleeve: plain paper with icon C centred on it, shadow and all.
static CGImageRef CoverWithIcon(BOOL darkPaper, BOOL cassette) {
    static CGImageRef screens[2];
    if (!screens[cassette]) screens[cassette] = IconCScreen(cassette);
    CGImageRef iconC = screens[cassette];
    const int n = 812;
    CGContextRef ctx = NewCtx(n, n);
    if (darkPaper) Grad2(ctx, CGPointMake(0, n), CGPointMake(0, 0), hex(0x2e2b27), 1, hex(0x1d1b19), 1);
    else Grad2(ctx, CGPointMake(0, n), CGPointMake(0, 0), hex(0xf2ede3), 1, hex(0xe2d9c9), 1);
    CGFloat side = n * .92;
    CGContextDrawImage(ctx, CGRectMake((n - side) / 2, (n - side) / 2 + n * .01, side, side), iconC);
    return Grain(CtxImage(ctx), .02f, 17);
}

static CGImageRef CaseIcon(BOOL darkGround, BOOL darkPaper, BOOL clear) {
    CGImageRef cover = CoverWithIcon(darkPaper, NO);
    DiscSpec spec = {200, 2.25f, .6f, 2.3f};
    int n; CGImageRef disc = RenderDisc(spec, &n);
    CGContextRef ctx = NewCtx(S, S);
    CGContextDrawImage(ctx, kFull, PlainGround(darkGround));
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, 512, 506);
    CGContextRotateCTM(ctx, -4 * M_PI / 180);
    CGContextTranslateCTM(ctx, -322, -207);
    if (darkGround) CGContextSetShadowWithColor(ctx, CGSizeMake(0, -24), 44, cg(gray(0), .6));
    else CGContextSetShadowWithColor(ctx, CGSizeMake(0, -20), 36, cg(hex(0x3b2a18), .36));
    CGContextBeginTransparencyLayer(ctx, NULL);
    CGContextDrawImage(ctx, CGRectMake(445 - n / 2.0, 207 - n / 2.0, n, n), disc);
    DrawCase(ctx, clear, ^(CGRect art) { CGContextDrawImage(ctx, art, cover); });
    CGContextEndTransparencyLayer(ctx);
    CGContextRestoreGState(ctx);
    return Finish(Grain(CtxImage(ctx), .014f, 16), !darkGround);
}
#pragma mark - The cassette label: C's pixel screen, printed

/// Status row on top and progress along the bottom — the middle is punched out by the cassette window anyway.
static BOOL LabelOn(int col, int row, int cols, int rows) {
    if (row <= 4) {
        int w = 3 - abs(row - 2);
        if (col >= 1 && col < 1 + w) return YES;                                  // ▶
        static const char *digits[2][5] = {{"111", "101", "101", "101", "111"}, {"010", "110", "010", "010", "111"}};
        for (int k = 0; k < 2; k++) {                                             // 01
            int c0 = 6 + k * 4;
            if (col >= c0 && col < c0 + 3 && digits[k][row][col - c0] == '1') return YES;
        }
        for (int k = 0; k < 4; k++) if (col == cols - 9 + k * 2 && row > 4 - (2 + k)) return YES;   // volume
    }
    if (row == rows - 2 && col >= 1 && col <= cols - 2) return col <= cols * .38f || col % 2 == 1;  // progress
    return NO;
}

/// 88.2 × 38.4 mm at 20 px/mm: exactly the printable area of the app's cassette label, so nothing gets cropped.
static CGImageRef TapeLabel(void) {
    const int W = 1764, H = 768, cols = 53, rows = 22;
    const CGFloat pitch = 32;
    CGContextRef ctx = NewCtx(W, H);
    Grad2(ctx, CGPointMake(0, H), CGPointMake(0, 0), hex(0x2a2721), 1, hex(0x151411), 1);
    CGRect grid = CGRectMake((W - cols * pitch) / 2, (H - rows * pitch) / 2, cols * pitch, rows * pitch);
    DrawLCD(ctx, grid, cols, rows, pitch, 6, 18, ^BOOL(int c, int r) { return LabelOn(c, r, cols, rows); });
    return CtxImage(ctx);
}

#pragma mark - L M N: I with a cassette on the screen, the disc further in, and the khaki shell all around

/// `window`: 0 — the shell frames a recessed window with I's pale ground inside; 1 — the window is C's smoked glass;
/// 2 — no window, the case lies straight on the shell.
static CGImageRef ShellIcon(int window) {
    CGImageRef cover = CoverWithIcon(NO, YES);
    DiscSpec spec = {200, 2.25f, .6f, 2.3f};
    int n; CGImageRef disc = RenderDisc(spec, &n);
    const CGFloat discX = 380;                     // was 445: the disc sits further inside the case
    CGContextRef ctx = NewCtx(S, S);
    DrawShellBody(ctx);
    CGRect W0 = CGRectInset(kBody, 58, 58), W1 = CGRectInset(W0, 12, 12);
    CGPathRef w0 = Squircle(W0, kRadius - 50), w1 = Squircle(W1, kRadius - 62);
    if (window < 2) {
        CGContextSaveGState(ctx); CGContextAddPath(ctx, w0); CGContextClip(ctx);
        Grad2(ctx, CGPointMake(0, CGRectGetMaxY(W0)), CGPointMake(0, W0.origin.y), hex(0x7a6b52), 1, hex(0xe6dac2), 1);
        CGContextRestoreGState(ctx);
        StrokePath(ctx, w0, hex(0x5a4d3a), .35, 1.5);
        CGContextSaveGState(ctx); CGContextAddPath(ctx, w1); CGContextClip(ctx);
        if (window == 1) Grad2(ctx, CGPointMake(0, CGRectGetMaxY(W1)), CGPointMake(0, W1.origin.y), hex(0x2a2721), 1, hex(0x151411), 1);
        else CGContextDrawImage(ctx, kFull, PlainGround(NO));
    } else {
        CGContextSaveGState(ctx);
    }
    CGFloat scale = window < 2 ? .84 : .9;
    CGContextTranslateCTM(ctx, 512, window < 2 ? 510 : 514);
    CGContextRotateCTM(ctx, -4 * M_PI / 180);
    CGContextScaleCTM(ctx, scale, scale);
    CGContextTranslateCTM(ctx, -(discX + 200) / 2, -207);
    if (window == 1) CGContextSetShadowWithColor(ctx, CGSizeMake(0, -20), 38, cg(gray(0), .7));
    else CGContextSetShadowWithColor(ctx, CGSizeMake(0, -18), 32, cg(hex(0x3b2a18), window == 2 ? .5 : .36));
    CGContextBeginTransparencyLayer(ctx, NULL);
    CGContextDrawImage(ctx, CGRectMake(discX - n / 2.0, 207 - n / 2.0, n, n), disc);
    DrawCase(ctx, YES, ^(CGRect art) { CGContextDrawImage(ctx, art, cover); });
    CGContextEndTransparencyLayer(ctx);
    CGContextRestoreGState(ctx);
    if (window < 2) {
        InnerShadow(ctx, w1, -9, 14, cg(gray(0), window == 1 ? .7 : .4));
        CGContextSaveGState(ctx); CGContextAddPath(ctx, w1); CGContextClip(ctx);
        { RGB w[3] = {gray(1), gray(1), gray(1)}; float al[3] = {window == 1 ? .12f : .20f, .03f, 0}; CGFloat lc[3] = {0, .45, 1};
          Linear(ctx, CGPointMake(W1.origin.x, CGRectGetMaxY(W1)), CGPointMake(600, 420), 3, w, al, lc); }
        CGContextRestoreGState(ctx);
        StrokePath(ctx, w1, gray(1), .12, 1.5);
    }
    CGPathRelease(w0); CGPathRelease(w1);
    return Finish(Grain(CtxImage(ctx), .01f, 18), NO);
}
#pragma mark - P Q R: C's housing around I's clear case, holding the app's cassette with C's screen on its label

static NSString *gStudyDir;

/// The app's cassette, rendered by cassette_snap: 2600 × 1800 px, the tape itself at (200, 198.2) sized 2200 × 1403.6 (22 px/mm).
static CGImageRef TapeImage(BOOL dark) {
    static CGImageRef tapes[2];
    if (!tapes[dark]) {
        NSString *path = [gStudyDir stringByAppendingPathComponent:dark ? @"磁带-深.png" : @"磁带-浅.png"];
        CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
        if (src) { tapes[dark] = CGImageSourceCreateImageAtIndex(src, 0, NULL); CFRelease(src); }
    }
    return tapes[dark];
}
/// Draws the tape with its bottom-left corner at `o`, in millimetres (the context is scaled to mm).
static void DrawTape(CGContextRef ctx, BOOL dark, CGPoint o) {
    CGImageRef tape = TapeImage(dark);
    if (tape) CGContextDrawImage(ctx, CGRectMake(o.x - 200 / 22.0, o.y - 198.2 / 22.0, 2600 / 22.0, 1800 / 22.0), tape);
}

/// A clear cassette box, 110 × 69 mm, hinge on the left. `front`: the lid drawn over the tape; otherwise the tray behind it.
/// `px` is the size of one device pixel in mm, for hairlines.
static void DrawTapeBox(CGContextRef ctx, BOOL front, CGFloat px) {
    CGRect box = CGRectMake(0, 0, 110, 69), lid = CGRectMake(7, 0, 103, 69);
    CGPathRef shape = CGPathCreateWithRoundedRect(box, 3, 3, NULL);
    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, shape); CGContextClip(ctx);
    if (!front) {
        CGContextSetFillColorWithColor(ctx, cg(gray(1), .26)); CGContextFillRect(ctx, box);
        Grad2(ctx, CGPointMake(0, 69), CGPointMake(0, 0), gray(1), .10, gray(0), .05);
        CGContextSetFillColorWithColor(ctx, cg(gray(1), .16)); CGContextFillRect(ctx, CGRectMake(0, 0, 7, 69));
        Grad2(ctx, CGPointMake(0, 0), CGPointMake(7, 0), gray(0), .08, gray(0), 0);
        for (int k = 0; k < 4; k++) {                                            // hinge ridges
            CGFloat x = 1.4 + k * 1.3;
            CGContextSetFillColorWithColor(ctx, cg(gray(1), .45)); CGContextFillRect(ctx, CGRectMake(x, 8, .35, 53));
            CGContextSetFillColorWithColor(ctx, cg(gray(0), .10)); CGContextFillRect(ctx, CGRectMake(x + .35, 8, .3, 53));
        }
        for (int k = 0; k < 2; k++) {                                            // knuckles
            CGPathRef knuckle = CGPathCreateWithRoundedRect(CGRectMake(.8, k ? 62.5 : 2.5, 5.4, 4), .8, .8, NULL);
            FillPath(ctx, knuckle, gray(1), .25);
            StrokePath(ctx, knuckle, gray(0), .16, px * 1.2);
            CGPathRelease(knuckle);
        }
    } else {
        CGContextClipToRect(ctx, lid);
        CGContextSetFillColorWithColor(ctx, cg(gray(1), .05)); CGContextFillRect(ctx, lid);
        { RGB w[3] = {gray(1), gray(1), gray(1)}; float al[3] = {.26, .07, 0}; CGFloat lc[3] = {0, .35, .7};
          Linear(ctx, CGPointMake(7, 69), CGPointMake(52, 22), 3, w, al, lc); }
        CGMutablePathRef band = CGPathCreateMutable();
        CGPathMoveToPoint(band, NULL, 50, 69); CGPathAddLineToPoint(band, NULL, 57, 69);
        CGPathAddLineToPoint(band, NULL, 7, 24); CGPathAddLineToPoint(band, NULL, 7, 17); CGPathCloseSubpath(band);
        FillPath(ctx, band, gray(1), .08);
        CGPathRelease(band);
        CGPathRef rim = CGPathCreateWithRoundedRect(CGRectInset(lid, 2, 2), 1.6, 1.6, NULL);
        StrokePath(ctx, rim, gray(1), .35, px * 1.4);
        CGContextSaveGState(ctx); CGContextTranslateCTM(ctx, 0, -px * 1.4);
        StrokePath(ctx, rim, gray(0), .08, px * 1.2);
        CGContextRestoreGState(ctx);
        CGPathRelease(rim);
    }
    CGContextRestoreGState(ctx);
    if (front) {
        CGContextSetFillColorWithColor(ctx, cg(gray(1), .6)); CGContextFillRect(ctx, CGRectMake(7 - px * 1.5, .3, px * 1.5, 68.4));
        CGContextSetFillColorWithColor(ctx, cg(gray(0), .18)); CGContextFillRect(ctx, CGRectMake(7, .3, px * 1.5, 68.4));
        StrokePath(ctx, shape, gray(0), .30, px * 2.6);
        StrokePath(ctx, shape, gray(1), .8, px * 1.2);
    }
    CGPathRelease(shape);
}

static BOOL BadgeOn(int col, int row) {   // 9 × 9, "01"
    static const char *digits[2][5] = {{"111", "101", "101", "101", "111"}, {"010", "110", "010", "010", "111"}};
    if (row < 2 || row > 6) return NO;
    for (int k = 0; k < 2; k++) {
        int c0 = 1 + k * 4;
        if (col >= c0 && col < c0 + 3 && digits[k][row - 2][col - c0] == '1') return YES;
    }
    return NO;
}

/// T's 60 px bottom bezel: status LED at the left, a tiny pixel screen as the logo in the middle, speaker holes at the right.
static void DrawSlimChin(CGContextRef ctx, CGFloat cy) {
    CGPoint toLight = gLeft ? CGPointMake(-1, .15) : CGPointMake(-.6, .8), away = gLeft ? CGPointMake(1, 0) : CGPointMake(0, -1);
    // LED
    const CGFloat k = 1.44;                                                   // everything in the bezel grows with it
    CGPoint lc = CGPointMake(256, cy);
    Radial(ctx, lc, 52 * k, hex(0xFFA43A), .22, hex(0xFFA43A), 0);
    CGPathRef bezel = Circle(lc, 11 * k), led = Circle(lc, 6.8 * k);
    FillPath(ctx, bezel, ShellTone(-.75f), 1);
    InnerShadowLit(ctx, bezel, -1.5 * k, 2 * k, cg(gray(0), .6));
    CGContextSaveGState(ctx);
    CGContextSetShadowWithColor(ctx, CGSizeZero, 15 * k, cg(hex(0xFFA43A), 1));
    FillPath(ctx, led, hex(0xFFA43A), 1);
    CGContextRestoreGState(ctx);
    CGContextSaveGState(ctx); CGContextAddPath(ctx, led); CGContextClip(ctx);
    Radial(ctx, CGPointMake(lc.x + toLight.x * 2.6 * k, lc.y + toLight.y * 2.6 * k), 7.6 * k, hex(0xFFE6B8), 1, hex(0xF28A22), 1);
    CGContextRestoreGState(ctx);
    CGPathRelease(bezel); CGPathRelease(led);
    // the logo, printed flat on the plastic: a rounded square with the 9 × 9 dot "01"
    const CGFloat pitch = 3.6 * k, dot = pitch * .8, side = 40 * k;
    CGRect B = CGRectMake(512 - side / 2, cy - side / 2, side, side);
    CGPathRef badge = Squircle(B, 10 * k);
    RGB ground = gBadge == 1 ? ShellTone(-.62f) : hex(0xc9d2b6), ink = gBadge == 1 ? ShellTone(.18f) : hex(0x1e281b);
    FillPath(ctx, badge, ground, .92);
    CGMutablePathRef lit = CGPathCreateMutable(), unlit = CGPathCreateMutable();
    for (int row = 0; row < 9; row++) for (int col = 0; col < 9; col++) {
        CGRect d = CGRectMake(512 + (col - 4.5) * pitch + (pitch - dot) / 2, cy + (3.5 - row) * pitch + (pitch - dot) / 2, dot, dot);
        CGPathAddRoundedRect(BadgeOn(col, row) ? lit : unlit, NULL, d, dot * .2, dot * .2);
    }
    if (gBadge != 1) FillPath(ctx, unlit, ink, .07);
    FillPath(ctx, lit, ink, gBadge == 1 ? .95 : .85);
    CGPathRelease(lit); CGPathRelease(unlit); CGPathRelease(badge);
    // speaker holes
    for (int r = 0; r < 3; r++) for (int c = 0; c < 6; c++) {                   // 3 rows × 6: a wide grille
        CGPoint hc = CGPointMake(768 + (c - 2.5) * 13 * k, cy + (1 - r) * 13 * k);
        CGPathRef lip = Circle(CGPointMake(hc.x + away.x * 1.2 * k, hc.y + away.y * 1.2 * k), 4 * k), hole = Circle(hc, 4 * k);
        FillPath(ctx, lip, ShellTone(.6f), .8);
        FillPath(ctx, hole, ShellTone(-.85f), 1);
        InnerShadowLit(ctx, hole, -1.6 * k, 1.6 * k, cg(gray(0), .7));
        CGPathRelease(lip); CGPathRelease(hole);
    }
}

static void Vignette(CGContextRef ctx, CGRect r, float alpha) {
    RGB cols[2] = {gray(0), gray(0)}; float al[2] = {0, alpha}; CGFloat locs[2] = {0, 1};
    CGGradientRef g = MakeGradient(2, cols, al, locs);
    CGPoint c = CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r));
    CGContextDrawRadialGradient(ctx, g, c, r.size.width * .3, c, r.size.width * .78, kCGGradientDrawsAfterEndLocation);
    CGGradientRelease(g);
}
static void DotGrid(CGContextRef ctx, CGRect r, CGFloat pitch, RGB ink, CGFloat alpha) {
    CGMutablePathRef dots = CGPathCreateMutable();
    CGFloat dot = pitch * .72;
    for (CGFloat y = r.origin.y + pitch / 2; y < CGRectGetMaxY(r); y += pitch)
        for (CGFloat x = r.origin.x + pitch / 2; x < CGRectGetMaxX(r); x += pitch)
            CGPathAddRoundedRect(dots, NULL, CGRectMake(x - dot / 2, y - dot / 2, dot, dot), dot * .2, dot * .2);
    FillPath(ctx, dots, ink, alpha);
    CGPathRelease(dots);
}
static void DrawGroundStyle(CGContextRef ctx, CGRect W1) {
    CGPoint c = CGPointMake(506, 583);
    switch (gGroundStyle) {
        case 1:
            Radial(ctx, CGPointMake(c.x - 40, c.y + 20), 430, gray(1), .5, gray(1), 0);
            Vignette(ctx, W1, .2);
            break;
        case 2:
            Radial(ctx, CGPointMake(c.x - 70, c.y + 40), 600, hex(0xdde4cf), 1, hex(0xb3bda0), 1);
            DotGrid(ctx, W1, 30, hex(0x1e281b), .06);
            Vignette(ctx, W1, .12);
            break;
        case 3:
            LitGrad(ctx, W1, ShellTone(.45f), 1, ShellTone(.22f), 1);
            Radial(ctx, CGPointMake(c.x - 40, c.y + 20), 420, gray(1), .22, gray(1), 0);
            Vignette(ctx, W1, .12);
            break;
        case 4:
            DotGrid(ctx, W1, 14, ShellTone(-.5f), .07);
            Vignette(ctx, W1, .1);
            break;
    }
}

/// C's housing with its screen window showing `scene` on I's pale ground instead of the LCD.
static CGImageRef HousedIcon(void (^scene)(CGContextRef ctx, CGRect W1)) {
    CGContextRef ctx = NewCtx(S, S);
    DrawShellBody(ctx);
    // C's window, with the chin below it 20% lower (217 → 174 px) and the window grown down by the difference
    CGRect W1 = CGRectMake(176, 330, 672, 527);
    const CGFloat chin = (W1.origin.y - 13 - 100) * .2;
    W1.origin.y -= chin; W1.size.height += chin;
    CGRect W0 = CGRectInset(W1, -13, -13);
    CGFloat r0 = 118, r1 = 105;
    if (gSlim) {   // top and sides halved to 30 px of shell; the bottom kept at the old bezel width, 60 px; an 11 px chamfer
        const CGFloat side = 50, bottom = 192;  // grown step by step from 30 / 60 px
        W0 = CGRectMake(kBody.origin.x + side, kBody.origin.y + bottom, kBody.size.width - side * 2, kBody.size.height - side - bottom);
        W1 = CGRectInset(W0, 11, 11);
        r0 = kRadius - 30; r1 = kRadius - 41;
    }
    CGPathRef w0 = Squircle(W0, r0), w1 = Squircle(W1, r1);
    CGContextSaveGState(ctx); CGContextAddPath(ctx, w0); CGContextClip(ctx);
    LitGrad(ctx, W0, ShellTone(-.45f), 1, ShellTone(.55f), 1);                        // the recess wall facing away from the light is dark
    CGContextRestoreGState(ctx);
    StrokePath(ctx, w0, ShellTone(-.65f), .35, 1.5);
    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, w1); CGContextClip(ctx);
    CGContextDrawImage(ctx, kFull, PlainGround(NO));
    if (gSlim) DrawGroundStyle(ctx, W1);
    scene(ctx, W1);
    CGContextRestoreGState(ctx);
    InnerShadowLit(ctx, w1, -9, 14, cg(gray(0), .42));
    CGContextSaveGState(ctx); CGContextAddPath(ctx, w1); CGContextClip(ctx);
    { RGB w[3] = {gray(1), gray(1), gray(1)}; float al[3] = {.18, .03, 0}; CGFloat lc[3] = {0, .5, 1};
      if (gLeft) Linear(ctx, CGPointMake(W1.origin.x, CGRectGetMidY(W1) + 60), CGPointMake(W1.origin.x + 420, CGRectGetMidY(W1)), 3, w, al, lc);
      else Linear(ctx, CGPointMake(W1.origin.x, CGRectGetMaxY(W1)), CGPointMake(600, 440), 3, w, al, lc); }
    CGContextRestoreGState(ctx);
    StrokePath(ctx, w1, gray(1), .12, 1.5);
    CGPathRelease(w0); CGPathRelease(w1);
    if (!gSlim) DrawChin(ctx, (100 + W0.origin.y) / 2, 12, 52);                       // pulled in a little: the lower chin puts the corners closer
    else DrawSlimChin(ctx, (100 + W0.origin.y) / 2);
    return Finish(Grain(CtxImage(ctx), .008f, 19), NO);
}

/// `slide`: how far (mm) the tape stands out of its box to the right.
static CGImageRef HousedTapeIcon(BOOL darkTape, CGFloat slide) {
    return HousedIcon(^(CGContextRef ctx, CGRect W1) {
        CGFloat span = MAX(110, 105 + slide), s = MIN(W1.size.width * .84 / span, W1.size.height * .78 / 69);
        CGContextTranslateCTM(ctx, CGRectGetMidX(W1), CGRectGetMidY(W1) - 4);
        CGContextRotateCTM(ctx, (slide > 0 ? -4 : -2.5) * M_PI / 180);
        CGContextScaleCTM(ctx, s, s);
        CGContextTranslateCTM(ctx, -span / 2, -34.5);
        CGContextSetShadowWithColor(ctx, CGSizeMake(0, -16), 30, cg(hex(0x3b2a18), .34));
        CGContextBeginTransparencyLayer(ctx, NULL);
        DrawTapeBox(ctx, NO, 1 / s);
        DrawTape(ctx, darkTape, CGPointMake(5 + slide, 2.6));
        DrawTapeBox(ctx, YES, 1 / s);
        CGContextEndTransparencyLayer(ctx);
    });
}

/// A cover sleeve with the app's cassette printed on it (the one with C's screen on its label).
static CGImageRef CoverWithTape(BOOL darkTape) {
    const int n = 812;
    CGContextRef ctx = NewCtx(n, n);
    LitGrad(ctx, CGRectMake(0, 0, n, n), gPaper[0], 1, gPaper[1], 1);
    CGImageRef tape = TapeImage(darkTape);
    CGFloat tw = n * .86, k = tw / 2200, tx = (n - tw) / 2, ty = (n - tw * .638) / 2 + n * .01;
    if (tape) CGContextDrawImage(ctx, CGRectMake(tx - 200 * k, ty - 198.2 * k, 2600 * k, 1800 * k), tape);
    return Grain(CtxImage(ctx), .02f, 21);
}

/// I in C's housing: the clear jewel case with the disc a little way out, the cover printed with the cassette.
static CGImageRef HousedCaseIcon(BOOL darkTape) {
    CGImageRef cover = CoverWithTape(darkTape);
    DiscSpec spec = gLeft ? (DiscSpec){200, 2.95f, .9f, 3.05f} : (DiscSpec){200, 2.25f, .6f, 2.3f};
    spec.rainbow = gRainbow;
    int n; CGImageRef disc = RenderDisc(spec, &n);
    return HousedIcon(^(CGContextRef ctx, CGRect W1) {
        const CGFloat discX = 340;                                               // the disc 70 px out of the case (was 110)
        CGFloat s = MIN(W1.size.width * .86 / 580, W1.size.height * .74 / 414);   // case kept at the same size
        CGPoint c = CGPointMake(CGRectGetMidX(W1), CGRectGetMidY(W1) - 6);
        if (gSlim) { s = 742 * .86 / 580; c = CGPointMake(506, 583); }             // size fixed; centred in the window, 6 px left so the disc keeps its margin
        CGContextTranslateCTM(ctx, c.x, c.y);
        CGContextRotateCTM(ctx, -6 * M_PI / 180);
        CGContextScaleCTM(ctx, s, s);
        CGContextTranslateCTM(ctx, -235, -207);                                  // the case itself in the middle; the disc runs toward the edge
        CGContextSetShadowWithColor(ctx, gLeft ? CGSizeMake(18, -8) : CGSizeMake(0, -18), 32, cg(hex(0x3b2a18), .36));
        CGContextBeginTransparencyLayer(ctx, NULL);
        CGContextDrawImage(ctx, CGRectMake(discX - n / 2.0, 207 - n / 2.0, n, n), disc);
        DrawCase(ctx, YES, ^(CGRect art) { CGContextDrawImage(ctx, art, cover); });
        CGContextEndTransparencyLayer(ctx);
    });
}
/// T in a given housing colour: lit from the left, the case a shade smokier, the disc's rainbow softer.
static CGImageRef ToneIcon(uint32_t shell) {
    RGB keepShell = gShell, keepGround[2] = {gGround[0], gGround[1]}, keepPaper[2] = {gPaper[0], gPaper[1]};
    gShell = hex(shell);
    float k = ShellDark() ? .18f : .38f;
    gGround[0] = mixc(hex(0xfbf9f4), gShell, .12f);
    gGround[1] = mixc(hex(0xf4f1ea), gShell, k);
    gPaper[0] = hex(0xebe4d7); gPaper[1] = hex(0xdad0bf);
    gLeft = YES; gCaseTint = .07f; gRainbow = .55f;
    CGImageRef icon = HousedCaseIcon(NO);
    gLeft = NO; gCaseTint = 0; gRainbow = 1;
    gShell = keepShell; gGround[0] = keepGround[0]; gGround[1] = keepGround[1]; gPaper[0] = keepPaper[0]; gPaper[1] = keepPaper[1];
    return icon;
}
static const uint32_t kTones[6] = {0xBAA98C, 0xC3C0B7, 0xA6B198, 0x9EAEBC, 0xC48E6E, 0x57524C};
static NSString *const kToneNames[6] = {@"灰棕黄", @"铂金灰", @"鼠尾草绿", @"雾霾蓝", @"陶土橙", @"石墨黑"};

static CGImageRef IconT(void) { return ToneIcon(kTones[0]); }
static CGImageRef IconU(void) { gLeft = YES; CGImageRef icon = HousedCaseIcon(YES); gLeft = NO; return icon; }

static CGImageRef IconP(void) { return HousedTapeIcon(NO, 0); }
static CGImageRef IconQ(void) { return HousedTapeIcon(NO, 30); }
static CGImageRef IconR(void) { return HousedTapeIcon(YES, 30); }

static CGImageRef IconL(void) { return ShellIcon(0); }
static CGImageRef IconM(void) { return ShellIcon(1); }
static CGImageRef IconN(void) { return ShellIcon(2); }

static CGImageRef IconI(void) { return CaseIcon(NO, NO, YES); }
static CGImageRef IconJ(void) { return CaseIcon(YES, NO, NO); }
static CGImageRef IconK(void) { return CaseIcon(NO, YES, NO); }

static CGImageRef IconF(void) { return ComboIcon(YES, NO); }
static CGImageRef IconG(void) { return ComboIcon(NO, NO); }
static CGImageRef IconH(void) { return ComboIcon(YES, YES); }

#pragma mark - E 光环: soft-glow rings, drawn like the app's controls

static CGImageRef IconE(void) {
    Img im = ImgNew(S, S);
    const float R = 300, span = 140;
    const float ha = (90 - span) * (float)M_PI / 180, hx = 512 + 190 * cosf(ha), hy = 512 + 190 * sinf(ha);
    dispatch_apply(S, Q(), ^(size_t j) {
        for (int i = 0; i < S; i++) {
            float x = i + .5f, y = S - (float)j - .5f, dx = x - 512, dy = y - 512, d = hypotf(dx, dy), th = atan2f(dy, dx), r = d / R;
            RGB c = mixc(hex(0x1c1829), hex(0x07070c), powf(clampf(hypotf(x - 512, y - 700) / 760, 0, 1), .8f));
            float inside = clampf(R - d + .5f, 0, 1) * clampf(d - 44 + .5f, 0, 1);
            if (inside > 0) {
                RGB body = addc(hex(0x0d0c13), gray(.06f * powf(.5f + .5f * cosf(2 * (th - .6f)), 4)));
                if (r > .38f && r < .97f) body = addc(body, scalec(hsv(.82f - (r - .38f) / .59f * .95f, .6f, 1), .07f * gauss(axisdiff(th, 2.25f), .36f)));
                c = mixc(c, body, inside * .92f);
            }
            RGB light = gray(0);
            float e = fabsf(d - R);
            light = addc(light, addc(gray(.95f * gauss(d - R, 2.4f)), scalec(hsv(th / (2 * (float)M_PI) + .05f, .5f, 1), .42f * expf(-e / 13) + .20f * expf(-e / 45) + .07f * expf(-e / 130))));
            float eh = fabsf(d - 62);
            light = addc(light, scalec(hex(0xfff0de), .9f * gauss(d - 62, 2.0f) + .35f * expf(-eh / 11) + .12f * expf(-eh / 40)));
            float deg = fmodf(90 - th * 180 / (float)M_PI + 720, 360);
            if (deg <= span) {
                float s = deg / span, I = .2f + .8f * powf(s, 1.3f), ea = fabsf(d - 190);
                RGB ac = mixc(hex(0x7fb2ff), hex(0xe0a8ff), s);
                light = addc(light, scalec(mixc(ac, gray(1), .5f * gauss(d - 190, 1.8f)), I * (.9f * gauss(d - 190, 1.9f) + .32f * expf(-ea / 10) + .1f * expf(-ea / 34))));
            }
            float hd = hypotf(x - hx, y - hy);
            light = addc(light, addc(gray(.9f * gauss(hd, 7)), scalec(hex(0xe0a8ff), .5f * expf(-hd / 16) + .15f * expf(-hd / 50))));
            c = addc(c, light);
            float *p = Px(im, i, (int)j);
            p[0] = knee(c.r); p[1] = knee(c.g); p[2] = knee(c.b); p[3] = 1;
        }
    });
    CGImageRef content = ImgToCG(im);
    ImgFree(im);
    return Finish(Grain(content, .015f, 13), NO);
}

#pragma mark - Contact sheet

static void Sheet(CGImageRef *icons, int count, NSArray *names, NSArray *notes, NSString *title, NSString *subtitle, NSString *path) {
    const int W = 120 + count * 416, H = 1300;
    CGContextRef ctx = NewCtx(W, H);
    CGContextSetFillColorWithColor(ctx, cg(hex(0xf3f1ee), 1));
    CGContextFillRect(ctx, CGRectMake(0, 0, W, H));
    NSGraphicsContext *prev = NSGraphicsContext.currentContext;
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:NO];
    void (^text)(NSString *, NSFont *, RGB, CGFloat, CGFloat, CGFloat) = ^(NSString *s, NSFont *f, RGB c, CGFloat x, CGFloat yTop, CGFloat w) {
        NSMutableParagraphStyle *p = [NSMutableParagraphStyle new];
        p.lineSpacing = 4;
        NSAttributedString *a = [[NSAttributedString alloc] initWithString:s attributes:@{NSFontAttributeName: f, NSForegroundColorAttributeName: ns(c, 1), NSParagraphStyleAttributeName: p}];
        CGFloat h = ceil([a boundingRectWithSize:NSMakeSize(w, 400) options:NSStringDrawingUsesLineFragmentOrigin].size.height) + 2;
        [a drawInRect:NSMakeRect(x, H - yTop - h, w, h)];
    };
    text(title, [NSFont systemFontOfSize:34 weight:NSFontWeightSemibold], hex(0x222222), 64, 40, W - 128);
    text(subtitle, [NSFont systemFontOfSize:17], hex(0x777777), 64, 90, W - 128);
    for (int k = 0; k < count; k++) {
        CGFloat x = 60 + k * 416;
        CGContextDrawImage(ctx, CGRectMake(x, H - 130 - 416, 416, 416), icons[k]);
        text(names[k], [NSFont systemFontOfSize:24 weight:NSFontWeightSemibold], hex(0x222222), x + 44, 552, 360);
        text(notes[k], [NSFont systemFontOfSize:16], hex(0x6b6b6b), x + 44, 590, 336);
    }
    const int sizes[4] = {128, 64, 32, 16};
    CGImageRef smalls[8][4];
    for (int k = 0; k < count; k++) for (int m = 0; m < 4; m++) smalls[k][m] = Downscale(icons[k], sizes[m]);
    for (int s = 0; s < 2; s++) {
        CGFloat top = s == 0 ? 700 : 1000, h = 250;
        text(s == 0 ? @"浅色桌面 · 128 / 64 / 32 / 16 px" : @"深色桌面", [NSFont systemFontOfSize:15 weight:NSFontWeightMedium], hex(0x8a8a8a), 64, top - 32, 800);
        CGRect r = CGRectMake(60, H - top - h, W - 120, h);
        CGPathRef p = CGPathCreateWithRoundedRect(r, 22, 22, NULL);
        CGContextSaveGState(ctx); CGContextAddPath(ctx, p); CGContextClip(ctx);
        if (s == 0) Grad2(ctx, CGPointMake(60, CGRectGetMaxY(r)), CGPointMake(W - 60, r.origin.y), hex(0xdfe6f1), 1, hex(0xf1e7e4), 1);
        else Grad2(ctx, CGPointMake(60, CGRectGetMaxY(r)), CGPointMake(W - 60, r.origin.y), hex(0x1a1d27), 1, hex(0x2b2332), 1);
        CGContextRestoreGState(ctx);
        CGPathRelease(p);
        for (int k = 0; k < count; k++) {
            CGFloat x = 60 + k * 416 + 34, cy = CGRectGetMidY(r);
            for (int m = 0; m < 4; m++) {
                CGContextDrawImage(ctx, CGRectMake(x, cy - sizes[m] / 2, sizes[m], sizes[m]), smalls[k][m]);
                x += sizes[m] + 26;
            }
        }
    }
    text(@"小尺寸是从 1024 直接缩小的；正式做进 App 时 16 / 32 px 会单独调细节。", [NSFont systemFontOfSize:15], hex(0x999999), 64, 1266, W - 128);
    NSGraphicsContext.currentContext = prev;
    SavePNG(CtxImage(ctx), path);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *dir = argc > 1 ? @(argv[1]) : @".";
        NSString *only = argc > 2 ? @(argv[2]) : nil;
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        if ([only isEqualToString:@"label"]) { SavePNG(TapeLabel(), [dir stringByAppendingPathComponent:@"磁带标签-像素屏.png"]); return 0; }
        if ([only isEqualToString:@"grounds"]) {
            gStudyDir = dir;
            gSlim = YES;
            CGImageRef g[5];
            NSArray *names = @[@"0  现在", @"1  聚光", @"2  浅绿屏", @"3  暖灰底", @"4  点阵纹"];
            NSArray *notes = @[@"平的米色底，和封面纸几乎同色。",
                               @"盒子后面一团柔光，四角压暗，像放在展示柜里被灯照着。",
                               @"窗里变成像素屏的浅绿背光，带很淡的点阵，窗口就是一块屏。",
                               @"底色往外壳色靠一档，米白封面和透明盒更跳出来。",
                               @"米色底上加很淡的点阵纹，四角稍暗，呼应底边的 01。"];
            for (int k = 0; k < 5; k++) {
                gGroundStyle = k;
                g[k] = ToneIcon(kTones[0]);
                SavePNG(g[k], [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"底-%d.png", k]]);
            }
            gGroundStyle = 0;
            Sheet(g, 5, names, notes, @"窗里的底", @"边框和 CD 盒之间那块底的五种做法，其余都不变。",
                  [dir stringByAppendingPathComponent:@"CD-Glass-图标方案-窗里的底.png"]);
            printf("grounds done\n");
            return 0;
        }
        if ([only isEqualToString:@"big"]) {   // T at 2048 px, for the app's idle cover
            gStudyDir = dir;
            gSlim = YES;
            gBadge = 1;
            gScale = 2;
            SavePNG(ToneIcon(kTones[0]), [dir stringByAppendingPathComponent:@"T-细边框@2x.png"]);
            printf("big done\n");
            return 0;
        }
        if ([only isEqualToString:@"tones"]) {
            gStudyDir = dir;
            gSlim = YES;
            gBadge = 0;
            CGImageRef clean = ToneIcon(kTones[0]);
            SavePNG(clean, [dir stringByAppendingPathComponent:@"T-细边框-彩色标志.png"]);
            gBadge = 1;
            CGImageRef tones[6];
            NSMutableArray *names = [NSMutableArray new], *notes = [NSMutableArray new];
            for (int k = 0; k < 6; k++) {
                tones[k] = ToneIcon(kTones[k]);
                NSString *name = [NSString stringWithFormat:@"%d  %@", k + 1, kToneNames[k]];
                [names addObject:name];
                [notes addObject:[NSString stringWithFormat:@"外壳 #%06X%@", kTones[k], k == 0 ? @"，也就是现在的 T" : @""]];
                SavePNG(tones[k], [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"配色-%d-%@.png", k + 1, kToneNames[k]]]);
            }
            SavePNG(tones[0], [dir stringByAppendingPathComponent:@"T-细边框.png"]);
            Sheet(tones, 6, names, notes, @"T 的配色", @"上面和左右 50 px，底部 192 px，窗里是浅绿点阵屏：左下指示灯，中间单色印刷的 01，右下扬声器孔。",
                  [dir stringByAppendingPathComponent:@"CD-Glass-图标配色-细边框.png"]);
            CGImageRef pair[2] = {tones[0], clean};
            Sheet(pair, 2, @[@"T  单色标志", @"T  彩色标志（对照）"],
                  @[@"边框 50 px、底边 192 px，窗里浅绿点阵屏。", @"同样的边框，标志换成浅绿底的彩色印刷。"],
                  @"T 细边框", @"上面和左右收窄一半，底部保留原来边框的宽度，CD GLASS 去掉。",
                  [dir stringByAppendingPathComponent:@"CD-Glass-图标方案-T细边框.png"]);
            printf("tones done\n");
            return 0;
        }
        NSArray *files = @[@"A-玻璃槽", @"B-玻璃唱片", @"C-点阵屏", @"D-珠宝盒", @"E-光环", @"F-点阵珠宝盒", @"G-透明盒点阵", @"H-点阵珠宝盒深底",
                           @"I-封面C-浅底", @"J-封面C-深底", @"K-黑封面C-浅底", @"L-外壳包围-浅窗", @"M-外壳包围-烟熏窗", @"N-外壳做底",
                           @"P-外壳-磁带在盒里", @"Q-外壳-磁带滑出", @"R-外壳-黑磁带滑出", @"T-外壳-封面印磁带", @"U-外壳-封面印黑磁带"];
        CGImageRef (*makers[19])(void) = {IconA, IconB, IconC, IconD, IconE, IconF, IconG, IconH, IconI, IconJ, IconK, IconL, IconM, IconN, IconP, IconQ, IconR, IconT, IconU};
        CGImageRef icons[19] = {0};
        gStudyDir = dir;
        for (int k = 0; k < 19; k++) {
            NSString *letter = [@"ABCDEFGHIJKLMNPQRTU" substringWithRange:NSMakeRange(k, 1)];
            if (only && ![only containsString:letter]) continue;
            NSDate *t0 = [NSDate date];
            icons[k] = makers[k]();
            SavePNG(icons[k], [dir stringByAppendingPathComponent:[files[k] stringByAppendingString:@".png"]]);
            printf("%s %.2fs\n", letter.UTF8String, -t0.timeIntervalSinceNow);
        }
        if (icons[0] && icons[1] && icons[2] && icons[3] && icons[4])
            Sheet(icons, 5, @[@"A  玻璃槽", @"B  玻璃唱片", @"C  点阵屏", @"D  珠宝盒", @"E  光环"],
                  @[@"银色光盘插在一块磨砂玻璃里，下半截透过玻璃变糊。",
                    @"磨砂玻璃做的 CD 浮在彩色底上，macOS 26 液态玻璃的画法。",
                    @"0.12.1 的灰棕黄外壳做成整个图标，屏上是点阵光盘。",
                    @"CD 盒里滑出光盘，背景就是封面糊开的颜色。",
                    @"黑底发光圆环，和界面里的柔光按钮同一种画法。"],
                  @"CD Glass 图标方案", @"五个方向，都是代码画的 1024 px 原图；下面两条是放进 Dock / Finder 的实际像素大小。",
                  [dir stringByAppendingPathComponent:@"CD-Glass-图标方案.png"]);
        if (icons[5] && icons[6] && icons[7])
            Sheet(icons + 5, 3, @[@"F  点阵珠宝盒", @"G  透明盒 + 点阵", @"H  点阵珠宝盒 · 深底"],
                  @[@"D 的构图，盒子用 C 的灰棕黄磨砂塑料，封面是点阵屏上的日落。",
                    @"保留 D 的透明 CD 盒，只把封面插页换成点阵屏。",
                    @"和 F 一样，背景换成素色深棕。"],
                  @"C × D", @"D 的 CD 盒和光盘，封面换成 C 的点阵屏；背景改成素色。",
                  [dir stringByAppendingPathComponent:@"CD-Glass-图标方案-CxD.png"]);
        if (icons[8] && icons[9] && icons[10])
            Sheet(icons + 8, 3, @[@"I  浅底", @"J  深底", @"K  黑封面 · 浅底"],
                  @[@"米白封面上印着完整的 C，全透明的盒子放在浅米色底上。",
                    @"同一张封面，底换成素色深棕，盒子最跳。",
                    @"封面纸换成炭黑，C 的灰棕黄在上面最显眼。"],
                  @"C 印在 D 的封面上", @"D 的透明 CD 盒和滑出的光盘不变，封面插页印的是完整的 C 图标；背景都是素色。",
                  [dir stringByAppendingPathComponent:@"CD-Glass-图标方案-封面C.png"]);
        if (icons[11] && icons[12] && icons[13])
            Sheet(icons + 11, 3, @[@"L  外壳包围 · 浅窗", @"M  外壳包围 · 烟熏窗", @"N  外壳做底"],
                  @[@"灰棕黄外壳围一圈，中间凹进去的窗里是 I 的浅米色底。",
                    @"同样的外壳，窗里换成 C 屏幕那种烟熏深色玻璃。",
                    @"不开窗，盒子直接放在整块外壳上。"],
                  @"磁带屏 · 光盘收进去 · 外壳包围", @"封面上 C 的屏幕改成点阵磁带，光盘往盒里收了一截，外面用像素屏的灰棕黄外壳包住。",
                  [dir stringByAppendingPathComponent:@"CD-Glass-图标方案-外壳包围.png"]);
        if (icons[14] && icons[15] && icons[16])
            Sheet(icons + 14, 3, @[@"P  磁带在盒里", @"Q  磁带滑出", @"R  黑磁带滑出"],
                  @[@"C 的外壳，窗里是 I 的浅底和透明盒，盒里装着 App 的磁带。",
                    @"同上，磁带像 I 的光盘一样从盒子右边滑出一截。",
                    @"和 Q 一样，磁带换成深灰外壳那一款。"],
                  @"C 的外壳 · I 的透明盒 · 我们的磁带", @"磁带就是 App 里「卡带」风格那一盘（同一份绘制代码），标签上印着 C 的像素屏。",
                  [dir stringByAppendingPathComponent:@"CD-Glass-图标方案-外壳磁带.png"]);
        if (icons[17] && icons[18])
            Sheet(icons + 17, 2, @[@"T  封面印浅色磁带", @"U  封面印深色磁带"],
                  @[@"C 的外壳里是 I：透明 CD 盒，光盘露出一截，封面印着那盘磁带。",
                    @"同上，封面上印的是深灰外壳的那盘。"],
                  @"封面印着磁带", @"I 的透明盒和光盘不变，封面图案换成 App 渲染的磁带。",
                  [dir stringByAppendingPathComponent:@"CD-Glass-图标方案-封面磁带.png"]);
    }
    return 0;
}
