// Checks where the CDs of a stack land: no overlaps, inside the window, clear of the title.
// Build: see tests/wall_test.sh. With OUT=dir it also draws each layout to a PNG.
#import <AppKit/AppKit.h>
#import "../CDAlbumWall.h"

int main(void) { @autoreleasepool {
    NSString *out = NSProcessInfo.processInfo.environment[@"OUT"];
    NSArray *sizes = @[[NSValue valueWithSize:NSMakeSize(1600, 1000)], [NSValue valueWithSize:NSMakeSize(1180, 740)], [NSValue valueWithSize:NSMakeSize(820, 540)], [NSValue valueWithSize:NSMakeSize(2560, 1440)]];
    NSArray *counts = @[@2, @3, @4, @6, @9, @12, @20, @37];
    int failures = 0, drawn = 0;
    for (NSValue *sv in sizes) {
        NSSize size = sv.sizeValue;
        CGRect area = CGRectMake(44, 62, size.width - 88, size.height - 88);
        NSArray *origins = @[[NSValue valueWithPoint:NSMakePoint(size.width * .12, 240)], [NSValue valueWithPoint:NSMakePoint(size.width * .5, size.height * .5)], [NSValue valueWithPoint:NSMakePoint(size.width * .9, size.height * .85)]];
        for (NSNumber *count in counts) for (NSValue *ov in origins) {
            CDWBurstGeometry g;
            NSArray *spots = CDWBurstLayout(count.unsignedIntegerValue, ov.pointValue, area, CGSizeMake(260, 64), [NSString stringWithFormat:@"series-%@", count], &g);
            CGFloat bw = g.side, bh = g.side + g.caption;
            BOOL ok = spots.count == count.unsignedIntegerValue;
            for (NSUInteger i = 0; i < spots.count; i++) {
                NSPoint p = [spots[i] pointValue];
                if (p.x - bw / 2 < area.origin.x - 2 || p.x + bw / 2 > CGRectGetMaxX(area) + 2 || p.y - bh / 2 < area.origin.y - 2 || p.y + bh / 2 > CGRectGetMaxY(area) + 2) ok = NO;
                if (CGRectIntersectsRect(CGRectInset(CGRectMake(p.x - bw / 2, p.y - bh / 2, bw, bh), 2, 2), g.titleRect)) ok = NO;
                for (NSUInteger j = i + 1; j < spots.count; j++) {
                    NSPoint q = [spots[j] pointValue];
                    if (fabs(p.x - q.x) < bw + 6 && fabs(p.y - q.y) < bh + 6) ok = NO;
                }
            }
            CGFloat shift = hypot(g.center.x - ov.pointValue.x, g.center.y - ov.pointValue.y);
            printf("%4.0fx%-4.0f n=%2lu origin(%4.0f,%4.0f) side %5.1f cap %2.0f shift %5.1f %s\n", size.width, size.height, (unsigned long)spots.count, ov.pointValue.x, ov.pointValue.y, g.side, g.caption, shift, ok ? "ok" : "FAIL");
            if (!ok) failures++;
            if (out.length && size.width == 1600) {
                NSImage *image = [NSImage imageWithSize:size flipped:YES drawingHandler:^BOOL(NSRect r) {
                    [[NSColor colorWithWhite:.95 alpha:1] setFill]; NSRectFill(r);
                    [[NSColor colorWithRed:.8 green:.3 blue:.3 alpha:1] setStroke]; [NSBezierPath strokeRect:area];
                    [[NSColor colorWithRed:.2 green:.4 blue:.9 alpha:.35] setFill]; [NSBezierPath fillRect:g.titleRect];
                    for (NSValue *v in spots) { NSPoint p = v.pointValue; [[NSColor colorWithWhite:.3 alpha:.6] setFill]; NSRectFill(NSMakeRect(p.x - bw / 2, p.y - bh / 2, bw, g.side)); }
                    [[NSColor redColor] setFill]; NSRectFill(NSMakeRect(ov.pointValue.x - 6, ov.pointValue.y - 6, 12, 12));
                    return YES;
                }];
                NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithData:image.TIFFRepresentation];
                [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[out stringByAppendingFormat:@"/n%02d_%d.png", count.intValue, drawn++ % 3] atomically:YES];
            }
        }
    }
    printf("%d failures\n", failures);
    return failures ? 1 : 0;
} }
