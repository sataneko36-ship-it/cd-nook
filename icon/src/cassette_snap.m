// Renders the app's own cassette (CDCassetteHero, "cover on the label" look) with a given label image,
// on a transparent background, so the icon uses exactly the tape the player shows.
// usage: cassette_snap <label.png> <out.png> [palette index]
#import <AppKit/AppKit.h>
#import <dlfcn.h>
#import "CDHeroes.h"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 3) return 1;
        NSString *labelPath = @(argv[1]), *outPath = @(argv[2]);
        NSInteger paletteIndex = argc > 3 ? atoi(argv[3]) : 6;
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        const CGFloat W = 1300, H = 900, cw = 1100, ch = cw * 63.8 / 100;
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(-9000, 0, W, H) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        window.opaque = NO;
        window.backgroundColor = NSColor.clearColor;
        window.hasShadow = NO;
        NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, W, H)];
        root.wantsLayer = YES;
        window.contentView = root;
        CDCassetteHero *hero = [[CDCassetteHero alloc] initWithFrame:NSMakeRect((W - cw) / 2, (H - ch) / 2, cw, ch)];
        [root addSubview:hero];
        NSImage *label = [[NSImage alloc] initWithContentsOfFile:labelPath];
        hero.palette = [CDPalette paletteAtIndex:paletteIndex];
        hero.np.hasSession = YES;
        hero.np.album = @"CD Nook";
        hero.np.count = 12;
        hero.np.trackProgress = .3;
        hero.np.albumProgress = .35;
        hero.coverColors = CDDominantColors(label, 3);
        hero.cover = label;
        hero.look = CDCassetteLookCoverLabel;
        [window orderFrontRegardless];
        [root layoutSubtreeIfNeeded];
        [hero nowPlayingChanged];
        [hero progressChanged];
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:3]];
        typedef CGImageRef (*Capture)(CGRect, uint32_t, uint32_t, uint32_t);
        Capture capture = (Capture)dlsym(RTLD_DEFAULT, "CGWindowListCreateImage");
        CGImageRef image = capture ? capture(CGRectNull, 1 << 3, (uint32_t)window.windowNumber, (1 << 0) | (1 << 3)) : NULL;
        if (!image) { fprintf(stderr, "capture failed\n"); return 2; }
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:image];
        printf("%zu x %zu\n", CGImageGetWidth(image), CGImageGetHeight(image));
        CGImageRelease(image);
        [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:outPath atomically:YES];
    }
    return 0;
}
