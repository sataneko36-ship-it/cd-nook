// A volume that stops answering: file calls on it block in the kernel. A FIFO does the same to whoever opens it
// for reading, so a folder of FIFOs, declared an external volume, stands in for a disk that dropped out.
// Build: clang -fobjc-arc -fmodules -mmacosx-version-min=26.0 -DCDGLASS_TEST tests/volumes_test.m CDVolumes.m \
//        -o volumes_test -framework AppKit
// Run:   CDGLASS_TEST_VOLUMES=<dir>/disk ./volumes_test <dir>
#import "../CDVolumes.h"
#import <AppKit/AppKit.h>
#include <assert.h>
#include <fcntl.h>
#include <sys/stat.h>

int main(int argc, const char *argv[]) { @autoreleasepool {
    NSString *dir = argc > 1 ? @(argv[1]) : NSTemporaryDirectory();
    NSString *disk = [dir stringByAppendingPathComponent:@"disk"], *album = [disk stringByAppendingPathComponent:@"Album"];
    [NSFileManager.defaultManager createDirectoryAtPath:album withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *stuck = [album stringByAppendingPathComponent:@"cover.jpg"];
    unlink(stuck.fileSystemRepresentation);
    assert(mkfifo(stuck.fileSystemRepresentation, 0600) == 0);

    // Where things live: the internal disk has no root, the stand-in disk does, an unplugged disk keeps its name.
    assert(CDVolumeRoot(NSHomeDirectory()) == nil);
    assert(CDVolumeRoot(@"/Volumes/Macintosh HD/Users") == nil);                 // a link to "/"
    assert([CDVolumeRoot(stuck) isEqualToString:disk]);
    assert([CDVolumeRoot(@"/Volumes/CDGlass-not-plugged-in/Series/CD1") isEqualToString:@"/Volumes/CDGlass-not-plugged-in"]);
    assert(CDVolumeIsSilent(@"/Volumes/CDGlass-not-plugged-in/Series/CD1"));
    assert(!CDVolumeIsSilent(stuck) && !CDVolumeIsSilent(NSHomeDirectory()));

    // An answering read comes back with its result.
    BOOL answered = NO;
    id listing = CDVolumeRun(album, 2, ^id{ return [NSFileManager.defaultManager contentsOfDirectoryAtPath:album error:nil]; }, &answered);
    assert(answered && [listing count] == 1);

    // A read that hangs: the caller is back after the timeout, and the volume is now known silent.
    CFTimeInterval start = CACurrentMediaTime();
    id nothing = CDVolumeRun(stuck, .8, ^id{ int fd = open(stuck.fileSystemRepresentation, O_RDONLY); if (fd >= 0) close(fd); return @"read"; }, &answered);
    CFTimeInterval took = CACurrentMediaTime() - start;
    assert(!answered && nothing == nil && took > .7 && took < 2);
    assert(CDVolumeIsSilent(album));
    NSArray *silent = CDVolumesSilentAmong(@[album, stuck, NSHomeDirectory(), @"/Volumes/CDGlass-not-plugged-in/x"]);
    assert(silent.count == 2 && [silent containsObject:disk]);

    // Nothing more is sent to a silent volume: this would hang again, and returns at once instead.
    start = CACurrentMediaTime();
    __block BOOL ran = NO;
    CDVolumeRun(stuck, 5, ^id{ ran = YES; int fd = open(stuck.fileSystemRepresentation, O_RDONLY); if (fd >= 0) close(fd); return nil; }, &answered);
    assert(!answered && !ran && CACurrentMediaTime() - start < .05);

    // The main thread's way: completion on the main thread, naming the silent volume.
    __block NSString *reported = nil; __block BOOL called = NO;
    CDVolumeRead(stuck, 1, ^id{ return @"x"; }, ^(id result, NSString *root) { assert(NSThread.isMainThread); called = YES; reported = root; });
    while (!called) [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
    assert([reported isEqualToString:disk]);

    // Retry: the disk is tried again (it answers now that the FIFO is gone).
    __block NSUInteger notes = 0;
    [NSNotificationCenter.defaultCenter addObserverForName:CDVolumesChangedNotification object:nil queue:nil usingBlock:^(NSNotification *n) { notes++; }];
    unlink(stuck.fileSystemRepresentation);
    // Unblock the thread still waiting on the FIFO? It was unlinked; that open stays stuck, as on a dead disk. Fine.
    CDVolumeRetry(disk);
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.1]];
    assert(notes >= 1 && !CDVolumeIsSilent(album));
    listing = CDVolumeRun(album, 2, ^id{ return [NSFileManager.defaultManager contentsOfDirectoryAtPath:album error:nil]; }, &answered);
    assert(answered && listing);
    NSLog(@"Volume timeouts passed");
    exit(0);   // the thread stuck on the FIFO would keep the process alive
} }
