#import "CDVolumes.h"
#import <AppKit/AppKit.h>
#import <os/lock.h>
#import <sys/mount.h>
#import <sys/stat.h>

NSNotificationName const CDVolumesChangedNotification = @"CDVolumesChanged";

static os_unfair_lock CDVLock = OS_UNFAIR_LOCK_INIT;
static NSMutableSet<NSString *> *CDVSilent;
static NSArray<NSString *> *CDVMountCache;
static CFTimeInterval CDVMountCacheTime;

static void CDVPost(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ [NSNotificationCenter.defaultCenter postNotificationName:CDVolumesChangedNotification object:nil]; });
}
static void CDVSetUp(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CDVSilent = [NSMutableSet new];
        // A disk plugged back in (or remounted) is worth trying again at once; one that left is reported as gone.
        NSNotificationCenter *center = NSWorkspace.sharedWorkspace.notificationCenter;
        [center addObserverForName:NSWorkspaceDidMountNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            os_unfair_lock_lock(&CDVLock); CDVMountCache = nil; os_unfair_lock_unlock(&CDVLock);
            NSString *path = [note.userInfo[NSWorkspaceVolumeURLKey] path];
            CDVolumeRetry(path.length ? path : nil);
        }];
        [center addObserverForName:NSWorkspaceDidUnmountNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            os_unfair_lock_lock(&CDVLock); CDVMountCache = nil; os_unfair_lock_unlock(&CDVLock);
            CDVPost();
        }];
    });
}
/// Mount points from the kernel's table as it stands (MNT_NOWAIT: no volume is asked for fresh statistics).
static NSArray<NSString *> *CDVMounts(void) {
    CDVSetUp();
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    os_unfair_lock_lock(&CDVLock);
    NSArray *cached = now - CDVMountCacheTime < 1 ? CDVMountCache : nil;
    os_unfair_lock_unlock(&CDVLock);
    if (cached) return cached;
    NSMutableArray<NSString *> *mounts = [NSMutableArray new];
    int count = getfsstat(NULL, 0, MNT_NOWAIT);
    if (count > 0) {
        int room = count + 8;
        struct statfs *table = calloc((size_t)room, sizeof *table);
        count = getfsstat(table, (int)(room * sizeof *table), MNT_NOWAIT);
        for (int i = 0; i < count; i++) [mounts addObject:@(table[i].f_mntonname)];
        free(table);
    }
#if defined(CDGLASS_SNAPSHOT) || defined(CDGLASS_TEST)
    // Tests stand in folders for external volumes.
    for (NSString *fake in [NSProcessInfo.processInfo.environment[@"CDGLASS_TEST_VOLUMES"] componentsSeparatedByString:@":"])
        if (fake.length) [mounts addObject:fake];
#endif
    os_unfair_lock_lock(&CDVLock);
    CDVMountCache = mounts; CDVMountCacheTime = now;
    os_unfair_lock_unlock(&CDVLock);
    return mounts;
}
static BOOL CDVUnder(NSString *path, NSString *mount) {
    if ([mount isEqualToString:@"/"]) return YES;
    return [path isEqualToString:mount] || [path hasPrefix:[mount stringByAppendingString:@"/"]];
}
static NSString *CDVRoot(NSString *path, int depth) {
    if (!path.length || ![path hasPrefix:@"/"] || depth > 4) return nil;
    NSString *best = @"";
    for (NSString *mount in CDVMounts()) if (mount.length > best.length && CDVUnder(path, mount)) best = mount;
    // "/" and /System/Volumes/… are the internal disk; any other mount is external or network.
    if (best.length > 1 && ![best hasPrefix:@"/System/Volumes/"]) return best;
    // Nothing mounted there. Under /Volumes that is an external disk that is not connected, unless the entry is a
    // plain folder or a link (such as "Macintosh HD" pointing at "/"). /Volumes itself is on the internal disk, so
    // looking at the entry cannot block.
    NSArray<NSString *> *parts = path.pathComponents;
    if (parts.count < 3 || ![parts[1] isEqualToString:@"Volumes"]) return nil;
    NSString *entry = [@"/Volumes" stringByAppendingPathComponent:parts[2]];
    struct stat info;
    if (lstat(entry.fileSystemRepresentation, &info) != 0) return entry;
    if (S_ISLNK(info.st_mode)) {
        char target[PATH_MAX]; ssize_t n = readlink(entry.fileSystemRepresentation, target, sizeof target - 1);
        if (n <= 0) return nil;
        target[n] = 0;
        NSString *resolved = [NSFileManager.defaultManager stringWithFileSystemRepresentation:target length:(NSUInteger)n];
        if (![resolved hasPrefix:@"/"]) resolved = [@"/Volumes" stringByAppendingPathComponent:resolved];
        NSArray *rest = [parts subarrayWithRange:NSMakeRange(3, parts.count - 3)];
        return CDVRoot([NSString pathWithComponents:[@[resolved.stringByStandardizingPath] arrayByAddingObjectsFromArray:rest]], depth + 1);
    }
    return nil;
}
NSString *CDVolumeRoot(NSString *path) { return CDVRoot(path, 0); }
NSString *CDVolumeName(NSString *root) { return root.lastPathComponent.length ? root.lastPathComponent : root; }
BOOL CDVolumeMounted(NSString *root) { return [CDVMounts() containsObject:root]; }
static BOOL CDVSilentRoot(NSString *root) {
    if (!CDVolumeMounted(root)) return YES;
    os_unfair_lock_lock(&CDVLock);
    BOOL silent = [CDVSilent containsObject:root];
    os_unfair_lock_unlock(&CDVLock);
    return silent;
}
BOOL CDVolumeIsSilent(NSString *path) {
    NSString *root = CDVolumeRoot(path);
    return root && CDVSilentRoot(root);
}
NSArray<NSString *> *CDVolumesSilentAmong(NSArray<NSString *> *paths) {
    NSMutableOrderedSet *roots = [NSMutableOrderedSet new];
    NSMutableSet *seen = [NSMutableSet new];
    for (NSString *path in paths) {
        NSString *root = CDVolumeRoot(path);
        if (!root || [seen containsObject:root]) continue;
        [seen addObject:root];
        if (CDVSilentRoot(root)) [roots addObject:root];
    }
    return roots.array;
}
void CDVolumeMarkSilent(NSString *root) {
    if (!root.length) return;
    CDVSetUp();
    os_unfair_lock_lock(&CDVLock);
    BOOL added = ![CDVSilent containsObject:root];
    [CDVSilent addObject:root];
    os_unfair_lock_unlock(&CDVLock);
    if (added) CDVPost();
}
void CDVolumeRetry(NSString *root) {
    CDVSetUp();
    os_unfair_lock_lock(&CDVLock);
    if (root) [CDVSilent removeObject:root]; else [CDVSilent removeAllObjects];
    CDVMountCache = nil;
    os_unfair_lock_unlock(&CDVLock);
    CDVPost();
}

@interface CDVTrip : NSObject
@property (nonatomic, strong) dispatch_semaphore_t done;
@property (nonatomic, strong, nullable) id result;
@property (nonatomic) BOOL finished, abandoned;
@end
@implementation CDVTrip @end

id CDVolumeRun(NSString *path, NSTimeInterval timeout, id (^work)(void), BOOL *answered) {
    NSString *root = CDVolumeRoot(path);
    if (!root) { if (answered) *answered = YES; return work(); }
    if (CDVSilentRoot(root)) { if (answered) *answered = NO; return nil; }
    // The work runs on a thread of its own; if the volume holds it, only that thread is lost, not the caller.
    CDVTrip *trip = [CDVTrip new];
    trip.done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        id result = work();
        @synchronized (trip) { if (!trip.abandoned) { trip.result = result; trip.finished = YES; } }
        dispatch_semaphore_signal(trip.done);
    });
    dispatch_semaphore_wait(trip.done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)));
    BOOL finished;
    @synchronized (trip) { finished = trip.finished; if (!finished) trip.abandoned = YES; }
    if (!finished) {
        CDVolumeMarkSilent(root);
        if (answered) *answered = NO;
        return nil;
    }
    if (answered) *answered = YES;
    return trip.result;
}
void CDVolumeRead(NSString *path, NSTimeInterval timeout, id (^work)(void), void (^completion)(id, NSString *)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL answered = YES;
        id result = CDVolumeRun(path, timeout, work, &answered);
        NSString *root = answered ? nil : (CDVolumeRoot(path) ?: path ?: @"");
        dispatch_async(dispatch_get_main_queue(), ^{ completion(result, root); });
    });
}
