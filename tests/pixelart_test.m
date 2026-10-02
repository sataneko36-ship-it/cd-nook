// Renders covers through CDPixelArt and writes a contact sheet: source and the pixel art (as LCD dots).
// PXSIZE=48 renders at another size (default 72).
// Usage: pixelart_test out.png cover1.jpg cover2.jpg …
#import "../CDPixelArt.h"

static void DrawDots(CGContextRef ctx, NSData *art, int n, CGRect box) {
    // Same look as the LCD: lit cells in ink, and the 1-px gaps between cells tinted a little toward the ink.
    const uint8_t *ink = art.bytes;
    CGFloat pitch = box.size.width / n, bg[3] = {.953, .820, .867}, fg[3] = {.29, .11, .18};
    for (int y = 0; y < n; y++) for (int x = 0; x < n; x++) {
        CGFloat s = ink[y * n + x], g = s * .62 + (1 - s) * .07;
        CGRect cell = CGRectMake(box.origin.x + x * pitch, box.origin.y + box.size.height - (y + 1) * pitch, pitch, pitch);
        CGContextSetRGBFillColor(ctx, bg[0] + (fg[0] - bg[0]) * g, bg[1] + (fg[1] - bg[1]) * g, bg[2] + (fg[2] - bg[2]) * g, 1);
        CGContextFillRect(ctx, cell);
        CGContextSetRGBFillColor(ctx, bg[0] + (fg[0] - bg[0]) * s, bg[1] + (fg[1] - bg[1]) * s, bg[2] + (fg[2] - bg[2]) * s, 1);
        CGContextFillRect(ctx, CGRectMake(cell.origin.x, cell.origin.y + 1, pitch - 1, pitch - 1));
    }
}

int main(int argc, const char **argv) { @autoreleasepool {
    if (argc < 3) return 1;
    int rows = argc - 2, cell = 432, gap = 12;
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(NULL, 2 * (cell + gap), rows * (cell + gap), 8, 0, srgb, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGContextSetRGBFillColor(ctx, .92, .92, .92, 1);
    CGContextFillRect(ctx, CGRectMake(0, 0, 2 * (cell + gap), rows * (cell + gap)));
    for (int r = 0; r < rows; r++) {
        NSImage *image = [[NSImage alloc] initWithContentsOfFile:@(argv[r + 2])];
        CGImageRef cg = [image CGImageForProposedRect:NULL context:nil hints:nil];
        CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
        CGImageRef mask = CDCreateSubjectMask(cg);
        CFAbsoluteTime t1 = CFAbsoluteTimeGetCurrent();
        int side = getenv("PXSIZE") ? atoi(getenv("PXSIZE")) : 72;
        NSData *art = CDPixelArtRender(cg, mask, side, NO);
        CFAbsoluteTime t2 = CFAbsoluteTimeGetCurrent();
        printf("%s mask %s %.0f ms, render %.0f ms\n", argv[r + 2], mask ? "yes" : "no", (t1 - t0) * 1000, (t2 - t1) * 1000);
        CGFloat top = (rows - 1 - r) * (cell + gap);
        size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg), e = MIN(w, h);
        CGImageRef sq = CGImageCreateWithImageInRect(cg, CGRectMake((w - e) / 2, (h - e) / 2, e, e));
        CGContextDrawImage(ctx, CGRectMake(0, top, cell, cell), sq);
        CGImageRelease(sq);
        DrawDots(ctx, art, side, CGRectMake(cell + gap, top, cell, cell));
        if (mask) CGImageRelease(mask);
    }
    CGImageRef sheet = CGBitmapContextCreateImage(ctx);
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:sheet];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@(argv[1]) atomically:YES];
    CGImageRelease(sheet); CGContextRelease(ctx); CGColorSpaceRelease(srgb);
    return 0;
}}
