#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

NSColor *CDHex(uint32_t rgb);
NSColor *CDMix(NSColor *a, NSColor *b, CGFloat t);
CGFloat CDLuminance(NSColor *color);
CGImageRef _Nullable CDCGImage(NSImage * _Nullable image);

/// Font helpers. Serif and hand fonts cascade to CJK faces so Japanese / Chinese titles stay in style.
NSFont *CDSerifFont(CGFloat size, NSFontWeight weight);
NSFont *CDRoundedFont(CGFloat size, NSFontWeight weight);
NSFont *CDHandFont(CGFloat size);
/// The cassette's lettering: its labels (masking-tape title, paper label), and the cassette style's track list and
/// wall titles. Toppan Bunkyu Midashi Mincho by default — a bold Shōwa-record Mincho; CDHandFont where it is missing.
/// `names`: PostScript names, the first one available leads and the rest cascade (for kana / hanzi it lacks);
/// `scale` evens out faces that run larger or smaller. nil goes back to the default.
NSFont *CDLabelFont(CGFloat size);
void CDSetLabelFont(NSArray<NSString *> * _Nullable names, CGFloat scale);
NSString *CDLabelFontKey(void);
NSDictionary *CDTextAttributes(NSFont *font, NSColor *color, CGFloat kern, NSTextAlignment alignment);

@interface CDPalette : NSObject
@property (nonatomic, readonly) NSInteger index;
@property (nonatomic, readonly) BOOL light;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly, strong) NSColor *base;      // stage background
@property (nonatomic, readonly, strong) NSColor *ink;       // primary text
@property (nonatomic, readonly, strong) NSColor *accent;    // progress, current track, LEDs
@property (nonatomic, readonly, strong) NSColor *surface;   // placeholders
@property (nonatomic, readonly, strong) NSColor *body;      // cassette shell
@property (nonatomic, readonly, strong) NSColor *lcd;       // retro screen backlight
@property (nonatomic, readonly, strong) NSColor *lcdInk;
@property (nonatomic, readonly, strong, nullable) NSColor *glassTint;
@property (nonatomic, readonly, copy) NSArray<NSColor *> *aurora;
@property (nonatomic, readonly) CGFloat secondary;          // alpha for secondary text (≥ 4.5:1 on base)
@property (nonatomic, readonly) CGFloat tertiary;           // alpha for small captions (≥ 4.5:1 on base)
+ (NSInteger)count;
+ (NSArray<NSString *> *)names;
+ (CDPalette *)paletteAtIndex:(NSInteger)index;
- (NSColor *)ink:(CGFloat)alpha;
- (NSImage *)swatch;
@end

/// A few representative colours of an image, most characteristic first.
NSArray<NSColor *> *CDDominantColors(NSImage * _Nullable image, NSUInteger count);

NS_ASSUME_NONNULL_END
