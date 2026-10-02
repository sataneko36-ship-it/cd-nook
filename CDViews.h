#import <AppKit/AppKit.h>
#import "CDTheme.h"

NS_ASSUME_NONNULL_BEGIN

/// Borderless glyph (and/or short title) with a soft radial glow instead of a hard circle.
/// The glow rests at `restGlow` and blooms on hover / press.
@interface CDSoftButton : NSView
+ (instancetype)buttonWithSymbol:(nullable NSString *)symbol title:(nullable NSString *)title target:(nullable id)target action:(nullable SEL)action;
@property (nonatomic, copy, nullable) NSString *symbol;
@property (nonatomic, copy, nullable) NSString *title;
@property (nonatomic) CGFloat glyphSize;
@property (nonatomic, strong, nullable) NSFont *font;
@property (nonatomic) CGFloat restGlow;
@property (nonatomic) CGFloat restOpacity;                // glyph opacity when idle (default .82); full on hover
@property (nonatomic) BOOL active;
@property (nonatomic, strong) NSColor *tint, *glowColor;
@property (nonatomic, weak, nullable) id target;
@property (nonatomic, nullable) SEL action;
@property (nonatomic, readonly) CGFloat contentWidth;
@end

/// Soft, slowly drifting colour field behind everything: aurora blobs, optional blurred cover, grain and floating motes.
@interface CDBackdropView : NSView
@property (nonatomic) NSInteger mode;          // 0 柔光纯色, 1 封面柔焦, 2 封面取色柔焦
@property (nonatomic) NSInteger blurLevel;     // 封面柔焦: 0 朦胧, 1 柔和, 2 清晰
@property (nonatomic) BOOL particles;
@property (nonatomic, readonly, nullable) NSColor *sampleColor;
@property (nonatomic, readonly, copy) NSArray<NSColor *> *coverColors;
- (void)setCoverImage:(nullable NSImage *)image;
- (void)applyPalette:(CDPalette *)palette;
@end

/// Thin line slider used for the seek bar and the volume. Thickens and shows a knob on hover.
@interface CDSliderView : NSView
@property (nonatomic) double doubleValue;
@property (nonatomic, readonly) BOOL scrubbing;
@property (nonatomic, strong) NSColor *trackColor, *fillColor;
@property (nonatomic) CGFloat step;                        // keyboard / VoiceOver increment
@property (nonatomic) CGFloat restOpacity;                 // opacity when idle (default 1); full on hover or drag
@property (nonatomic, copy, nullable) void (^onChange)(double value);   // live while dragging
@property (nonatomic, copy, nullable) void (^onCommit)(double value);   // mouse up
@property (nonatomic, copy, nullable) NSString *(^valueText)(double value);
@end

/// Quiet status line in the top-right corner, beside the gear — like a notification, but just text over a soft haze.
/// Slides in from the right; busy messages show a small spinner and stay until replaced.
@interface CDToastView : NSView
- (void)placeRight:(CGFloat)right centerY:(CGFloat)centerY;
- (void)show:(NSString *)text busy:(BOOL)busy;
- (void)hide;
- (void)applyPalette:(CDPalette *)palette;
@end

/// Three bouncing bars that mark the playing track.
@interface CDEqualizerView : NSView
@property (nonatomic) BOOL animating;
@property (nonatomic, strong) NSColor *color;
@end

typedef NS_ENUM(NSInteger, CDListFace) { CDListFacePlain = 0, CDListFaceHand, CDListFaceMono };

/// The small scrollable tracklist in the bottom-right corner: no panel, just text over a soft haze,
/// a glow that blooms on hover like the buttons, and edge fades that show there is more to scroll.
@interface CDTrackListView : NSView
@property (nonatomic, copy) NSArray<NSString *> *names;
@property (nonatomic) NSInteger current;
@property (nonatomic) BOOL playing;
@property (nonatomic) CDListFace face;
@property (nonatomic) CGFloat scale;
@property (nonatomic, copy) NSString *heading;
@property (nonatomic, strong) CDPalette *palette;
@property (nonatomic, strong, nullable) NSColor *glowColor;
@property (nonatomic, copy, nullable) void (^onSelect)(NSInteger row);
@property (nonatomic, readonly) CGFloat rowHeight, headerHeight;
- (CGFloat)preferredHeightWithMax:(CGFloat)maxHeight;
- (CGFloat)heightForRows:(CGFloat)rows;
- (void)reload;
- (void)scrollToCurrent:(BOOL)animated;
@end

/// One cover candidate in the chooser sheet.
@interface CDCandidateTile : NSView
@property (nonatomic, strong, nullable) NSImage *image;
@property (nonatomic, copy) NSString *title, *detail;
@property (nonatomic) BOOL current, hasSource;
@property (nonatomic) NSUInteger stackCount, stackIndex;
@property (nonatomic, copy) NSArray<NSImage *> *stackPreviewImages;
@property (nonatomic, copy, nullable) void (^onChoose)(void);
@property (nonatomic, copy, nullable) void (^onOpenSource)(void);
@property (nonatomic, copy, nullable) void (^onPrevious)(void), (^onNext)(void);
+ (CGFloat)heightForWidth:(CGFloat)width;
@end

/// Dashed outline shown while a folder or image is dragged over the window.
@interface CDDropOverlay : NSView
@property (nonatomic, copy) NSString *message;
- (void)applyPalette:(CDPalette *)palette;
@end

@interface CDFlippedView : NSView
@end

NS_ASSUME_NONNULL_END
