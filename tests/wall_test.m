// Album wall behaviour, off screen: grouping, the burst settling exactly where it was sent (nothing springs
// back upright afterwards), blank-click collapse, and picking a CD.
// Build: clang -fobjc-arc -fmodules -mmacosx-version-min=26.0 tests/wall_test.m CDViews.m CDTheme.m CDVolumes.m -o wall_test \
//        -framework AppKit -framework QuartzCore -framework CoreImage
#import "../CDAlbumWall.m"
#include <assert.h>

static void Pump(double seconds) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (end.timeIntervalSinceNow > 0) [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
}
static NSEvent *Mouse(NSEventType type, NSWindow *window, NSPoint p) {
    return [NSEvent mouseEventWithType:type location:p modifierFlags:0 timestamp:0 windowNumber:window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
}

int main(void) { @autoreleasepool {
    [NSApplication sharedApplication];
    for (NSValue *size in @[[NSValue valueWithSize:NSMakeSize(1180, 740)], [NSValue valueWithSize:NSMakeSize(1728, 1117)], [NSValue valueWithSize:NSMakeSize(820, 540)]]) {
        NSWindow *window = [[NSWindow alloc] initWithContentRect:(NSRect){NSMakePoint(-9000, 0), size.sizeValue} styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        window.releasedWhenClosed = NO;
        CDAlbumWall *wall = [[CDAlbumWall alloc] initWithFrame:(NSRect){NSZeroPoint, size.sizeValue}];
        window.contentView = wall;
        [window orderFrontRegardless];
        wall.palette = [CDPalette paletteAtIndex:4];
        NSMutableArray *albums = [NSMutableArray new];
        for (NSUInteger i = 0; i < 8; i++) [albums addObject:@{@"id": [NSString stringWithFormat:@"a%lu", i], @"animeKey": @"series", @"animeTitle": @"シリーズ", @"album": [NSString stringWithFormat:@"Album %lu", i], @"sourcePath": [NSString stringWithFormat:@"/nowhere/[%lu] disc", i], @"audioFiles": @4}];
        for (NSUInteger i = 0; i < 3; i++) [albums addObject:@{@"id": [NSString stringWithFormat:@"s%lu", i], @"animeKey": [NSString stringWithFormat:@"single%lu", i], @"animeTitle": [NSString stringWithFormat:@"Single %lu", i], @"album": @"Only", @"sourcePath": @"/nowhere/x"}];
        wall.albums = albums;
        [wall layoutSubtreeIfNeeded];
        assert(wall.items.count == 4);
        wall.grouped = NO; assert(wall.items.count == 11);
        wall.grouped = YES; assert(wall.items.count == 4);
        [wall layoutSubtreeIfNeeded];
        NSInteger stack = -1;
        for (NSUInteger i = 0; i < wall.items.count; i++) if (wall.items[i].albums.count == 8) stack = i;
        assert(stack >= 0 && wall.live[@(stack)]);

        __block NSDictionary *played = nil;
        wall.onPlay = ^(NSDictionary *album) { played = album; };
        [wall activate:stack];
        assert(wall.expanded && wall.cards.count == 8);
        Pump(2.6);                                   // springs settled, blur wave finished
        CGRect area = CGRectInset(wall.bounds, 10, 10);
        for (CDWBurstCard *card in wall.cards) {
            CALayer *mover = card.mover.presentationLayer, *spinner = card.spinner.presentationLayer, *scaler = card.scaler.presentationLayer;
            assert(mover && hypot(mover.position.x - card.home.x, mover.position.y - card.home.y) < .5);
            assert(fabs([[spinner valueForKeyPath:@"transform.rotation.z"] doubleValue] - card.tilt) < .002);
            assert(fabs([[scaler valueForKeyPath:@"transform.scale"] doubleValue] - 1) < .002);
            assert(fabs(card.tilt) <= CDWRad(12.01));          // bounded tilt; every sleeve still faces the viewer
            assert(CGRectContainsPoint(area, card.home));
            assert([wall cardAtPoint:card.home] == card);
        }
        // Once removed, the animations leave the model exactly where the spring ended.
        for (CDWBurstCard *card in wall.cards) {
            [card.spinner removeAllAnimations]; [card.mover removeAllAnimations];
            assert(fabs([[card.spinner valueForKeyPath:@"transform.rotation.z"] doubleValue] - card.tilt) < .0001);
        }
        // A click on empty space folds the stack back.
        NSPoint blank = NSMakePoint(4, NSHeight(wall.bounds) - 4);
        assert(![wall cardAtPoint:[wall convertPoint:blank fromView:nil]]);
        [wall mouseDown:Mouse(NSEventTypeLeftMouseDown, window, blank)];
        [wall mouseUp:Mouse(NSEventTypeLeftMouseUp, window, blank)];
        Pump(.8);
        assert(!wall.expanded && wall.cards.count == 0 && !wall.live[@(stack)].root.hidden);
        assert(![wall dismissExpansion]);

        [wall activate:stack];
        Pump(1.2);
        CDWBurstCard *pick = wall.cards[3];
        // The player could not load it (its disk did not answer): the CD settles back among the others.
        [wall launch:pick];
        Pump(.3);
        assert([played[@"id"] isEqualToString:@"a3"] && wall.leaving);
        [wall cancelLaunch];
        Pump(1);
        assert(wall.expanded && !wall.leaving && wall.cards.count == 8);
        CGPoint back = pick.mover.presentationLayer ? pick.mover.presentationLayer.position : pick.mover.position;
        assert(hypot(back.x - pick.home.x, back.y - pick.home.y) < 2 && pick.mover.opacity > .99);
        for (CDWBurstCard *other in wall.cards) assert(other.mover.opacity > .99);
        played = nil;
        [wall launch:pick];
        Pump(.3);
        assert([played[@"id"] isEqualToString:@"a3"]);
        [wall dismissAnimated:NO completion:nil];
        assert(wall.hidden && wall.cards.count == 0);
        [window close];
    }
    NSLog(@"Wall: grouping, burst settles in place with bounded tilt, blank-click collapse, pick → play passed at 3 sizes");
} }
