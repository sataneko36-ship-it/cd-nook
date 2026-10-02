// Snapshot harness, compiled only into the silent test copy (tests/snapshot.sh, -DCDGLASS_SNAPSHOT).
// PLAN is a space-separated script, e.g. "size:1920x1080 style:2 load wait:3 snap:cassette quit".
#import "../CDApp.h"
#import <dlfcn.h>
#import <QuartzCore/QuartzCore.h>
#import <ImageIO/ImageIO.h>

@interface CDApp (SnapshotPrivate)
- (void)selectStyle:(NSMenuItem *)sender;
- (void)selectTheme:(NSMenuItem *)sender;
- (void)selectBackground:(NSMenuItem *)sender;
- (void)toggleList:(id)sender;
- (void)closeCandidatePanel:(id)sender;
- (void)showAlbumWall:(id)sender;
- (void)closeAlbumWall:(id)sender;
- (void)setGlobalBlurPercent:(double)percent on:(BOOL)on;
- (void)showBlurPanel:(id)sender;
@end

@implementation CDApp (Snapshot)

- (void)snapWindow:(NSWindow *)window name:(NSString *)name {
    NSString *dir = NSProcessInfo.processInfo.environment[@"CDGLASS_SNAP"];
    typedef CGImageRef (*Capture)(CGRect, uint32_t, uint32_t, uint32_t);
    Capture capture = (Capture)dlsym(RTLD_DEFAULT, "CGWindowListCreateImage");
    CGImageRef image = capture ? capture(CGRectNull, 1 << 3, (uint32_t)window.windowNumber, (1 << 0) | (1 << 3)) : NULL;
    if (!image) { NSLog(@"snapshot %@ failed", name); return; }
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:image];
    CGImageRelease(image);
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[dir stringByAppendingPathComponent:[name stringByAppendingString:@".png"]] atomically:YES];
}

- (NSMenuItem *)itemWithTag:(NSInteger)tag { NSMenuItem *item = [NSMenuItem new]; item.tag = tag; return item; }

- (void)runPlan:(NSArray<NSString *> *)plan index:(NSUInteger)index {
    if (index >= plan.count) { [NSApp terminate:nil]; return; }
    NSString *step = plan[index];
    NSArray *parts = [step componentsSeparatedByString:@":"];
    NSString *verb = parts.firstObject, *arg = parts.count > 1 ? parts[1] : @"";
    double delay = .4;
    if ([verb isEqualToString:@"size"]) {
        NSArray *wh = [arg componentsSeparatedByString:@"x"];
        // Render far off-screen so the test never covers the user's desktop.
        [self.window setFrame:NSMakeRect(-9000, 0, [wh[0] doubleValue], [wh[1] doubleValue]) display:YES];
    } else if ([verb isEqualToString:@"style"]) [self selectStyle:[self itemWithTag:arg.integerValue]];
    else if ([verb isEqualToString:@"theme"]) [self selectTheme:[self itemWithTag:arg.integerValue]];
    else if ([verb isEqualToString:@"bg"]) [self selectBackground:[self itemWithTag:arg.integerValue]];
    else if ([verb isEqualToString:@"load"]) [self loadVirtual:[NSURL fileURLWithPath:arg.length ? arg : NSProcessInfo.processInfo.environment[@"FOLDER"]]];
    else if ([verb isEqualToString:@"demo"]) [self playDemo:nil];
    else if ([verb isEqualToString:@"end"]) [self endSession:nil];
    else if ([verb isEqualToString:@"wait"]) delay = arg.doubleValue;
    else if ([verb isEqualToString:@"snap"]) [self snapWindow:self.window name:arg];
    else if ([verb isEqualToString:@"panel"]) [self showCandidateCovers:nil];
    else if ([verb isEqualToString:@"snappanel"]) { if (self.candidatePanel) [self snapWindow:self.candidatePanel name:arg]; }
    else if ([verb isEqualToString:@"closepanel"]) [self closeCandidatePanel:nil];
    else if ([verb isEqualToString:@"chrome"]) [self setChromeHidden:arg.boolValue animated:NO];
    else if ([verb isEqualToString:@"list"]) [self toggleList:nil];
    else if ([verb isEqualToString:@"look"]) { if ([self.hero isKindOfClass:CDCassetteHero.class]) ((CDCassetteHero *)self.hero).look = arg.integerValue; }
    else if ([verb isEqualToString:@"hoverlist"]) [self.trackList mouseEntered:[NSEvent new]];
    else if ([verb isEqualToString:@"scrolllist"]) {
        // Sends a wheel event to whatever sits under the list's centre, as a real wheel would.
        CGEventRef wheel = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitPixel, 1, -(int32_t)arg.integerValue);
        NSEvent *event = [NSEvent eventWithCGEvent:wheel];
        CFRelease(wheel);
        NSPoint centre = [self.stage convertPoint:NSMakePoint(NSMidX(self.trackList.frame), NSMidY(self.trackList.frame)) toView:self.stage.superview];
        NSView *target = [self.stage hitTest:centre];
        [target scrollWheel:event];
    }
    else if ([verb isEqualToString:@"screen"]) { if ([self.hero isKindOfClass:CDPixelScreenView.class]) ((CDPixelScreenView *)self.hero).screen = arg.integerValue; }
    else if ([verb isEqualToString:@"pause"]) { SEL s = NSSelectorFromString(@"togglePlayback:"); ((void (*)(id, SEL, id))[self methodForSelector:s])(self, s, nil); }
    else if ([verb isEqualToString:@"fs"]) [self.window toggleFullScreen:nil];
    else if ([verb isEqualToString:@"cpu"]) { system([[NSString stringWithFormat:@"ps -o %%cpu= -p %d >> '%@/cpu.txt'", getpid(), NSProcessInfo.processInfo.environment[@"CDGLASS_SNAP"]] UTF8String]); }
    else if ([verb isEqualToString:@"seek"]) { SEL s = NSSelectorFromString(@"seekToFraction:"); ((void (*)(id, SEL, double))[self methodForSelector:s])(self, s, arg.doubleValue); }
    else if ([verb isEqualToString:@"next"]) { SEL s = NSSelectorFromString(@"next:"); ((void (*)(id, SEL, id))[self methodForSelector:s])(self, s, nil); }
    else if ([verb isEqualToString:@"wake"]) { SEL s = NSSelectorFromString(@"userActivity"); ((void (*)(id, SEL))[self methodForSelector:s])(self, s); }
    else if ([verb isEqualToString:@"wall"]) { [self showAlbumWall:nil]; delay = .02; }
    else if ([verb isEqualToString:@"wallclose"]) [self closeAlbumWall:nil];
    else if ([verb isEqualToString:@"wallexpand"]) { delay = .02; SEL s = NSSelectorFromString(@"snapshotExpandGroup:"); if ([self.albumWall respondsToSelector:s]) ((void (*)(id, SEL, NSInteger))[self.albumWall methodForSelector:s])(self.albumWall, s, arg.integerValue); }
    else if ([verb isEqualToString:@"wallexpandt"]) { delay = .02; SEL s = NSSelectorFromString(@"snapshotExpandTitle:"); if ([self.albumWall respondsToSelector:s]) ((void (*)(id, SEL, NSString *))[self.albumWall methodForSelector:s])(self.albumWall, s, arg); }
    else if ([verb isEqualToString:@"wallcollapse"]) { [self.albumWall dismissExpansion]; delay = .02; }
    else if ([verb isEqualToString:@"wallhover"]) { SEL s = NSSelectorFromString(@"snapshotHoverItem:"); if ([self.albumWall respondsToSelector:s]) ((void (*)(id, SEL, NSInteger))[self.albumWall methodForSelector:s])(self.albumWall, s, arg.integerValue); }
    else if ([verb isEqualToString:@"wallpick"]) { delay = .02; SEL s = NSSelectorFromString(@"snapshotPickItem:"); if ([self.albumWall respondsToSelector:s]) ((void (*)(id, SEL, NSInteger))[self.albumWall methodForSelector:s])(self.albumWall, s, arg.integerValue); }
    else if ([verb isEqualToString:@"wallscroll"]) { SEL s = NSSelectorFromString(@"snapshotScrollBy:"); if ([self.albumWall respondsToSelector:s]) ((void (*)(id, SEL, CGFloat))[self.albumWall methodForSelector:s])(self.albumWall, s, arg.doubleValue); }
    else if ([verb isEqualToString:@"burst"]) {
        // burst:name,count,interval — a quick run of frames to judge motion.
        NSArray *a = [arg componentsSeparatedByString:@","];
        NSInteger n = a.count > 1 ? [a[1] integerValue] : 8; double dt = a.count > 2 ? [a[2] doubleValue] : .1;
        for (NSInteger i = 0; i < n; i++) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * dt * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self snapWindow:self.window name:[NSString stringWithFormat:@"%@_%02ld", a[0], (long)i]]; });
        delay = n * dt + .05;
    }
    else if ([verb isEqualToString:@"burstfast"]) {
        // burstfast:name,count,interval — like burst, at nominal resolution (much quicker to capture), each frame
        // named by the milliseconds actually elapsed, since a capture can hold up the next one.
        NSArray *a = [arg componentsSeparatedByString:@","];
        NSInteger n = a.count > 1 ? [a[1] integerValue] : 8; double dt = a.count > 2 ? [a[2] doubleValue] : .05;
        CFTimeInterval start = CACurrentMediaTime();
        for (NSInteger i = 0; i < n; i++) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * dt * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            typedef CGImageRef (*Capture)(CGRect, uint32_t, uint32_t, uint32_t);
            Capture capture = (Capture)dlsym(RTLD_DEFAULT, "CGWindowListCreateImage");
            int ms = (int)round((CACurrentMediaTime() - start) * 1000);
            CGImageRef image = capture ? capture(CGRectNull, 1 << 3, (uint32_t)self.window.windowNumber, (1 << 0) | (1 << 4)) : NULL;
            if (!image) return;
            NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:image];
            CGImageRelease(image);
            NSString *dir = NSProcessInfo.processInfo.environment[@"CDGLASS_SNAP"];
            [[rep representationUsingType:NSBitmapImageFileTypeJPEG properties:@{NSImageCompressionFactor: @.8}] writeToFile:[dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_%02ld_%04dms.jpg", a[0], (long)i, ms]] atomically:NO];
        });
        delay = n * dt + .05;
    }
    // pickcand:N uses candidate cover N (as a click in the candidate panel); coverenv:NAME sets the image at $NAME as the cover.
    else if ([verb isEqualToString:@"pickcand"]) { SEL s = NSSelectorFromString(@"selectCandidateAtIndex:"); ((void (*)(id, SEL, NSUInteger))[self methodForSelector:s])(self, s, (NSUInteger)arg.integerValue); }
    else if ([verb isEqualToString:@"coverenv"]) { SEL s = NSSelectorFromString(@"applyManualCoverFromURL:"); ((void (*)(id, SEL, NSURL *))[self methodForSelector:s])(self, s, [NSURL fileURLWithPath:NSProcessInfo.processInfo.environment[arg]]); }
    // loadalbum:N plays the folder in $ALBUM_N (paths have spaces, which a plan cannot hold).
    else if ([verb isEqualToString:@"loadalbum"]) [self loadVirtual:[NSURL fileURLWithPath:NSProcessInfo.processInfo.environment[[@"ALBUM_" stringByAppendingString:arg]] isDirectory:YES]];
    // record:name,seconds[,fps[,2x]] — frames grabbed off the main thread (so the page's own animation is not held up)
    // into <snap>/<name>/, each named by the milliseconds since the start; the plan carries on meanwhile.
    else if ([verb isEqualToString:@"record"]) {
        NSArray *a = [arg componentsSeparatedByString:@","];
        NSString *dir = [NSProcessInfo.processInfo.environment[@"CDGLASS_SNAP"] stringByAppendingPathComponent:a[0]];
        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        double seconds = a.count > 1 ? [a[1] doubleValue] : 5, fps = a.count > 2 ? [a[2] doubleValue] : 30;
        uint32_t options = (1 << 0) | (a.count > 3 && [a[3] isEqualToString:@"2x"] ? (1 << 3) : (1 << 4));
        uint32_t window = (uint32_t)self.window.windowNumber;
        typedef CGImageRef (*Capture)(CGRect, uint32_t, uint32_t, uint32_t);
        Capture capture = (Capture)dlsym(RTLD_DEFAULT, "CGWindowListCreateImage");
        static dispatch_queue_t writers; static dispatch_once_t once;
        dispatch_once(&once, ^{ writers = dispatch_queue_create("snapshot.writers", DISPATCH_QUEUE_CONCURRENT); });
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            CFTimeInterval start = CACurrentMediaTime();
            dispatch_semaphore_t room = dispatch_semaphore_create(6);
            for (NSInteger i = 0; ; i++) {
                CFTimeInterval due = start + i / fps, now = CACurrentMediaTime();
                if (due - start > seconds) break;
                if (due > now) usleep((useconds_t)((due - now) * 1e6));
                int ms = (int)round((CACurrentMediaTime() - start) * 1000);
                CGImageRef image = capture ? capture(CGRectNull, 1 << 3, window, options) : NULL;
                if (!image) continue;
                dispatch_semaphore_wait(room, DISPATCH_TIME_FOREVER);
                dispatch_async(writers, ^{
                    NSString *file = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"f%06d.jpg", ms]];
                    CGImageDestinationRef out = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:file], CFSTR("public.jpeg"), 1, NULL);
                    if (out) { CGImageDestinationAddImage(out, image, (__bridge CFDictionaryRef)@{(id)kCGImageDestinationLossyCompressionQuality: @.93}); CGImageDestinationFinalize(out); CFRelease(out); }
                    CGImageRelease(image);
                    dispatch_semaphore_signal(room);
                });
            }
            NSLog(@"record %@ done", a[0]);
        });
        delay = .05;
    }
    // wallreveal:<title> scrolls a series into view; wallhovert:<title> also fans it as the pointer would.
    else if ([verb isEqualToString:@"wallreveal"] || [verb isEqualToString:@"wallhovert"]) {
        SEL s = NSSelectorFromString(@"snapshotRevealTitle:");
        NSInteger index = [self.albumWall respondsToSelector:s] ? ((NSInteger (*)(id, SEL, NSString *))[self.albumWall methodForSelector:s])(self.albumWall, s, arg) : -1;
        SEL h = NSSelectorFromString(@"snapshotHoverItem:");
        if (index >= 0 && [verb isEqualToString:@"wallhovert"]) ((void (*)(id, SEL, NSInteger))[self.albumWall methodForSelector:h])(self.albumWall, h, index);
    }
    // hang:1 makes the disk under CDGLASS_HANG_PREFIX stop answering (tests/hang_interpose.c), hang:0 brings it back.
    else if ([verb isEqualToString:@"hang"]) {
        NSString *flag = NSProcessInfo.processInfo.environment[@"CDGLASS_HANG_FLAG"];
        if (arg.boolValue) [[NSData data] writeToFile:flag atomically:NO]; else unlink(flag.fileSystemRepresentation);
    }
    else if ([verb isEqualToString:@"gblur"]) [self setGlobalBlurPercent:arg.doubleValue > 0 ? arg.doubleValue : self.globalBlur on:arg.doubleValue > 0];
    else if ([verb isEqualToString:@"blurpanel"]) [self showBlurPanel:nil];
    else if ([verb isEqualToString:@"snapblurpanel"]) { if (self.blurPanel) [self snapWindow:self.blurPanel name:arg]; }
    // Disk trouble: the wall's 重试, and the connection error's two buttons.
    else if ([verb isEqualToString:@"wallretry"]) { SEL s = NSSelectorFromString(@"retryVolumes:"); if ([self.albumWall respondsToSelector:s]) ((void (*)(id, SEL, id))[self.albumWall methodForSelector:s])(self.albumWall, s, nil); }
    else if ([verb isEqualToString:@"snapalert"]) { if (self.connectionAlert) [self snapWindow:self.connectionAlert.window name:arg]; else NSLog(@"snapshot %@: no connection alert", arg); }
    else if ([verb isEqualToString:@"alert"]) { if (self.connectionAlert) [self.window endSheet:self.connectionAlert.window returnCode:[arg isEqualToString:@"retry"] ? NSAlertFirstButtonReturn : NSAlertSecondButtonReturn]; }
    else if ([verb isEqualToString:@"log"]) NSLog(@"PLAN %@ t=%.2f vlc=%lld/%d stall=%ld alert=%d busy=%d playing=%d track=%ld album=%@ wallShown=%d", arg, CACurrentMediaTime(), self.player && self.playerJobsDone >= self.playerJobsSent ? libvlc_media_player_get_time(self.player) : -1, self.player ? (int)libvlc_media_player_get_state(self.player) : -1, (long)self.stallTicks, self.connectionAlert != nil, (int)(self.playerJobsDone < self.playerJobsSent), self.np.playing, (long)self.trackIndex, self.albumTitle, self.albumWallShown);
    else if ([verb isEqualToString:@"quit"]) { [NSApp terminate:nil]; return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self runPlan:plan index:index + 1]; });
}

- (void)runSnapshots {
    NSString *plan = NSProcessInfo.processInfo.environment[@"PLAN"];
    if (!plan.length) return;
    NSArray *steps = [[plan componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self runPlan:steps index:0]; });
}
@end
