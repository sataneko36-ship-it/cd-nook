#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// CD folders usually live on an external or network volume (a USB disk, an sshfs or SMB share). When such a volume
/// stops answering (the cable dropped, the link went down) every file call on it blocks, sometimes for good.
/// Whatever reads CD folders goes through here: the main thread never waits on such a volume, and one that does not
/// answer in time is marked silent and left alone, so nothing piles up behind it, until the user retries or the disk
/// is mounted again.

/// Posted on the main thread whenever a volume goes silent or may be tried again.
extern NSNotificationName const CDVolumesChangedNotification;

/// Where the external or network volume holding `path` is mounted ("/Volumes/永遠の残響"), also while it is not
/// mounted; nil on the internal disk. Reads only the kernel's mount table, never the volume itself.
NSString *_Nullable CDVolumeRoot(NSString *_Nullable path);
/// The volume's name as the user knows it.
NSString *CDVolumeName(NSString *root);
/// Is the volume holding `path` not mounted, or known not to answer? Never touches the volume; fine on the main thread.
BOOL CDVolumeIsSilent(NSString *_Nullable path);
/// The distinct volumes among `paths` that are not mounted or do not answer, by mount point.
NSArray<NSString *> *CDVolumesSilentAmong(NSArray<NSString *> *paths);
/// Is `root` mounted right now?
BOOL CDVolumeMounted(NSString *root);
/// Off the main thread only: runs `work`, waiting at most `timeout` when `path` is on an external volume. If that
/// volume is already known silent, or the work does not finish in time, the volume is marked silent, nil comes back
/// and `*answered` is NO. The work itself may still be stuck in the file system; its late result is dropped.
id _Nullable CDVolumeRun(NSString *_Nullable path, NSTimeInterval timeout, id _Nullable (^work)(void), BOOL *_Nullable answered);
/// From the main thread: the same, done in the background, `completion` back on the main thread with the silent
/// volume's mount point when it did not answer.
void CDVolumeRead(NSString *_Nullable path, NSTimeInterval timeout, id _Nullable (^work)(void),
                  void (^completion)(id _Nullable result, NSString *_Nullable silentRoot));
/// Forget that a volume (every volume, for nil) did not answer, so the next access tries it again.
void CDVolumeRetry(NSString *_Nullable root);
/// Mark a volume silent from outside, e.g. when the player's reading thread stopped coming back.
void CDVolumeMarkSilent(NSString *root);

NS_ASSUME_NONNULL_END
