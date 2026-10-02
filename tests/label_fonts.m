// Renders the app's own cassette (CDCassetteHero) with each candidate label hand, for picking one.
// usage: label_fonts <out-dir> <palette> <look> <cover> <title> [<look> <cover> <title> …]
// Build: clang -fobjc-arc -fmodules -mmacosx-version-min=26.0 -I . tests/label_fonts.m CDHeroes.m CDTheme.m CDViews.m CDPixelArt.m \
//        -o label_fonts -framework AppKit -framework QuartzCore -framework CoreImage -framework Vision
#import <AppKit/AppKit.h>
#import <dlfcn.h>
#import "CDHeroes.h"

typedef struct { const char *tag; NSArray<NSString *> *names; CGFloat scale; } Hand;

static void Pump(double seconds) { [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]]; }

int main(int argc, const char *argv[]) { @autoreleasepool {
    if (argc < 6 || (argc - 3) % 3) { fprintf(stderr, "usage: label_fonts <out-dir> <palette> (<look> <cover> <title>)…\n"); return 1; }
    NSString *dir = @(argv[1]);
    NSInteger palette = atoi(argv[2]);
    Hand hands[] = {
        {"0-Klee", @[@"Klee-Demibold"], 1},
        {"1-Hannotate", @[@"HannotateSC-W5"], .95},
        {"2-HanziPen", @[@"HanziPenSC-W5"], 1},
        {"3-Yuppy", @[@"YuppySC-Regular"], .95},
        {"4-HiraMaru", @[@"HiraMaruProN-W4"], .86},
        {"5-Typewriter", @[@"AmericanTypewriter-Semibold", @"ToppanBunkyuMinchoPr6N-Regular"], .9},
        {"6-BunkyuMidashi", @[@"ToppanBunkyuMidashiMinchoStdN-ExtraBold"], .84},
        {"7-Kaiti", @[@"STKaitiSC-Bold"], 1.05},
        {"8-MarkerFelt", @[@"MarkerFelt-Wide", @"HannotateSC-W5"], .95},
    };
    const int count = sizeof hands / sizeof hands[0];
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    const CGFloat W = 1300, H = 900, cw = 1100, ch = cw * 63.8 / 100;
    typedef CGImageRef (*Capture)(CGRect, uint32_t, uint32_t, uint32_t);
    Capture capture = (Capture)dlsym(RTLD_DEFAULT, "CGWindowListCreateImage");
    for (int s = 3; s + 2 < argc; s += 3) {
        NSInteger look = atoi(argv[s]);
        NSImage *cover = [[NSImage alloc] initWithContentsOfFile:@(argv[s + 1])];
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(-9000, 0, W, H) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        window.opaque = NO; window.backgroundColor = NSColor.clearColor; window.hasShadow = NO;
        NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, W, H)];
        root.wantsLayer = YES;
        window.contentView = root;
        CDCassetteHero *hero = [[CDCassetteHero alloc] initWithFrame:NSMakeRect((W - cw) / 2, (H - ch) / 2, cw, ch)];
        [root addSubview:hero];
        CDSetLabelFont(nil, 1);
        hero.palette = [CDPalette paletteAtIndex:palette];
        hero.np.hasSession = YES;
        hero.np.album = @(argv[s + 2]);
        hero.np.count = 10; hero.np.trackProgress = .3; hero.np.albumProgress = .35;
        hero.coverColors = CDDominantColors(cover, 3);
        hero.cover = cover;
        hero.look = look;
        [window orderFrontRegardless];
        [root layoutSubtreeIfNeeded];
        [hero nowPlayingChanged]; [hero progressChanged];
        Pump(3);                                            // the subject lift settles the print's crop
        for (int h = 0; h < count; h++) {
            CDSetLabelFont(hands[h].names, hands[h].scale);
            [hero nowPlayingChanged];
            Pump(.8);                                       // past the label's .35 s cross-fade
            CGImageRef image = capture ? capture(CGRectNull, 1 << 3, (uint32_t)window.windowNumber, (1 << 0) | (1 << 3)) : NULL;
            if (!image) { fprintf(stderr, "capture failed\n"); return 2; }
            NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:image];
            CGImageRelease(image);
            NSString *out = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"s%d-%s.png", (s - 3) / 3, hands[h].tag]];
            [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:out atomically:YES];
        }
        [window orderOut:nil];
    }
    printf("done\n");
} return 0; }
