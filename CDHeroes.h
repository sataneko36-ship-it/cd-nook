#import <AppKit/AppKit.h>
#import "CDTheme.h"

NS_ASSUME_NONNULL_BEGIN

/// Everything a style needs to know about what is playing. Owned by the app, read by the hero views.
@interface CDNowPlaying : NSObject
@property (nonatomic) BOOL hasSession, playing;
@property (nonatomic, copy) NSString *album, *artist, *track;
@property (nonatomic, copy) NSArray<NSString *> *trackNames;
@property (nonatomic) NSInteger index, count, volume;
@property (nonatomic) double trackProgress;   // 0…1 within the track
@property (nonatomic) double albumProgress;   // 0…1 across the whole disc
@property (nonatomic) long long elapsedMS, durationMS;
@end

typedef NS_ENUM(NSInteger, CDStyle) {
    CDStyleEthereal = 0,
    CDStyleDisc,
    CDStyleCassette,
    CDStylePixelScreen,
};

/// Base class for the large central object of each style.
@interface CDHeroView : NSView
@property (nonatomic, strong, nullable) NSImage *cover;
@property (nonatomic, strong) CDPalette *palette;
@property (nonatomic, copy) NSArray<NSColor *> *coverColors;
@property (nonatomic, strong) CDNowPlaying *np;
@property (nonatomic, readonly) CGFloat aspect;            // width / height of the object
@property (nonatomic, readonly) NSRect objectRect;         // aspect-fitted rect inside bounds
- (void)coverChanged;
- (void)paletteChanged;
- (void)nowPlayingChanged;
- (void)progressChanged;
- (void)step:(CFTimeInterval)dt;                          // called every display frame
@end

@interface CDEtherealHero : CDHeroView
@end
@interface CDDiscHero : CDHeroView
@end
/// How the cover sits on the cassette: printed on the paper label, printed across the whole shell,
/// or as the colour of a translucent shell with a small cover sticker on a paper label.
typedef NS_ENUM(NSInteger, CDCassetteLook) { CDCassetteLookCoverLabel = 0, CDCassetteLookPrintedShell, CDCassetteLookTintedShell };

@interface CDCassetteHero : CDHeroView
@property (nonatomic) CDCassetteLook look;
@property (nonatomic, copy, nullable) void (^onCycleLook)(void);
@end

/// Materials shared by the physical-looking styles (cassette shell, pixel screen housing).
/// Draws into a bitmap of `size` points at `scale`; the context is not flipped.
CGImageRef _Nullable CDRenderImage(CGSize size, CGFloat scale, void (^draw)(CGContextRef ctx, CGSize size)) CF_RETURNS_RETAINED;
CGImageRef CDGrainTile(void);                      // fine moulding grain
CGImageRef CDMottleTile(void);                     // large soft unevenness; draw it scaled up
void CDDrawTile(CGContextRef ctx, CGImageRef tile, CGRect rect, CGFloat scale, CGFloat alpha, CGBlendMode mode);
/// Inner shadow (or inner light) along the inside of `path`; negative `dy` puts it along the top edge.
void CDInnerShadow(CGContextRef ctx, CGPathRef path, CGFloat dy, CGFloat blur, NSColor *color);
/// Fills `path` as a soft, blurred shape (a reflection of the light source).
void CDSoftFill(CGContextRef ctx, CGPathRef path, CGFloat blur, NSColor *color, CGFloat scale);

/// Soft placeholder artwork used when a disc has no cover.
NSImage *CDPlaceholderCover(CDPalette *palette, NSString * _Nullable caption);
NSImage *CDIdleCover(void);

NS_ASSUME_NONNULL_END
