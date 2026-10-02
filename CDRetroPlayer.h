#import "CDHeroes.h"

NS_ASSUME_NONNULL_BEGIN

/// A standalone dot-matrix screen. Click toggles the now-playing and artwork pages; scrolling changes the volume.
@interface CDPixelScreenView : CDHeroView
@property (nonatomic, copy, nullable) void (^onOpen)(void);
@property (nonatomic, copy, nullable) NSInteger (^onVolumeStep)(NSInteger delta);
@property (nonatomic) NSInteger screen;       // 0 now playing, 1 artwork
/// Width / height of the dot matrix alone, and the housing (shell, glass surround, chin) that goes around a screen
/// placed at `screen` in the stage's flipped coordinates — so the layout can size the screen first.
+ (CGFloat)screenAspect;
+ (NSRect)housingForScreen:(NSRect)screen;
/// Frame for the whole device: the screen no bigger than a bare screen in `screen` would be, as large as fits with
/// its housing inside `limits`, clear of `avoid` (all in the stage's coordinates).
+ (NSRect)housingForScreen:(NSRect)screen within:(NSRect)limits avoiding:(NSRect)avoid scale:(CGFloat)scale;
@end

NS_ASSUME_NONNULL_END
