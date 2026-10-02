#import <AppKit/AppKit.h>
#import "CDTheme.h"
#import "CDViews.h"

NS_ASSUME_NONNULL_BEGIN

/// The anime CD wall: a full-window layer over the player that keeps the player's backdrop, palette and style.
/// Series stack up; clicking a stack bursts its CDs around it while a ripple blurs everything else.
@interface CDAlbumWall : NSView
@property (nonatomic, strong) CDPalette *palette;
@property (nonatomic) NSInteger playerStyle;            // CDStyle: 0 空灵, 1 CD, 2 卡带, 3 像素屏
@property (nonatomic, strong, readonly) CDBackdropView *backdrop;
@property (nonatomic, copy) NSArray<NSDictionary *> *albums;
@property (nonatomic) BOOL grouped;                     // stack CDs of one series
@property (nonatomic, readonly) BOOL expanded;          // a stack is burst open
@property (nonatomic, copy, readonly, nullable) NSString *expandedStackKey;
@property (nonatomic, copy, nullable) void (^onScan)(void);
@property (nonatomic, copy, nullable) void (^onArchive)(NSArray<NSDictionary *> *albums);
@property (nonatomic, copy, nullable) void (^onPlay)(NSDictionary *album);
@property (nonatomic, copy, nullable) void (^onGroupedChange)(BOOL grouped);
- (void)presentAnimated:(BOOL)animated;
- (void)dismissAnimated:(BOOL)animated completion:(void (^ _Nullable)(void))completion;
- (void)refresh;
/// After onPlay: fly the chosen CD into `rect` (wall coordinates), where the player now shows the cover.
/// The player calls this, or -cancelLaunch, once it knows whether the CD could be loaded.
- (void)landLaunchIn:(NSRect)rect;
/// After onPlay: the CD could not be loaded (its disk did not answer); it settles back where it was picked from.
- (void)cancelLaunch;
/// Folds an open stack back; returns NO when nothing was open.
- (BOOL)dismissExpansion;
/// Reopens the same series after returning from its player page.
- (BOOL)expandStackWithKey:(NSString *)key;
/// The same, animated as the way back: `page` (what the player showed, filling the wall) shrinks back into the CD
/// `albumID` from `cover` (where the player showed the cover, wall coordinates) while the blur ripple closes in on the
/// stack. Shows the wall itself; returns NO when the series is gone, and the caller then presents the wall as usual.
- (BOOL)returnToStackWithKey:(NSString *)key albumID:(nullable NSString *)albumID page:(nullable CGImageRef)page cover:(NSRect)cover;
@end

/// Where the CDs of one stack land around the burst point. Exposed for tests.
typedef struct { CGPoint center; CGFloat side, caption; CGRect titleRect; } CDWBurstGeometry;
NSArray<NSValue *> *CDWBurstLayout(NSUInteger count, CGPoint origin, CGRect area, CGSize titleSize, NSString *seed, CDWBurstGeometry *geometry);

NS_ASSUME_NONNULL_END
