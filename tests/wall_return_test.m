// A played CD returns to its original expanded series rather than the wall grid.
// Build: clang -fobjc-arc -fmodules -mmacosx-version-min=26.0 tests/wall_return_test.m CDViews.m CDTheme.m CDVolumes.m \
//        -o wall_return_test -framework AppKit -framework QuartzCore -framework CoreImage
#import "../CDAlbumWall.m"
#include <assert.h>

int main(void) { @autoreleasepool {
    [NSApplication sharedApplication];
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(-9000, 0, 1180, 740)
                                                       styleMask:NSWindowStyleMaskBorderless
                                                         backing:NSBackingStoreBuffered defer:NO];
    CDAlbumWall *wall = [[CDAlbumWall alloc] initWithFrame:window.contentView.bounds];
    window.contentView = wall;
    wall.palette = [CDPalette paletteAtIndex:4];
    NSMutableArray *albums = [NSMutableArray new];
    for (NSUInteger i = 0; i < 3; i++) {
        [albums addObject:@{@"id":[NSString stringWithFormat:@"cd%lu", (unsigned long)i],
                            @"animeKey":@"original-series", @"animeTitle":@"Series",
                            @"album":[NSString stringWithFormat:@"CD %lu", (unsigned long)i],
                            @"sourcePath":[NSString stringWithFormat:@"/example/cd%lu", (unsigned long)i]}];
    }
    wall.albums = albums;
    [wall presentAnimated:NO];
    [wall layoutSubtreeIfNeeded];
    assert(wall.items.count == 1);
    [wall activate:0];
    assert(wall.expanded);
    NSString *key = wall.expandedStackKey;
    assert([key isEqualToString:@"original-series"]);
    [wall dismissAnimated:NO completion:nil];
    assert(!wall.expanded && wall.hidden);
    [wall presentAnimated:NO];
    assert([wall expandStackWithKey:key]);
    assert(wall.expanded && wall.cards.count == 3);
    assert([wall.expandedStackKey isEqualToString:key]);
    // The animated way back: the wall shows itself with the same stack open, the CD that was playing among the cards.
    [wall dismissAnimated:NO completion:nil];
    CGImageRef page = CDWDraw(CGSizeMake(1180, 740), 1, ^(CGContextRef ctx) { CGContextSetGrayFillColor(ctx, .5, 1); CGContextFillRect(ctx, CGRectMake(0, 0, 1180, 740)); });
    assert([wall returnToStackWithKey:key albumID:@"cd1" page:page cover:NSMakeRect(440, 180, 300, 300)]);
    CGImageRelease(page);
    assert(!wall.hidden && wall.expanded && wall.cards.count == 3);
    assert([wall.expandedStackKey isEqualToString:key]);
    NSUInteger landing = NSNotFound;
    for (NSUInteger i = 0; i < wall.cards.count; i++) if ([wall.cards[i].album[@"id"] isEqualToString:@"cd1"]) landing = i;
    assert(landing != NSNotFound && wall.cards[landing].mover.zPosition == 500);   // the returning CD rides on top
    [wall dismissAnimated:NO completion:nil];
    assert(![wall returnToStackWithKey:@"no-such-series" albumID:nil page:NULL cover:NSZeroRect]);
    // A CD picked from the open stack while the player goes full screen: the window grows mid-fade, which clears the
    // cards — the wall must still finish hiding. It used to stay up for good, covering the player's cover page.
    [wall presentAnimated:NO];
    assert([wall expandStackWithKey:key]);
    __block BOOL gone = NO;
    wall.onPlay = ^(NSDictionary *album) {
        [wall dismissAnimated:YES completion:^{ gone = YES; }];
        [window setFrame:NSMakeRect(-9000, 0, 1440, 900) display:YES];
        [wall layoutSubtreeIfNeeded];
    };
    [wall launch:wall.cards[0]];
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:3];
    while (!gone && until.timeIntervalSinceNow > 0) [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
    assert(gone && wall.hidden);
    NSLog(@"Wall return to the original expanded stack passed (also when the window resizes as it closes)");
    // AppKit's off-screen animation callbacks outlive this short-lived fixture.
    exit(0);
} }
