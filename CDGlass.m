#import <AppKit/AppKit.h>
#import <DiscRecording/DiscRecording.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreImage/CoreImage.h>
#import <CommonCrypto/CommonDigest.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <objc/message.h>
#import <sys/stat.h>
#import "CDApp.h"
#import "CDVolumes.h"

/// How long reading a CD folder may take before its disk counts as not answering. A sleeping drive spins up
/// well within this; a USB disk that dropped out or an sshfs / SMB link that went down does not.
static const NSTimeInterval CDDiskPatience = 8;
/// Stopping or switching a track normally takes milliseconds; a player still at it after this is stuck on a disk.
static const NSTimeInterval CDPlayerPatience = 5;

static NSDictionary *CDAttrs(NSFont *font, NSColor *color, CGFloat kern, NSTextAlignment alignment, BOOL wrap) {
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.alignment = alignment;
    paragraph.lineBreakMode = wrap ? NSLineBreakByWordWrapping : NSLineBreakByTruncatingTail;
    paragraph.lineHeightMultiple = wrap ? 1.06 : 1;
    return @{NSFontAttributeName: font, NSForegroundColorAttributeName: color, NSKernAttributeName: @(kern), NSParagraphStyleAttributeName: paragraph};
}

static NSString *CDTime(long long ms) {
    long long s = MAX(0, ms / 1000);
    return s >= 3600 ? [NSString stringWithFormat:@"%lld:%02lld:%02lld", s / 3600, (s / 60) % 60, s % 60] : [NSString stringWithFormat:@"%lld:%02lld", s / 60, s % 60];
}

@implementation CDWindow
- (void)keyDown:(NSEvent *)event {
    if (self.keyAction) self.keyAction(event);
    else [super keyDown:event];
}
#ifdef CDGLASS_SNAPSHOT
- (NSRect)constrainFrameRect:(NSRect)frameRect toScreen:(NSScreen *)screen { return frameRect; }
#endif
@end

@implementation CDStageView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
    }
    return self;
}
- (void)layout { [super layout]; if (self.onLayout) self.onLayout(); }
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *area in self.trackingAreas) [self removeTrackingArea:area];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseMoved | NSTrackingActiveAlways | NSTrackingInVisibleRect owner:self userInfo:nil]];
}
- (void)mouseMoved:(NSEvent *)event { if (self.onActivity) self.onActivity(); }
- (void)mouseDown:(NSEvent *)event { if (self.onActivity) self.onActivity(); }
- (NSArray<NSURL *> *)urlsFrom:(id<NSDraggingInfo>)info {
    return [info.draggingPasteboard readObjectsForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}] ?: @[];
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    NSString *message = self.onDragEnter ? self.onDragEnter([self urlsFrom:sender]) : nil;
    return message ? NSDragOperationCopy : NSDragOperationNone;
}
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender { return [self draggingEntered:sender]; }
- (void)draggingExited:(id<NSDraggingInfo>)sender { if (self.onDragExit) self.onDragExit(); }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    if (self.onDragExit) self.onDragExit();
    return self.onDrop ? self.onDrop([self urlsFrom:sender]) : NO;
}
@end

@interface CDApp ()
@property (nonatomic, strong, nullable) NSImage *displayCover;
@property (nonatomic, strong, nullable) NSImage *backdropShown;     // what the backdrop is blurring now
@property (nonatomic, strong) NSArray<NSMenuItem *> *styleMenuItems;
@end

@implementation CDApp

#pragma mark - Building blocks

/// With no CD in, the window is cream white (奶油白) whatever the theme; the theme comes in with the CD.
- (CDPalette *)palette { return [CDPalette paletteAtIndex:self.hasSession ? self.themeIndex : 6]; }
- (BOOL)hasSession { return self.trackCount > 0; }
- (BOOL)isFullscreen {
#ifdef CDGLASS_SNAPSHOT
    if (NSProcessInfo.processInfo.environment[@"FAKEFS"]) return YES;
#endif
    return (self.window.styleMask & NSWindowStyleMaskFullScreen) != 0;
}
- (BOOL)cornerLayout { return self.styleIndex == CDStyleDisc; }

- (NSTextField *)makeLabel:(BOOL)wrapping {
    NSTextField *label = wrapping ? [NSTextField wrappingLabelWithString:@""] : [NSTextField labelWithString:@""];
    label.lineBreakMode = wrapping ? NSLineBreakByWordWrapping : NSLineBreakByTruncatingTail;
    if (wrapping) { label.maximumNumberOfLines = 2; label.cell.truncatesLastVisibleLine = YES; }
    label.selectable = NO;
    [self.stage addSubview:label];
    return label;
}

- (CDSoftButton *)softButton:(NSString *)symbol title:(NSString *)title tip:(NSString *)tip action:(SEL)action {
    CDSoftButton *button = [CDSoftButton buttonWithSymbol:symbol title:title target:self action:action];
    button.toolTip = tip;
    [self.stage addSubview:button];
    return button;
}

#pragma mark - Launch

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSString *plugins = [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"VLC/plugins"];
    setenv("VLC_PLUGIN_PATH", plugins.fileSystemRepresentation, 1);
#ifdef CDGLASS_SNAPSHOT
    const char *args[] = {"--quiet", "--no-video", "--no-video-title-show", "--no-metadata-network-access", "--aout=dummy"};
    self.vlc = libvlc_new(5, args);
#else
    const char *args[] = {"--quiet", "--no-video", "--no-video-title-show", "--no-metadata-network-access"};
    self.vlc = libvlc_new(4, args);
#endif
    if (self.vlc) self.player = libvlc_media_player_new(self.vlc);
    self.playerQueue = dispatch_queue_create("local.cdglass.player", DISPATCH_QUEUE_SERIAL);
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    self.np = [CDNowPlaying new];
    self.themeIndex = [defaults objectForKey:@"CDGlassTheme"] ? MIN(7, MAX(0, [defaults integerForKey:@"CDGlassTheme"])) : 4;
    self.backgroundMode = [defaults objectForKey:@"CDGlassBackgroundMode"] ? MIN(2, MAX(0, [defaults integerForKey:@"CDGlassBackgroundMode"])) : 2;
    self.blurLevel = MIN(2, MAX(0, [defaults integerForKey:@"CDGlassBlurLevel"]));
    self.enhancementMode = [defaults objectForKey:@"CDGlassEnhancementMode"] ? [defaults integerForKey:@"CDGlassEnhancementMode"] : 1;
    self.styleIndex = [self savedStyle];
    self.particles = [defaults objectForKey:@"CDGlassParticles"] ? [defaults boolForKey:@"CDGlassParticles"] : YES;
    self.cassetteLook = MIN(2, MAX(0, [defaults integerForKey:@"CDGlassCassetteLook"]));
    self.globalBlur = [defaults objectForKey:@"CDGlassGlobalBlur"] ? MAX(.001, MIN(3, [defaults doubleForKey:@"CDGlassGlobalBlur"])) : .05;
    self.globalBlurOn = [defaults boolForKey:@"CDGlassGlobalBlurOn"];
    self.library = [CDLibrary new];
#ifdef CDGLASS_SNAPSHOT
    // Tests use a private copy of the catalogue, never the user's own Library.json.
    NSString *testLibrary = NSProcessInfo.processInfo.environment[@"CDGLASS_LIBRARY"];
    if (testLibrary.length) self.library = [[CDLibrary alloc] initWithRootURL:[NSURL fileURLWithPath:testLibrary isDirectory:YES]];
#endif
    // The small list in the bottom-right corner shows by default; L hides it.
    self.listPreference = [defaults objectForKey:@"CDGlassListVisible"] ? [defaults boolForKey:@"CDGlassListVisible"] : YES;
    [self buildMenu];
    [self buildWindow];
    [self applyGlobalBlur];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    self.displayTimer = [NSTimer timerWithTimeInterval:1.0 / 60.0 target:self selector:@selector(displayTick:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.displayTimer forMode:NSRunLoopCommonModes];
    self.displayLink = [self.stage displayLinkWithTarget:self selector:@selector(frameTick:)];
    [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    self.lastActivity = CACurrentMediaTime();
    [self scanDisc];
#ifdef CDGLASS_SNAPSHOT
    // The test window renders off-screen, where display links do not fire.
    __weak typeof(self) weakSelf = self;
    [NSTimer scheduledTimerWithTimeInterval:1 / 60.0 repeats:YES block:^(NSTimer *timer) { [weakSelf advanceFrame:1 / 60.0]; }];
    SEL snapshots = NSSelectorFromString(@"runSnapshots");
    if ([self respondsToSelector:snapshots]) ((void (*)(id, SEL))[self methodForSelector:snapshots])(self, snapshots);
#endif
}

/// The style last used, remembered across launches; 空灵 the first time. 0.8 stored five styles under
/// "CDGlassStyle" (with 黑胶唱机 at 2); those values are mapped onto the four that remain.
- (NSInteger)savedStyle {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults objectForKey:@"CDGlassStyleV2"]) return MIN(CDStylePixelScreen, MAX(CDStyleEthereal, [defaults integerForKey:@"CDGlassStyleV2"]));
    NSInteger style = CDStyleEthereal;
    if ([defaults objectForKey:@"CDGlassStyle"]) {
        NSInteger old = [defaults integerForKey:@"CDGlassStyle"];
        style = old == 1 ? CDStyleDisc : old == 3 ? CDStyleCassette : old == 4 ? CDStylePixelScreen : CDStyleEthereal;
    }
    [defaults setInteger:style forKey:@"CDGlassStyleV2"];
    return style;
}

- (void)buildMenu {
    NSMenu *main = [NSMenu new];
    NSMenuItem *appItem = [NSMenuItem new];
    [main addItem:appItem];
    NSMenu *appMenu = [NSMenu new];
    [appMenu addItemWithTitle:@"隐藏 CD Nook" action:@selector(hide:) keyEquivalent:@"h"];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"退出 CD Nook" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    NSMenuItem *fileItem = [NSMenuItem new];
    [main addItem:fileItem];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"文件"];
    [fileMenu addItemWithTitle:@"从文件夹模拟 CD…" action:@selector(openVirtual:) keyEquivalent:@"o"].target = self;
    [fileMenu addItemWithTitle:@"专辑墙" action:@selector(showAlbumWall:) keyEquivalent:@"b"].target = self;
    [fileMenu addItemWithTitle:@"扫描文件夹加入专辑墙…" action:@selector(scanLibraryFolder:) keyEquivalent:@""].target = self;
    [fileMenu addItemWithTitle:@"播放内置测试 CD" action:@selector(playDemo:) keyEquivalent:@"d"].target = self;
    [fileMenu addItemWithTitle:@"结束播放" action:@selector(endSession:) keyEquivalent:@"w"].target = self;
    fileItem.submenu = fileMenu;
    NSMenuItem *viewItem = [NSMenuItem new];
    [main addItem:viewItem];
    NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:@"显示"];
    NSMutableArray *styleItems = [NSMutableArray new];
    NSArray *styles = [self styleNames];
    for (NSInteger i = 0; i < (NSInteger)styles.count; i++) {
        NSMenuItem *item = [viewMenu addItemWithTitle:styles[i] action:@selector(selectStyle:) keyEquivalent:[NSString stringWithFormat:@"%ld", (long)i + 1]];
        item.target = self; item.tag = i; item.state = i == self.styleIndex ? NSControlStateValueOn : NSControlStateValueOff;
        [styleItems addObject:item];
    }
    self.styleMenuItems = styleItems;
    [viewMenu addItem:[NSMenuItem separatorItem]];
    [viewMenu addItemWithTitle:@"显示 / 隐藏 LIST" action:@selector(toggleList:) keyEquivalent:@"l"].target = self;
    NSMenuItem *full = [viewMenu addItemWithTitle:@"进入 / 退出全屏" action:@selector(toggleFullScreen:) keyEquivalent:@"f"];
    full.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagCommand;
    viewItem.submenu = viewMenu;
    [NSApp setMainMenu:main];
}

- (NSArray<NSString *> *)styleNames { return @[@"空灵", @"CD 光盘", @"复古卡带", @"像素屏"]; }
- (NSArray<NSString *> *)styleSymbols { return @[@"sparkles", @"opticaldisc", @"recordingtape", @"square.grid.3x3.fill"]; }

- (void)buildWindow {
    self.window = [[CDWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1180, 740) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"CD Nook";
    self.window.delegate = self;
    // Never set contentAspectRatio to NSZeroSize here: AppKit traps on it when the window leaves full screen.
    self.window.minSize = NSMakeSize(820, 540);
    [self.window center];
    self.window.titlebarAppearsTransparent = YES;
    self.window.titleVisibility = NSWindowTitleHidden;
    self.window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
    self.window.acceptsMouseMovedEvents = YES;
    __weak typeof(self) weakSelf = self;
    self.window.keyAction = ^(NSEvent *event) { [weakSelf handleKey:event]; };

    NSView *root = self.window.contentView;
    root.wantsLayer = YES;
    self.stage = [[CDStageView alloc] initWithFrame:root.bounds];
    self.stage.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [root addSubview:self.stage];
    self.stage.onLayout = ^{ [weakSelf layoutStage]; };
    self.stage.onActivity = ^{ [weakSelf userActivity]; };
    self.stage.onDragEnter = ^NSString *(NSArray<NSURL *> *urls) { return [weakSelf dropMessageFor:urls]; };
    self.stage.onDragExit = ^{ weakSelf.dropOverlay.hidden = YES; };
    self.stage.onDrop = ^BOOL(NSArray<NSURL *> *urls) { return [weakSelf acceptDrop:urls]; };

    self.backdrop = [[CDBackdropView alloc] initWithFrame:self.stage.bounds];
    self.backdrop.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.stage addSubview:self.backdrop];

    self.indexLabel = [self makeLabel:NO];
    self.titleLabel = [self makeLabel:YES];
    self.subtitleLabel = [self makeLabel:NO];
    self.elapsedLabel = [self makeLabel:NO];
    self.remainingLabel = [self makeLabel:NO];
    self.elapsedLabel.alignment = NSTextAlignmentRight;

    self.progress = [CDSliderView new];
    self.progress.toolTip = @"拖动以跳转播放位置 · ⇧← / ⇧→ 快退 / 快进 10 秒";
    self.progress.step = .02;
    self.progress.onCommit = ^(double fraction) { [weakSelf seekToFraction:fraction]; };
    self.progress.onChange = ^(double fraction) { [weakSelf previewSeek:fraction]; };
    self.progress.valueText = ^NSString *(double value) { return [NSString stringWithFormat:@"%@ / %@", CDTime(weakSelf.np.durationMS * value), CDTime(weakSelf.np.durationMS)]; };
    self.progress.accessibilityLabel = @"播放进度";
    [self.stage addSubview:self.progress];

    self.prevButton = [self softButton:@"backward.fill" title:nil tip:@"上一首 · ←" action:@selector(previous:)];
    self.playButton = [self softButton:@"play.fill" title:nil tip:@"播放 / 暂停 · 空格" action:@selector(togglePlayback:)];
    self.nextButton = [self softButton:@"forward.fill" title:nil tip:@"下一首 · →" action:@selector(next:)];
    self.muteButton = [self softButton:@"speaker.wave.2.fill" title:nil tip:@"静音 / 恢复音量" action:@selector(toggleMute:)];
    self.volumeSlider = [CDSliderView new];
    self.volumeSlider.accessibilityLabel = @"音量";
    self.volumeSlider.toolTip = @"音量 · ↑ / ↓";
    self.volumeSlider.onChange = ^(double value) { [weakSelf setVolumeLevel:(NSInteger)round(value * 100) persist:NO]; };
    self.volumeSlider.onCommit = ^(double value) { [weakSelf setVolumeLevel:(NSInteger)round(value * 100) persist:YES]; };
    [self.stage addSubview:self.volumeSlider];

    self.trackList = [CDTrackListView new];
    self.trackList.onSelect = ^(NSInteger row) { [weakSelf selectTrack:row]; };
    self.trackList.toolTip = @"点一首歌播放 · L 隐藏 / 显示";
    [self.stage addSubview:self.trackList];

    self.openButton = [self softButton:@"folder" title:@"打开文件夹…" tip:@"⌘O" action:@selector(openVirtual:)];
    self.demoButton = [self softButton:@"play.circle" title:@"试听示例" tip:@"⌘D" action:@selector(playDemo:)];
    self.libraryButton = [self softButton:@"square.grid.2x2" title:@"专辑墙" tip:@"查看、扫描并归档音乐 CD · ⌘B" action:@selector(showAlbumWall:)];
    self.libraryEntryButton = [self softButton:@"square.grid.2x2" title:nil tip:@"专辑墙 · ⌘B" action:@selector(showAlbumWall:)];
    self.gearButton = [self softButton:@"gearshape" title:nil tip:@"更多操作" action:@selector(showGearMenu:)];

    self.toast = [CDToastView new];
    [self.stage addSubview:self.toast];
    self.dropOverlay = [CDDropOverlay new];
    self.dropOverlay.hidden = YES;
    [self.stage addSubview:self.dropOverlay];

    NSInteger volume = [NSUserDefaults.standardUserDefaults objectForKey:@"CDGlassVolume"] ? [NSUserDefaults.standardUserDefaults integerForKey:@"CDGlassVolume"] : 75;
    self.savedVolume = volume ?: 75;
    [self setVolumeLevel:volume persist:NO];
    [self installHero];
    [self applyTheme];
}

- (void)installHero {
    NSArray<Class> *classes = @[CDEtherealHero.class, CDDiscHero.class, CDCassetteHero.class, CDPixelScreenView.class];
    CDHeroView *hero = [[classes[MAX(0, MIN((NSInteger)classes.count - 1, self.styleIndex))] alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)];
    hero.np = self.np;
    hero.palette = self.palette;
    hero.coverColors = self.backdrop.coverColors;
    hero.cover = self.displayCover;
    __weak typeof(self) weakSelf = self;
    if ([hero isKindOfClass:CDCassetteHero.class]) {
        CDCassetteHero *cassette = (CDCassetteHero *)hero;
        cassette.look = self.cassetteLook;
        cassette.toolTip = @"点击磁带切换样式";
        cassette.onCycleLook = ^{ [weakSelf cycleCassetteLook]; };
    }
    if ([hero isKindOfClass:CDPixelScreenView.class]) {
        CDPixelScreenView *screen = (CDPixelScreenView *)hero;
        screen.onOpen = ^{ [weakSelf openVirtual:nil]; };
        screen.onVolumeStep = ^NSInteger(NSInteger delta) { [weakSelf setVolumeLevel:weakSelf.np.volume + delta persist:YES]; return weakSelf.np.volume; };
    }
    [self.stage addSubview:hero positioned:NSWindowAbove relativeTo:self.backdrop];
    [self.hero removeFromSuperview];
    self.hero = hero;
    if (self.albumWallShown) hero.hidden = YES;
    self.trackList.face = self.styleIndex == CDStyleCassette ? CDListFaceHand : self.styleIndex == CDStylePixelScreen ? CDListFaceMono : CDListFacePlain;
    self.albumWall.playerStyle = self.styleIndex;
    for (NSMenuItem *item in self.styleMenuItems) item.state = item.tag == self.styleIndex ? NSControlStateValueOn : NSControlStateValueOff;
    [self refreshLabels];
    self.stage.needsLayout = YES;
}

#pragma mark - Layout

- (CGFloat)heightOf:(NSTextField *)label width:(CGFloat)width {
    NSAttributedString *text = label.attributedStringValue;
    if (!text.length) return 0;
    if (label.maximumNumberOfLines == 1 || !label.cell.wraps) return ceil(text.size.height);
    NSRect bounds = [text boundingRectWithSize:NSMakeSize(width, 10000) options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading];
    NSFont *font = [text attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL];
    CGFloat line = ceil([[NSAttributedString alloc] initWithString:@"Ag国あ" attributes:@{NSFontAttributeName: font}].size.height * 1.06);
    return ceil(MIN(bounds.size.height, line * label.maximumNumberOfLines));
}

- (CGFloat)place:(NSTextField *)label x:(CGFloat)x y:(CGFloat)y width:(CGFloat)width {
    CGFloat h = [self heightOf:label width:width];
    label.preferredMaxLayoutWidth = width;
    label.frame = NSMakeRect(round(x), round(y), round(width), h + 2);
    return h;
}

- (void)put:(CDSoftButton *)button center:(NSPoint)center size:(NSSize)size glyph:(CGFloat)glyph {
    button.glyphSize = glyph;
    button.frame = NSIntegralRect(NSMakeRect(center.x - size.width / 2, center.y - size.height / 2, size.width, size.height));
}

// Transport metrics: a large play glyph flanked by two smaller ones, all borderless with a soft glow.
- (CGFloat)playSize { return round(80 * self.u); }
- (CGFloat)skipSize { return round(58 * self.u); }
- (CGFloat)skipGap { return round(64 * self.u); }

- (void)layoutTransportCenter:(NSPoint)c {
    CGFloat u = self.u, P = self.playSize, S = self.skipSize, D = self.skipGap;
    [self put:self.prevButton center:NSMakePoint(c.x - D, c.y) size:NSMakeSize(S, S) glyph:round(18 * u)];
    [self put:self.playButton center:c size:NSMakeSize(P, P) glyph:round(27 * u)];
    [self put:self.nextButton center:NSMakePoint(c.x + D, c.y) size:NSMakeSize(S, S) glyph:round(18 * u)];
}

- (CGFloat)layoutVolumeLeft:(CGFloat)x centerY:(CGFloat)cy {
    CGFloat u = self.u, m = round(40 * u), w = round(92 * u);
    [self put:self.muteButton center:NSMakePoint(x + m / 2, cy) size:NSMakeSize(m, m) glyph:round(13 * u)];
    self.volumeSlider.frame = NSIntegralRect(NSMakeRect(x + m + 2, cy - 9, w, 18));
    return m + 2 + w;
}

- (void)layoutProgressLeft:(CGFloat)x centerY:(CGFloat)cy width:(CGFloat)width {
    CGFloat label = round(56 * self.u), gap = round(10 * self.u);
    CGFloat bar = MAX(80, width - 2 * (label + gap));
    NSSize e = self.elapsedLabel.attributedStringValue.size;
    self.elapsedLabel.frame = NSIntegralRect(NSMakeRect(x, cy - e.height / 2 - 1, label, ceil(e.height) + 2));
    self.progress.frame = NSIntegralRect(NSMakeRect(x + label + gap, cy - 9, bar, 18));
    self.remainingLabel.frame = NSIntegralRect(NSMakeRect(x + label + gap * 2 + bar, cy - e.height / 2 - 1, label, ceil(e.height) + 2));
}

/// The little tracklist window, anchored by its bottom-right corner. Shows up to six rows, the last one and a
/// half melting into an eased fade that hints it scrolls.
- (NSRect)listRectRight:(CGFloat)right bottom:(CGFloat)bottom {
    CGFloat w = round(250 * self.u);
    CGFloat h = [self.trackList preferredHeightWithMax:[self.trackList heightForRows:6]];
    return NSMakeRect(right - w, bottom - h, w, h);
}

- (void)placeList:(NSRect)rect {
    rect = NSIntegralRect(rect);
    if (NSEqualRects(rect, self.trackList.frame)) return;
    BOOL resized = fabs(NSHeight(rect) - NSHeight(self.trackList.frame)) > .5;
    self.trackList.frame = rect;
    if (resized) { [self.trackList layoutSubtreeIfNeeded]; [self.trackList scrollToCurrent:NO]; }
}

- (void)layoutEmptyButtonsX:(CGFloat)x top:(CGFloat)top centered:(BOOL)centered {
    CGFloat u = self.u, h = round(44 * u), gap = round(8 * u);
    NSFont *font = [NSFont systemFontOfSize:round(13.5 * u) weight:NSFontWeightMedium];
    self.openButton.font = font; self.demoButton.font = font; self.libraryButton.font = font;
    self.openButton.glyphSize = round(14 * u); self.demoButton.glyphSize = round(14 * u); self.libraryButton.glyphSize = round(14 * u);
    CGFloat w1 = self.openButton.contentWidth + round(44 * u), w2 = self.demoButton.contentWidth + round(44 * u), w3 = self.libraryButton.contentWidth + round(44 * u);
    CGFloat x0 = centered ? x - (w1 + gap + w2 + gap + w3) / 2 : x - round(20 * u);
    self.openButton.frame = NSIntegralRect(NSMakeRect(x0, top, w1, h));
    self.demoButton.frame = NSIntegralRect(NSMakeRect(x0 + w1 + gap, top, w2, h));
    self.libraryButton.frame = NSIntegralRect(NSMakeRect(x0 + w1 + gap + w2 + gap, top, w3, h));
}

- (void)layoutStage {
    NSRect b = self.stage.bounds;
    CGFloat W = NSWidth(b), H = NSHeight(b);
    if (W < 100 || H < 100) return;
    CGFloat u = MAX(.74, MIN(1.4, MIN(H / 1000.0, W / 1500.0)));
    if (fabs(u - self.u) > .005) { self.u = u; [self refreshLabels]; }
    u = self.u;
    self.trackList.scale = u;
    BOOL session = self.hasSession, list = self.listShown;
    CDStyle style = self.styleIndex;
    self.backdrop.frame = b;
    self.dropOverlay.frame = b;
    self.albumWall.frame = b;
    [self put:self.gearButton center:NSMakePoint(W - round(30 * u) - 20, 42) size:NSMakeSize(48, 48) glyph:16];
    [self put:self.libraryEntryButton center:NSMakePoint(round(30 * u) + 20, 42) size:NSMakeSize(48, 48) glyph:16];
    [self.toast placeRight:NSMinX(self.gearButton.frame) - 2 centerY:NSMidY(self.gearButton.frame)];
    CGFloat margin = round(36 * u), P = self.playSize, gap = round(18 * u);
    CGFloat cy = H - round(22 * u) - P / 2;                 // centre line of the bottom control row
    CGFloat progressY = cy - P / 2 - round(12 * u);          // centre line of the progress row above it
    CGFloat top = round(64 * u);                              // clear of the window buttons and the gear
    CGFloat right = W - margin;

    if (style == CDStyleDisc) {
        // Subject centred and large; title in the bottom-left corner; transport + progress in the bottom-right
        // corner with the little list just above them.
        [self layoutTransportCenter:NSMakePoint(right - round(14 * u) - self.skipGap, cy)];
        CGFloat volumeW = round(40 * u) + 2 + round(92 * u);
        CGFloat volumeX = NSMinX(self.prevButton.frame) - round(22 * u) - volumeW;
        [self layoutVolumeLeft:volumeX centerY:cy];
        CGFloat clusterLeft = session ? volumeX : W;
        CGFloat progressW = MIN(round(430 * u), right - volumeX);
        [self layoutProgressLeft:right - progressW centerY:progressY width:progressW];
        NSRect listRect = [self listRectRight:right bottom:progressY - round(22 * u)];
        [self placeList:listRect];
        CGFloat textW = MIN(W * .4, MAX(220 * u, clusterLeft - margin - round(60 * u)));
        if (!session) textW = MIN(W * .5, 620 * u);
        CGFloat indexH = session ? [self heightOf:self.indexLabel width:textW] : 0;
        CGFloat titleH = [self heightOf:self.titleLabel width:textW], subH = [self heightOf:self.subtitleLabel width:textW];
        CGFloat buttons = session ? 0 : round(44 * u) + round(22 * u);
        CGFloat blockH = (session ? indexH + round(8 * u) : 0) + titleH + round(6 * u) + subH + buttons;
        CGFloat blockBottom = session ? cy + P / 2 - round(10 * u) : H - round(40 * u);
        CGFloat y = blockBottom - blockH;
        CGFloat textTop = y;
        if (session) y += [self place:self.indexLabel x:margin y:y width:textW] + round(8 * u);
        y += [self place:self.titleLabel x:margin y:y width:textW] + round(6 * u);
        y += [self place:self.subtitleLabel x:margin y:y width:textW];
        if (!session) [self layoutEmptyButtonsX:margin top:y + round(22 * u) centered:NO];
        CGFloat areaBottom = MIN(textTop, session ? progressY - 12 : H) - round(26 * u);
        CGFloat heroH = MIN(MIN(areaBottom - top, H * .7), W * .84 / self.hero.aspect);
        CGFloat heroY = top + (areaBottom - top - heroH) / 2;
        // Keep the disc clear of the list: if they would meet, narrow the disc rather than squeeze the list.
        if (list && heroY + heroH > NSMinY(listRect) - gap) heroH = MIN(heroH, 2 * (NSMinX(listRect) - gap - W / 2) / self.hero.aspect);
        CGFloat heroW = heroH * self.hero.aspect;
        self.hero.frame = NSIntegralRect(NSMakeRect(W / 2 - heroW / 2, top + (areaBottom - top - heroH) / 2, heroW, heroH));
    } else {
        // Ethereal, cassette and pixel screen: subject centred, controls pressed down to the bottom edge,
        // the list in the bottom-right corner where a button would be.
        BOOL pixel = style == CDStylePixelScreen, cassette = style == CDStyleCassette;
        [self layoutTransportCenter:NSMakePoint(W / 2, cy)];
        [self layoutVolumeLeft:margin centerY:cy];
        CGFloat progressW = MIN(round(560 * u), W * .42);
        [self layoutProgressLeft:W / 2 - progressW / 2 centerY:progressY width:progressW];
        NSRect listRect = [self listRectRight:right bottom:cy + round(26 * u)];
        [self placeList:listRect];
        CGFloat textW = MIN(W * .62, 760 * u);
        if (list) textW = MIN(textW, 2 * (NSMinX(listRect) - gap - W / 2));
        CGFloat indexH = session && !pixel ? [self heightOf:self.indexLabel width:textW] : 0;
        CGFloat titleH = pixel ? 0 : [self heightOf:self.titleLabel width:textW], subH = pixel ? 0 : [self heightOf:self.subtitleLabel width:textW];
        CGFloat textBlock = pixel ? 0 : (indexH ? indexH + round(6 * u) : 0) + titleH + round(6 * u) + subH;
        CGFloat buttons = session ? 0 : round(26 * u) + round(44 * u);
        CGFloat heroGap = pixel ? 0 : round(34 * u);
        // The pixel screen is sized as a bare screen first; its housing then grows into the free space around it.
        CGFloat aspect = pixel ? [CDPixelScreenView screenAspect] : self.hero.aspect;
        // Sizes the subject for a given floor and width limit; returns its frame (the text block follows below it).
        NSRect (^fit)(CGFloat, CGFloat) = ^NSRect(CGFloat bottomLimit, CGFloat maxW) {
            CGFloat avail = bottomLimit - top - textBlock - heroGap - buttons, heroH, heroW;
            if (cassette) { heroW = MIN(MIN(W * .64, maxW), avail * aspect); heroH = heroW / aspect; }
            else if (pixel) { heroH = MIN(MIN(avail, W * .84 / aspect), maxW / aspect); heroW = heroH * aspect; }
            else { heroH = MIN(MIN(avail, MIN(H * .62, W * .44)), maxW / aspect); heroW = heroH; }
            CGFloat blockH = heroH + heroGap + textBlock + buttons;
            return NSMakeRect(W / 2 - heroW / 2, top + (bottomLimit - top - blockH) / 2, heroW, heroH);
        };
        CGFloat bottomLimit = session ? (pixel ? cy - P / 2 : progressY - 12) - round(28 * u) : H - round(48 * u);
        NSRect hero = fit(bottomLimit, W);
        if (list && NSIntersectsRect(NSInsetRect(hero, -gap, -gap), listRect)) {
            // The subject would run into the corner list: either narrow it or lift its floor, whichever keeps it bigger.
            NSRect narrow = fit(bottomLimit, 2 * (NSMinX(listRect) - gap - W / 2));
            NSRect lifted = fit(MIN(bottomLimit, NSMinY(listRect) - gap + textBlock + heroGap), W);
            hero = NSWidth(narrow) >= NSWidth(lifted) ? narrow : lifted;
        }
        if (pixel) {
            CGFloat side = MAX(round(36 * u), W * .05);
            CGFloat floorY = session ? cy - P / 2 - round(18 * u) : H - round(48 * u) - buttons;
            NSRect limits = NSMakeRect(side, top + round(6 * u), W - side * 2, floorY - top - round(6 * u));
            hero = [CDPixelScreenView housingForScreen:hero within:limits avoiding:list ? NSInsetRect(listRect, -gap, -gap) : NSZeroRect scale:self.window.backingScaleFactor ?: 2];
        }
        self.hero.frame = NSIntegralRect(hero);
        CGFloat y = NSMaxY(hero) + heroGap;
        if (!pixel) {
            if (indexH) y += [self place:self.indexLabel x:W / 2 - textW / 2 y:y width:textW] + round(6 * u);
            y += [self place:self.titleLabel x:W / 2 - textW / 2 y:y width:textW] + round(6 * u);
            y += [self place:self.subtitleLabel x:W / 2 - textW / 2 y:y width:textW];
        }
        if (!session) [self layoutEmptyButtonsX:W / 2 top:y + round(26 * u) centered:YES];
    }
    [self updateVisibility];
}

- (BOOL)listShown { return self.hasSession && self.listPreference; }

- (void)updateVisibility {
    BOOL session = self.hasSession, pixel = self.styleIndex == CDStylePixelScreen;
    self.titleLabel.hidden = pixel;
    self.subtitleLabel.hidden = pixel;
    self.indexLabel.hidden = pixel || !session;
    for (NSView *view in @[self.prevButton, self.playButton, self.nextButton, self.muteButton, self.volumeSlider]) view.hidden = !session;
    for (NSView *view in @[self.progress, self.elapsedLabel, self.remainingLabel]) view.hidden = !session || pixel;
    self.trackList.hidden = !self.listShown;
    self.openButton.hidden = session;
    self.demoButton.hidden = session;
    self.libraryButton.hidden = session;
}

#pragma mark - Theme and text

- (void)applyTheme {
    CDPalette *p = self.palette;
    self.np.hasSession = self.hasSession;       // the hero picks its idle art from this as the palette lands
    self.window.appearance = [NSAppearance appearanceNamed:p.light ? NSAppearanceNameAqua : NSAppearanceNameDarkAqua];
    self.window.backgroundColor = p.base;
    self.backdrop.mode = self.backgroundMode;
    self.backdrop.blurLevel = self.blurLevel;
    self.backdrop.particles = self.particles;
    [self.backdrop applyPalette:p];
    self.hero.palette = p;
    self.hero.coverColors = self.backdrop.coverColors;
    NSColor *glow = p.light ? CDMix(p.accent, p.ink, .12) : CDMix(p.ink, p.accent, .35);
    for (CDSoftButton *button in @[self.prevButton, self.playButton, self.nextButton, self.muteButton, self.gearButton, self.openButton, self.demoButton, self.libraryButton, self.libraryEntryButton]) {
        button.tint = [p ink:button == self.playButton ? .95 : (p.light ? .78 : .82)];
        button.glowColor = glow;
        button.restGlow = 0;
    }
    self.playButton.restGlow = .85;
    // Volume sits back until it is reached for.
    self.muteButton.restOpacity = .42;
    self.volumeSlider.restOpacity = .45;
    self.openButton.restGlow = .25;
    self.demoButton.restGlow = .25;
    self.libraryButton.restGlow = .25;
    // A wall fading out over a CD that just started keeps its colours; it takes the new ones when it next opens.
    if (!self.albumWallClosing) { self.albumWall.palette = p; [self configureWallBackdrop]; }
    NSColor *fill = [CDMix(p.ink, p.accent, p.light ? .45 : .3) colorWithAlphaComponent:.9];
    for (CDSliderView *slider in @[self.progress, self.volumeSlider]) { slider.trackColor = [p ink:p.light ? .12 : .16]; slider.fillColor = fill; [slider setNeedsDisplay:YES]; }
    self.trackList.glowColor = glow;
    self.trackList.palette = p;
    [self.toast applyPalette:p];
    [self.dropOverlay applyPalette:p];
    [self refreshBackdropCover];
    [self refreshLabels];
}

- (void)crossfade:(CFTimeInterval)duration {
    CATransition *fade = [CATransition animation];
    fade.type = kCATransitionFade;
    fade.duration = duration;
    [self.stage.layer addAnimation:fade forKey:@"stageFade"];
}

- (NSString *)currentTrackName {
    return self.trackIndex < (NSInteger)self.trackNames.count ? self.trackNames[self.trackIndex] : [NSString stringWithFormat:@"Track %ld", (long)self.trackIndex + 1];
}

- (NSString *)albumLine {
    NSMutableArray *parts = [NSMutableArray new];
    if (self.albumTitle.length) [parts addObject:self.albumTitle];
    if (self.albumArtist.length && ![@[@"虚拟 CD", @"未知艺人"] containsObject:self.albumArtist]) [parts addObject:self.albumArtist];
    return [parts componentsJoinedByString:@"  ·  "];
}

- (void)refreshLabels {
    CDPalette *p = self.palette;
    CGFloat u = self.u ?: 1;
    BOOL session = self.hasSession;
    CDStyle style = self.styleIndex;
    NSTextAlignment align = self.cornerLayout ? NSTextAlignmentLeft : NSTextAlignmentCenter;
    NSFont *titleFont;
    CGFloat kern = 0;
    switch (style) {
        case CDStyleEthereal: titleFont = CDSerifFont(round(30 * u), NSFontWeightLight); kern = .4; break;
        case CDStyleDisc: titleFont = [NSFont systemFontOfSize:round(30 * u) weight:NSFontWeightLight]; kern = -.2; break;
        case CDStyleCassette: titleFont = CDRoundedFont(round(24 * u), NSFontWeightMedium); break;
        default: titleFont = [NSFont systemFontOfSize:round(26 * u) weight:NSFontWeightRegular]; break;
    }
    NSString *title = session ? self.currentTrackName : @"放入一张 CD";
    NSString *subtitle = session ? self.albumLine : @"或把音乐文件夹拖进窗口";
    self.titleLabel.attributedStringValue = [[NSAttributedString alloc] initWithString:title attributes:CDAttrs(titleFont, p.ink, kern, align, YES)];
    self.subtitleLabel.attributedStringValue = [[NSAttributedString alloc] initWithString:subtitle attributes:CDAttrs([NSFont systemFontOfSize:round(13.5 * u) weight:NSFontWeightRegular], [p ink:p.secondary], .5, align, NO)];
    NSString *index = [NSString stringWithFormat:@"%ld / %ld", (long)self.trackIndex + 1, (long)self.trackCount];
    self.indexLabel.attributedStringValue = [[NSAttributedString alloc] initWithString:index attributes:CDAttrs([NSFont monospacedDigitSystemFontOfSize:round(11.5 * u) weight:NSFontWeightMedium], [p ink:p.tertiary], 2.4, align, NO)];
    [self refreshTimeLabels];
    self.np.hasSession = session;
    self.np.album = self.albumTitle ?: @"";
    self.np.artist = [@[@"虚拟 CD", @"未知艺人"] containsObject:self.albumArtist ?: @""] ? @"" : (self.albumArtist ?: @"");
    self.np.track = session ? self.currentTrackName : @"";
    self.np.index = self.trackIndex;
    self.np.count = self.trackCount;
    NSMutableArray *names = [NSMutableArray new];
    for (NSInteger i = 0; i < self.trackCount; i++) [names addObject:i < (NSInteger)self.trackNames.count ? self.trackNames[i] : [NSString stringWithFormat:@"Track %ld", (long)i + 1]];
    self.np.trackNames = names;
    [self.hero nowPlayingChanged];
    if (![self.trackList.names isEqualToArray:names]) self.trackList.names = names;
    self.trackList.heading = @"LIST";
    self.trackList.current = session ? self.trackIndex : -1;
    self.trackList.playing = self.np.playing;
    self.stage.needsLayout = YES;
}

- (void)refreshTimeLabels {
    CDPalette *p = self.palette;
    CGFloat u = self.u ?: 1;
    NSFont *font = [NSFont monospacedDigitSystemFontOfSize:round(11.5 * u) weight:NSFontWeightRegular];
    long long elapsed = self.np.elapsedMS, duration = self.np.durationMS;
    self.elapsedLabel.attributedStringValue = [[NSAttributedString alloc] initWithString:CDTime(elapsed) attributes:CDAttrs(font, [p ink:p.tertiary], .3, NSTextAlignmentRight, NO)];
    self.remainingLabel.attributedStringValue = [[NSAttributedString alloc] initWithString:duration > 0 ? [@"-" stringByAppendingString:CDTime(MAX(0, duration - elapsed))] : @"--:--" attributes:CDAttrs(font, [p ink:p.tertiary], .3, NSTextAlignmentLeft, NO)];
}

- (void)setPlayingState:(BOOL)playing {
    self.np.playing = playing;
    self.playButton.symbol = playing ? @"pause.fill" : @"play.fill";
    self.trackList.playing = playing;
    [self.hero nowPlayingChanged];
    if (!playing) [self setChromeHidden:NO animated:YES];
}

#pragma mark - Gear menu

- (void)showGearMenu:(id)sender {
    NSMenu *menu = [NSMenu new];
    [menu addItemWithTitle:@"从文件夹模拟 CD…" action:@selector(openVirtual:) keyEquivalent:@""].target = self;
    [menu addItemWithTitle:@"播放测试 CD" action:@selector(playDemo:) keyEquivalent:@""].target = self;
    [menu addItemWithTitle:@"专辑墙…" action:@selector(showAlbumWall:) keyEquivalent:@""].target = self;
    [menu addItemWithTitle:@"扫描文件夹加入专辑墙…" action:@selector(scanLibraryFolder:) keyEquivalent:@""].target = self;
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *styleItem = [menu addItemWithTitle:@"界面风格" action:nil keyEquivalent:@""];
    NSMenu *styles = [NSMenu new];
    for (NSInteger i = 0; i < (NSInteger)self.styleNames.count; i++) {
        NSMenuItem *item = [styles addItemWithTitle:self.styleNames[i] action:@selector(selectStyle:) keyEquivalent:@""];
        item.target = self; item.tag = i; item.state = i == self.styleIndex ? NSControlStateValueOn : NSControlStateValueOff;
        item.image = [NSImage imageWithSystemSymbolName:self.styleSymbols[i] accessibilityDescription:nil];
    }
    styleItem.submenu = styles;
    NSMenuItem *themeItem = [menu addItemWithTitle:@"界面色调" action:nil keyEquivalent:@""];
    NSMenu *themes = [NSMenu new];
    for (NSInteger i = 0; i < CDPalette.count; i++) {
        NSMenuItem *item = [themes addItemWithTitle:CDPalette.names[i] action:@selector(selectTheme:) keyEquivalent:@""];
        item.target = self; item.tag = i; item.state = i == self.themeIndex ? NSControlStateValueOn : NSControlStateValueOff;
        item.image = [[CDPalette paletteAtIndex:i] swatch];
    }
    themeItem.submenu = themes;
    NSMenuItem *backgroundItem = [menu addItemWithTitle:@"背景" action:nil keyEquivalent:@""];
    NSMenu *backgrounds = [NSMenu new];
    // Tags: 0 柔光纯色, 10–12 封面柔焦 at 朦胧 / 柔和 / 清晰, 2 封面取色柔焦.
    NSArray *entries = @[@[@"柔光纯色", @0, @0], @[@"封面柔焦", @-1, @0], @[@"朦胧", @10, @1], @[@"柔和", @11, @1], @[@"清晰（更看得清封面）", @12, @1], @[@"封面取色柔焦", @2, @0]];
    for (NSArray *entry in entries) {
        NSInteger tag = [entry[1] integerValue];
        NSMenuItem *item = [backgrounds addItemWithTitle:entry[0] action:tag >= 0 ? @selector(selectBackground:) : nil keyEquivalent:@""];
        item.target = self; item.tag = tag; item.indentationLevel = [entry[2] integerValue];
        BOOL on = tag >= 10 ? (self.backgroundMode == 1 && self.blurLevel == tag - 10) : (tag >= 0 && self.backgroundMode == tag);
        item.state = on ? NSControlStateValueOn : NSControlStateValueOff;
        if (tag < 0) item.enabled = NO;
    }
    [backgrounds addItem:[NSMenuItem separatorItem]];
    NSMenuItem *motes = [backgrounds addItemWithTitle:@"浮光粒子" action:@selector(toggleParticles:) keyEquivalent:@""];
    motes.target = self; motes.state = self.particles ? NSControlStateValueOn : NSControlStateValueOff;
    backgroundItem.submenu = backgrounds;
    NSMenuItem *enhanceItem = [menu addItemWithTitle:@"封面画质增强" action:nil keyEquivalent:@""];
    NSMenu *enhancements = [NSMenu new];
    NSArray *enhancementNames = @[@"关闭", @"自动", @"2×", @"4×"];
    for (NSInteger i = 0; i < (NSInteger)enhancementNames.count; i++) {
        NSMenuItem *item = [enhancements addItemWithTitle:enhancementNames[i] action:@selector(selectEnhancement:) keyEquivalent:@""];
        item.target = self; item.tag = i; item.state = i == self.enhancementMode ? NSControlStateValueOn : NSControlStateValueOff;
    }
    enhanceItem.submenu = enhancements;
    NSMenuItem *blurItem = [menu addItemWithTitle:@"全局高斯模糊（试验）…" action:@selector(showBlurPanel:) keyEquivalent:@""];
    blurItem.target = self; blurItem.state = self.globalBlurOn ? NSControlStateValueOn : NSControlStateValueOff;
    if (self.trackCount) {
        [menu addItem:[NSMenuItem separatorItem]];
        [menu addItemWithTitle:@"候选封面…" action:@selector(showCandidateCovers:) keyEquivalent:@""].target = self;
        [menu addItemWithTitle:@"更换错误封面…" action:@selector(chooseCover:) keyEquivalent:@""].target = self;
        [menu addItemWithTitle:@"恢复自动封面" action:@selector(resetCover:) keyEquivalent:@""].target = self;
        [menu addItemWithTitle:@"重新联网匹配" action:@selector(findOnlineCover:) keyEquivalent:@""].target = self;
        [menu addItemWithTitle:@"结束播放" action:@selector(endSession:) keyEquivalent:@""].target = self;
    }
    self.menuOpen = YES;
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, -4) inView:self.gearButton];
    self.menuOpen = NO;
    self.lastActivity = CACurrentMediaTime();
}

#pragma mark - Trial blur

// A temporary control for trying a Gaussian blur over everything the window draws. The amount is σ as a percentage
// of the window's width, 0.001 % – 3 % on a logarithmic slider (the range spans more than three decades).
static double CDBlurFromSlider(double t) { return .001 * pow(3000, MAX(0, MIN(1, t))); }
static double CDBlurToSlider(double percent) { return log(MAX(.001, MIN(3, percent)) / .001) / log(3000); }
static NSString *CDBlurText(double percent) { return [NSString stringWithFormat:@"%.3g", percent]; }

- (CGFloat)globalBlurSigma { return self.globalBlurOn ? self.globalBlur / 100 * NSWidth(self.window.contentView.bounds) : 0; }
- (void)applyGlobalBlur {
    NSView *root = self.window.contentView;
    root.wantsLayer = YES;
    CGFloat sigma = self.globalBlurSigma;
    if (sigma <= 0) { root.layer.filters = nil; [self refreshBlurPanel]; return; }
    // Core Animation's own blur (its radius is σ in points) normalises the edges, so the window's borders do not
    // fade; Core Image's needs a clamp for that, and is the fallback.
    Class caFilter = NSClassFromString(@"CAFilter");
    id filter = [caFilter respondsToSelector:@selector(filterWithType:)] ? ((id (*)(id, SEL, NSString *))objc_msgSend)(caFilter, @selector(filterWithType:), @"gaussianBlur") : nil;
    if (filter) {
        [filter setValue:@(sigma) forKey:@"inputRadius"];
        [filter setValue:@YES forKey:@"inputNormalizeEdges"];
        root.layer.filters = @[filter];
    } else {
        root.layerUsesCoreImageFilters = YES;
        CIFilter *clamp = [CIFilter filterWithName:@"CIAffineClamp"];
        [clamp setValue:[NSAffineTransform transform] forKey:@"inputTransform"];
        CIFilter *blur = [CIFilter filterWithName:@"CIGaussianBlur"];
        [blur setValue:@(sigma / 1.22) forKey:kCIInputRadiusKey];    // measured: CI's radius 8 spreads like σ ≈ 9.75 pt
        root.layer.filters = @[clamp, blur];
    }
    [self refreshBlurPanel];
}
- (void)setGlobalBlurPercent:(double)percent on:(BOOL)on {
    self.globalBlur = MAX(.001, MIN(3, percent));
    self.globalBlurOn = on;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setDouble:self.globalBlur forKey:@"CDGlassGlobalBlur"];
    [defaults setBool:on forKey:@"CDGlassGlobalBlurOn"];
    [self applyGlobalBlur];
}
- (void)showBlurPanel:(id)sender {
    if (!self.blurPanel) {
        NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 380, 150)
                                                    styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskUtilityWindow | NSWindowStyleMaskHUDWindow
                                                      backing:NSBackingStoreBuffered defer:NO];
        panel.title = @"全局高斯模糊（试验）";
        panel.floatingPanel = YES; panel.releasedWhenClosed = NO; panel.becomesKeyOnlyIfNeeded = YES;
        panel.collectionBehavior = NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorMoveToActiveSpace;
        NSView *root = panel.contentView;
        NSButton *toggle = [NSButton checkboxWithTitle:@"开启" target:self action:@selector(blurSwitched:)];
        toggle.frame = NSMakeRect(18, 110, 90, 22);
        NSTextField *field = [NSTextField textFieldWithString:@""];
        field.frame = NSMakeRect(250, 110, 92, 24);
        field.alignment = NSTextAlignmentRight;
        field.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular];
        field.target = self; field.action = @selector(blurTyped:);
        field.toolTip = @"输入 0.001 到 3 之间的百分比，回车生效；输入 0 关闭";
        NSTextField *percent = [NSTextField labelWithString:@"%"];
        percent.frame = NSMakeRect(346, 113, 20, 18);
        NSSlider *slider = [NSSlider sliderWithValue:0 minValue:0 maxValue:1 target:self action:@selector(blurSlid:)];
        slider.frame = NSMakeRect(16, 76, 348, 24);
        slider.continuous = YES;
        NSTextField *low = [NSTextField labelWithString:@"0.001%"], *high = [NSTextField labelWithString:@"3%"];
        low.frame = NSMakeRect(18, 58, 80, 16); high.frame = NSMakeRect(284, 58, 78, 16); high.alignment = NSTextAlignmentRight;
        NSTextField *note = [NSTextField wrappingLabelWithString:@""];
        note.frame = NSMakeRect(18, 12, 344, 36);
        for (NSTextField *label in @[low, high, note]) { label.font = [NSFont systemFontOfSize:11]; label.textColor = NSColor.secondaryLabelColor; }
        for (NSView *view in @[toggle, field, percent, slider, low, high, note]) [root addSubview:view];
        self.blurPanel = panel; self.blurSwitch = toggle; self.blurField = field; self.blurSlider = slider; self.blurNote = note;
#ifdef CDGLASS_SNAPSHOT
        panel.hidesOnDeactivate = NO;       // the test copy is never the active app
#endif
    }
    // Top right, just under the gear, over whichever screen the player is on.
    NSRect frame = self.window.frame;
    [self.blurPanel setFrameTopLeftPoint:NSMakePoint(NSMaxX(frame) - NSWidth(self.blurPanel.frame) - 24, NSMaxY(frame) - 64)];
    [self refreshBlurPanel];
    [self.blurPanel orderFront:nil];
}
- (void)refreshBlurPanel {
    if (!self.blurPanel) return;
    self.blurSwitch.state = self.globalBlurOn ? NSControlStateValueOn : NSControlStateValueOff;
    if (!self.blurField.currentEditor) self.blurField.stringValue = CDBlurText(self.globalBlur);     // not while typing
    self.blurSlider.doubleValue = CDBlurToSlider(self.globalBlur);
    CGFloat width = NSWidth(self.window.contentView.bounds), sigma = self.globalBlur / 100 * width;
    self.blurNote.stringValue = self.globalBlurOn
        ? [NSString stringWithFormat:@"σ ≈ %@ pt（窗口宽 %.0f pt 的 %@%%）· 作用于窗口里的全部画面", [NSString stringWithFormat:@"%.3g", sigma], width, CDBlurText(self.globalBlur)]
        : @"已关闭 · 拖动滑条或输入数值就会开启";
}
- (void)blurSlid:(NSSlider *)sender {
    [self.blurPanel makeFirstResponder:nil];
    [self setGlobalBlurPercent:CDBlurFromSlider(sender.doubleValue) on:YES];
}
- (void)blurTyped:(NSTextField *)sender {
    NSString *text = [[[sender.stringValue stringByReplacingOccurrencesOfString:@"%" withString:@""] stringByReplacingOccurrencesOfString:@"，" withString:@"."] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSScanner *scanner = [NSScanner scannerWithString:text];
    double value = 0;
    if (![scanner scanDouble:&value] || value < 0) { [self refreshBlurPanel]; NSBeep(); return; }
    if (value == 0) [self setGlobalBlurPercent:self.globalBlur on:NO];
    else [self setGlobalBlurPercent:value on:YES];
    sender.stringValue = CDBlurText(self.globalBlur);
}
- (void)blurSwitched:(NSButton *)sender { [self setGlobalBlurPercent:self.globalBlur on:sender.state == NSControlStateValueOn]; }

- (void)selectStyle:(NSMenuItem *)sender {
    if (sender.tag == self.styleIndex) return;
    self.styleIndex = MAX(CDStyleEthereal, MIN(CDStylePixelScreen, sender.tag));
    [NSUserDefaults.standardUserDefaults setInteger:self.styleIndex forKey:@"CDGlassStyleV2"];
    [self crossfade:.55];
    [self installHero];
    [self.stage layoutSubtreeIfNeeded];
}
- (void)cycleCassetteLook {
    if (self.styleIndex != CDStyleCassette || ![self.hero isKindOfClass:CDCassetteHero.class]) return;
    self.cassetteLook = (self.cassetteLook + 1) % 3;
    [NSUserDefaults.standardUserDefaults setInteger:self.cassetteLook forKey:@"CDGlassCassetteLook"];
    [self crossfade:.45];
    ((CDCassetteHero *)self.hero).look = self.cassetteLook;
    NSArray *names = @[@"封面印在标签上", @"封面印满外壳", @"取色彩壳 + 封面贴纸"];
    [self.toast show:names[self.cassetteLook] busy:NO];
}
- (void)selectTheme:(NSMenuItem *)sender {
    self.themeIndex = sender.tag;
    [NSUserDefaults.standardUserDefaults setInteger:self.themeIndex forKey:@"CDGlassTheme"];
    [self crossfade:.6];
    [self applyTheme];
    if (!self.hasSession) [self.toast show:[NSString stringWithFormat:@"放入 CD 后换成「%@」", CDPalette.names[self.themeIndex]] busy:NO];
}
- (void)selectBackground:(NSMenuItem *)sender {
    if (sender.tag >= 10) {
        self.backgroundMode = 1;
        self.blurLevel = MIN(2, sender.tag - 10);
        [NSUserDefaults.standardUserDefaults setInteger:self.blurLevel forKey:@"CDGlassBlurLevel"];
    } else self.backgroundMode = MAX(0, MIN(2, sender.tag));
    [NSUserDefaults.standardUserDefaults setInteger:self.backgroundMode forKey:@"CDGlassBackgroundMode"];
    [self applyTheme];
}
- (void)toggleParticles:(id)sender {
    self.particles = !self.particles;
    [NSUserDefaults.standardUserDefaults setBool:self.particles forKey:@"CDGlassParticles"];
    self.backdrop.particles = self.particles;
}
- (void)selectEnhancement:(NSMenuItem *)sender {
    self.enhancementMode = sender.tag;
    [NSUserDefaults.standardUserDefaults setInteger:self.enhancementMode forKey:@"CDGlassEnhancementMode"];
    if (self.sourceCover) [self setCoverImage:self.sourceCover];
}
- (void)toggleList:(id)sender {
    if (!self.hasSession) return;
    self.listPreference = !self.listPreference;
    [NSUserDefaults.standardUserDefaults setBool:self.listPreference forKey:@"CDGlassListVisible"];
    [self crossfade:.3];
    [self layoutStage];
    if (!self.trackList.hidden) [self.trackList scrollToCurrent:NO];
}

#pragma mark - Cover

- (void)setCoverImage:(NSImage *)image {
    NSUInteger token = ++self.enhancementToken;
    self.sourceCover = image;
    self.displayCover = image;
    [self refreshBackdropCover];
    self.hero.cover = image;
    if (image) [self enhanceCover:image token:token];
}

/// The backdrop blurs the cover; with no CD in, the idle sleeve, as it would any CD's.
- (NSImage *)backdropCover { return self.sourceCover ?: (self.hasSession || self.replacingSession ? nil : CDIdleCover()); }
- (void)refreshBackdropCover {
    NSImage *image = self.backdropCover;
    if (image == self.backdropShown && image) return;
    self.backdropShown = image;
    [self.backdrop setCoverImage:image];
    if (self.albumWall) [self.albumWall.backdrop setCoverImage:image];
    self.hero.coverColors = self.backdrop.coverColors;
}

- (void)showEnhanced:(NSImage *)image {
    self.displayCover = image;
    self.hero.cover = image;
}

- (void)enhanceCover:(NSImage *)image token:(NSUInteger)token {
    if (self.enhancementMode == 0) return;
    CGImageRef cg = [image CGImageForProposedRect:NULL context:nil hints:nil];
    if (!cg) return;
    size_t width = CGImageGetWidth(cg), height = CGImageGetHeight(cg);
    NSInteger scale = self.enhancementMode == 1 ? (MIN(width, height) < 420 ? 4 : MIN(width, height) < 950 ? 2 : 0) : (self.enhancementMode == 2 ? 2 : 4);
    if (!scale || width > 1800 || height > 1800) return;
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithCGImage:cg];
    NSData *data = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (!data.length) return;
    unsigned char hash[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(data.bytes, (CC_LONG)data.length, hash);
    NSMutableString *stem = [NSMutableString new];
    for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [stem appendFormat:@"%02x", hash[i]];
    NSString *directory = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"CD Glass/Upscaled"];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *output = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-%ldx.png", stem, (long)scale]];
    NSImage *cached = [[NSImage alloc] initWithContentsOfFile:output];
    if (cached) { if (token == self.enhancementToken) [self showEnhanced:cached]; return; }
    NSString *input = [directory stringByAppendingPathComponent:[stem stringByAppendingString:@"-source.png"]];
    if (![data writeToFile:input atomically:YES]) return;
    NSString *bundle = [[NSBundle mainBundle].resourcePath stringByAppendingPathComponent:@"RealESRGAN"];
    NSString *executable = [bundle stringByAppendingPathComponent:@"realesrgan-ncnn-vulkan"];
    NSString *models = [bundle stringByAppendingPathComponent:@"models"];
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:executable]) return;
    NSString *model = scale == 2 ? @"realesr-animevideov3" : @"realesrgan-x4plus-anime";
    [self.toast show:[NSString stringWithFormat:@"正在本地增强封面 · %ld×", (long)scale] busy:YES];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSTask *task = [NSTask new]; task.executableURL = [NSURL fileURLWithPath:executable];
        task.arguments = @[@"-i", input, @"-o", output, @"-m", models, @"-n", model, @"-s", [NSString stringWithFormat:@"%ld", (long)scale]];
        task.standardOutput = [NSFileHandle fileHandleWithNullDevice]; task.standardError = [NSFileHandle fileHandleWithNullDevice];
        NSError *error = nil; BOOL started = [task launchAndReturnError:&error];
        if (started) [task waitUntilExit];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (token != self.enhancementToken) return;
            NSImage *enhanced = started && task.terminationStatus == 0 ? [[NSImage alloc] initWithContentsOfFile:output] : nil;
            if (enhanced) { [self showEnhanced:enhanced]; [self.toast show:[NSString stringWithFormat:@"封面已在本机增强 · %ld×", (long)scale] busy:NO]; }
            else [self.toast show:@"本地增强未完成 · 正在显示原图" busy:NO];
        });
    });
}

#pragma mark - Drag and drop

- (NSString *)dropMessageFor:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return nil;
    NSNumber *directory = nil; [url getResourceValue:&directory forKey:NSURLIsDirectoryKey error:nil];
    NSString *ext = url.pathExtension.lowercaseString;
    NSString *message = nil;
    if (directory.boolValue || [@[@"wav", @"aiff", @"aif", @"mp3", @"m4a", @"flac", @"ogg", @"cue"] containsObject:ext]) message = @"松开即可播放这张虚拟 CD";
    else if ([@[@"jpg", @"jpeg", @"png", @"webp", @"heic"] containsObject:ext] && self.hasSession) message = @"松开即可设为这张 CD 的封面";
    if (message) { self.dropOverlay.message = message; self.dropOverlay.hidden = NO; }
    return message;
}

- (BOOL)acceptDrop:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return NO;
    NSNumber *directory = nil; [url getResourceValue:&directory forKey:NSURLIsDirectoryKey error:nil];
    NSString *ext = url.pathExtension.lowercaseString;
    if ([@[@"jpg", @"jpeg", @"png", @"webp", @"heic"] containsObject:ext]) {
        if (!self.hasSession) return NO;
        [self applyManualCoverFromURL:url];
        return YES;
    }
    NSURL *folder = directory.boolValue ? url : url.URLByDeletingLastPathComponent;
    dispatch_async(dispatch_get_main_queue(), ^{ [self loadVirtual:folder]; });
    return YES;
}

#pragma mark - Window

- (NSSize)window:(NSWindow *)window willUseFullScreenContentSize:(NSSize)proposedSize {
    // Use the full display width; never keep the launch window's aspect ratio.
    NSScreen *screen = window.screen ?: NSScreen.mainScreen;
    return NSMakeSize(NSWidth(screen.frame), proposedSize.height);
}
- (void)windowDidResize:(NSNotification *)notification {
    if (notification.object == self.candidatePanel) [self refreshCandidatePanel];
    if (notification.object == self.window && self.globalBlurOn) [self applyGlobalBlur];    // σ follows the width
}
- (void)windowDidEnterFullScreen:(NSNotification *)notification {
    [self.window.contentView layoutSubtreeIfNeeded];
    self.lastActivity = CACurrentMediaTime();
    NSString *log = (NSProcessInfo.processInfo.environment[@"CDGLASS_PROGRESS_LOG"] ?: [[NSUserDefaults standardUserDefaults] stringForKey:@"CDGlassDiagnosticLog"]);
    if (log.length) {
        NSString *geometry = [NSString stringWithFormat:@"screen=%@ window=%@ content=%@ stage=%@\n", NSStringFromRect(self.window.screen.frame), NSStringFromRect(self.window.frame), NSStringFromRect(self.window.contentView.frame), NSStringFromRect(self.stage.frame)];
        [geometry writeToFile:[log stringByAppendingString:@".geometry"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}
- (void)windowDidExitFullScreen:(NSNotification *)notification { [self setChromeHidden:NO animated:NO]; }

#pragma mark - Volume

- (void)setVolumeLevel:(NSInteger)volume persist:(BOOL)persist {
    volume = MAX(0, MIN(100, volume));
    self.np.volume = volume;
    if (!self.volumeSlider.scrubbing) self.volumeSlider.doubleValue = volume / 100.0;
    // While a stop or switch is under way the player is left alone; the switch sets the volume itself.
    if (self.player && !self.playerBusy) libvlc_audio_set_volume(self.player, (int)volume);
    if (volume > 0) self.savedVolume = volume;
    if (persist) [[NSUserDefaults standardUserDefaults] setInteger:volume forKey:@"CDGlassVolume"];
    NSString *symbol = volume == 0 ? @"speaker.slash.fill" : volume < 34 ? @"speaker.wave.1.fill" : volume < 67 ? @"speaker.wave.2.fill" : @"speaker.wave.3.fill";
    self.muteButton.symbol = symbol;
    self.volumeSlider.toolTip = [NSString stringWithFormat:@"音量 %ld%% · ↑ / ↓", (long)volume];
}
- (void)toggleMute:(id)sender {
    [self setVolumeLevel:self.np.volume ? 0 : (self.savedVolume ?: 75) persist:YES];
}

#pragma mark - Keyboard and idle chrome

- (void)handleKey:(NSEvent *)event {
    [self userActivity];
    if (event.keyCode == 53 && self.albumWallShown) { if (![self.albumWall dismissExpansion]) [self closeAlbumWall:nil]; return; }
    BOOL shift = (event.modifierFlags & NSEventModifierFlagShift) != 0;
    NSString *chars = event.charactersIgnoringModifiers.lowercaseString;
    if ([chars isEqualToString:@" "]) [self togglePlayback:nil];
    else if (event.keyCode == 123) { if (shift) [self seekBy:-10]; else [self previous:nil]; }
    else if (event.keyCode == 124) { if (shift) [self seekBy:10]; else [self next:nil]; }
    else if (event.keyCode == 126) [self setVolumeLevel:self.np.volume + 5 persist:YES];
    else if (event.keyCode == 125) [self setVolumeLevel:self.np.volume - 5 persist:YES];
    else if (event.keyCode == 53) {
        // Esc only leaves full screen; playback keeps going. ⌘W ends the session.
        if (self.isFullscreen) { self.wasFullscreen = NO; [self.window toggleFullScreen:nil]; }
    }
    else if ([chars isEqualToString:@"l"]) [self toggleList:nil];
    else if ([chars isEqualToString:@"f"]) [self.window toggleFullScreen:nil];
    else [self.window interpretKeyEvents:@[event]];
}

- (void)userActivity {
    self.lastActivity = CACurrentMediaTime();
    if (self.chromeHidden) [self setChromeHidden:NO animated:YES];
}

- (NSArray<NSView *> *)chromeViews {
    return @[self.progress, self.elapsedLabel, self.remainingLabel, self.prevButton, self.playButton, self.nextButton, self.muteButton, self.volumeSlider, self.trackList, self.gearButton, self.libraryEntryButton, self.toast];
}

- (void)setChromeHidden:(BOOL)hidden animated:(BOOL)animated {
    if (self.chromeHidden == hidden) return;
    self.chromeHidden = hidden;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = animated ? (hidden ? 1.1 : .35) : 0;
        context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        for (NSView *view in self.chromeViews) (animated ? view.animator : view).alphaValue = hidden ? 0 : 1;
    }];
    if (hidden) [NSCursor setHiddenUntilMouseMoves:YES];
}

- (BOOL)pointerOverChrome {
    NSPoint p = [self.stage convertPoint:self.window.mouseLocationOutsideOfEventStream fromView:nil];
    for (NSView *view in self.chromeViews) if (!view.hidden && NSPointInRect(p, NSInsetRect(view.frame, -12, -12))) return YES;
    return NO;
}

- (void)frameTick:(CADisplayLink *)link {
    CFTimeInterval now = link.timestamp;
    CFTimeInterval dt = self.lastFrame > 0 ? MIN(.1, MAX(0, now - self.lastFrame)) : 1 / 60.0;
    self.lastFrame = now;
    [self advanceFrame:dt];
}

- (void)advanceFrame:(CFTimeInterval)dt {
    if (!self.hero.hidden) [self.hero step:dt];
    BOOL idle = CACurrentMediaTime() - self.lastActivity > 4.0;
    if (!self.chromeHidden && idle && self.isFullscreen && self.hasSession && self.np.playing && !self.menuOpen && !self.candidatePanel && self.dropOverlay.hidden && !self.pointerOverChrome && !self.albumWallShown)
        [self setChromeHidden:YES animated:YES];
}

#pragma mark - Playback clock

- (void)tick:(NSTimer *)timer {
    [self scanDisc];
    if (!self.player || self.trackCount == 0 || self.playerBusy) return;
    libvlc_state_t state = libvlc_media_player_get_state(self.player);
    [self watchForStall:state];
    if (state == libvlc_Ended && !self.ending) { self.ending = YES; [self next:nil]; self.ending = NO; }
    if (self.cueSeekPending && state == libvlc_Playing) {
        libvlc_media_player_set_time(self.player, [self.virtualStarts[self.trackIndex] longLongValue]);
        self.cueSeekPending = NO;
        CDPlaybackClock clock; CDClockReset(&clock, [self.virtualStarts[self.trackIndex] doubleValue], CACurrentMediaTime(), true); self.playbackClock = clock;
        return;
    }
    [self displayTick:nil];
}

- (void)displayTick:(NSTimer *)timer {
    if (!self.player || !self.trackCount || self.progress.scrubbing || self.playerBusy) return;
    libvlc_time_t duration = libvlc_media_player_get_length(self.player);
    libvlc_time_t raw = libvlc_media_player_get_time(self.player);
    CDPlaybackClock clock = self.playbackClock;
    BOOL running = !self.paused && !self.cueSeekPending && libvlc_media_player_get_state(self.player) == libvlc_Playing;
    libvlc_time_t position = (libvlc_time_t)CDClockStep(&clock, raw, CACurrentMediaTime(), running, libvlc_media_player_get_rate(self.player));
    self.playbackClock = clock;
    if (self.virtualStarts.count == self.trackCount) {
        libvlc_time_t start = [self.virtualStarts[self.trackIndex] longLongValue];
        libvlc_time_t end = [self.virtualEnds[self.trackIndex] longLongValue];
        if (end > start && position >= end && !self.ending) { self.ending = YES; [self next:nil]; self.ending = NO; return; }
        if (end > start) duration = end - start;
        else if (duration > start) duration -= start;
        if (position >= 0) position = MAX(0, position - start);
    }
    if (duration > 0 && position >= 0) {
        self.progress.doubleValue = (double)position / (double)duration;
        NSString *log = (NSProcessInfo.processInfo.environment[@"CDGLASS_PROGRESS_LOG"] ?: [[NSUserDefaults standardUserDefaults] stringForKey:@"CDGlassDiagnosticLog"]);
        if (log.length) {
            NSString *line = [NSString stringWithFormat:@"%.6f,%lld,%lld,%.9f\n", CACurrentMediaTime(), raw, position, self.progress.doubleValue];
            NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:log];
            if (!handle) [[NSData data] writeToFile:log atomically:YES];
            handle = [NSFileHandle fileHandleForWritingAtPath:log]; [handle seekToEndOfFile]; [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [handle closeFile];
        }
        long long previousSecond = self.np.elapsedMS / 1000;
        self.np.elapsedMS = MIN(position, duration);
        self.np.durationMS = duration;
        self.np.trackProgress = self.progress.doubleValue;
        self.np.albumProgress = (self.trackIndex + self.progress.doubleValue) / MAX(1, self.trackCount);
        [self.hero progressChanged];
        if (previousSecond != self.np.elapsedMS / 1000 || [self.remainingLabel.stringValue isEqualToString:@"--:--"]) [self refreshTimeLabels];
    }
}

- (void)previewSeek:(double)fraction {
    long long elapsed = (long long)(fraction * self.np.durationMS);
    long long saved = self.np.elapsedMS;
    self.np.elapsedMS = elapsed;
    [self refreshTimeLabels];
    self.np.elapsedMS = saved;
}

- (void)seekBy:(double)seconds {
    if (!self.hasSession || self.np.durationMS <= 0) return;
    [self seekToFraction:(self.np.elapsedMS + seconds * 1000.0) / (double)self.np.durationMS];
}

- (void)seekToFraction:(double)fraction {
    if (!self.player || !self.trackCount || self.playerBusy) return;
    libvlc_time_t duration = libvlc_media_player_get_length(self.player);
    libvlc_time_t start = 0;
    if (self.virtualStarts.count == self.trackCount) {
        start = [self.virtualStarts[self.trackIndex] longLongValue];
        libvlc_time_t end = [self.virtualEnds[self.trackIndex] longLongValue];
        if (end > start) duration = end - start;
        else duration = MAX(0, duration - start);
    }
    if (duration > 0) {
        libvlc_time_t target = start + (libvlc_time_t)(MAX(0, MIN(1, fraction)) * duration);
        libvlc_media_player_set_time(self.player, target);
        CDPlaybackClock clock; CDClockReset(&clock, target, CACurrentMediaTime(), true); self.playbackClock = clock;
    }
    [self displayTick:nil];
}

- (void)scanDisc {
    if (self.trackCount && !self.physical) return;
    NSString *foundPath = nil;
    DRDevice *foundDevice = nil;
    BOOL ignoredStillPresent = NO;
    for (DRDevice *device in [DRDevice devices]) {
        NSDictionary *status = [device status];
        if (![status[DRDeviceMediaStateKey] isEqual:DRDeviceMediaStateMediaPresent]) continue;
        NSDictionary *media = status[DRDeviceMediaInfoKey];
        if (![media[DRDeviceMediaClassKey] isEqual:DRDeviceMediaClassCD]) continue;
        if ([status[DRDeviceTrackRefsKey] count] && ![self audioTracksFromStatus:status].count) continue;
        NSString *bsd = media[DRDeviceMediaBSDNameKey];
        if (bsd.length) {
            NSString *path = [@"/dev/r" stringByAppendingString:bsd];
            if (!self.physical && [path isEqualToString:self.ignoredDiscPath]) { ignoredStillPresent = YES; continue; }
            if (!foundPath || [path isEqualToString:self.discPath]) { foundPath = path; foundDevice = device; }
            if ([path isEqualToString:self.discPath]) break;
        }
    }
    if (!ignoredStillPresent) self.ignoredDiscPath = nil;
    if ([foundPath isEqualToString:self.ignoredDiscPath]) return;
    if (self.physical && ![self.discPath isEqualToString:foundPath]) {
        self.missingDiscTicks++;
        if (self.missingDiscTicks >= 2) [self endSession:nil];
        return;
    }
    self.missingDiscTicks = 0;
    if (!self.physical && foundPath) [self loadPhysical:foundDevice path:foundPath];
}

- (NSArray<NSNumber *> *)audioTracksFromStatus:(NSDictionary *)status {
    NSArray *refs = status[DRDeviceTrackRefsKey];
    NSDictionary *infos = status[DRDeviceTrackInfoKey];
    NSMutableArray<NSNumber *> *numbers = [NSMutableArray new];
    for (id ref in refs) {
        NSDictionary *info = infos[ref];
        NSNumber *number = info[DRTrackNumberKey];
        NSNumber *blockType = info[DRBlockTypeKey];
        if (number && (!blockType || blockType.integerValue == kDRBlockTypeAudio)) [numbers addObject:number];
    }
    [numbers sortUsingSelector:@selector(compare:)];
    return numbers;
}

- (void)loadPhysical:(DRDevice *)device path:(NSString *)path {
    NSDictionary *status = [device status];
    NSDictionary *media = status[DRDeviceMediaInfoKey];
    self.discPath = path; self.physical = YES;
    self.missingDiscTicks = 0;
    self.physicalTrackNumbers = [self audioTracksFromStatus:status];
    self.trackCount = self.physicalTrackNumbers.count ?: MAX(1,[media[DRDeviceMediaTrackCountKey] integerValue]);
    self.trackNames = nil;
    self.albumTitle = @"音频 CD"; self.albumArtist = @"正在识别专辑…";
    [self setCoverImage:nil];
    self.trackIndex = 0;
    self.discID = [self discIDFromStatus:status];
    self.discFingerprint = self.discID.length ? [@"physical-" stringByAppendingString:self.discID] : nil;
    NSDictionary *known = [self coverRecord];
    if ([known[@"album"] isKindOfClass:NSString.class] && [known[@"album"] length]) self.albumTitle = known[@"album"];
    if ([known[@"artist"] isKindOfClass:NSString.class] && [known[@"artist"] length]) self.albumArtist = known[@"artist"];
    if ([known[@"tracks"] isKindOfClass:NSArray.class] && [known[@"tracks"] count] == self.trackCount) self.trackNames = known[@"tracks"];
    [self applyStoredCover];
    [self showSession];
    [self playCurrent];
    // A disc seen before keeps its titles and cover; only an unknown one is looked up.
    BOOL knownTracks = self.trackNames.count == self.trackCount && ![self.albumTitle isEqualToString:@"音频 CD"];
    if (!knownTracks || [self needsCoverSearch]) [self lookupMetadata];
}

- (NSString *)discIDFromStatus:(NSDictionary *)status {
    NSArray *refs = status[DRDeviceTrackRefsKey];
    NSDictionary *infos = status[DRDeviceTrackInfoKey];
    if (!refs.count || !infos.count) return nil;
    NSMutableArray<NSDictionary *> *tracks = [NSMutableArray new];
    for (id ref in refs) {
        NSDictionary *info = infos[ref];
        if (info[DRTrackNumberKey] && info[DRTrackStartAddressKey] && info[DRTrackLengthKey]) [tracks addObject:info];
    }
    [tracks sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [a[DRTrackNumberKey] compare:b[DRTrackNumberKey]]; }];
    if (!tracks.count || tracks.count > 99) return nil;
    NSInteger first = [tracks.firstObject[DRTrackNumberKey] integerValue];
    NSInteger last = [tracks.lastObject[DRTrackNumberKey] integerValue];
    NSInteger leadout = [tracks.lastObject[DRTrackStartAddressKey] integerValue] + [tracks.lastObject[DRTrackLengthKey] integerValue] + 150;
    NSMutableString *toc = [NSMutableString stringWithFormat:@"%02lX%02lX%08lX",(long)first,(long)last,(long)leadout];
    for (NSInteger n=1;n<=99;n++) {
        NSDictionary *match = nil;
        for (NSDictionary *entry in tracks) if ([entry[DRTrackNumberKey] integerValue] == n) { match = entry; break; }
        NSInteger offset = match ? [match[DRTrackStartAddressKey] integerValue] + 150 : 0;
        [toc appendFormat:@"%08lX",(long)offset];
    }
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(toc.UTF8String,(CC_LONG)strlen(toc.UTF8String),digest);
    NSData *data = [NSData dataWithBytes:digest length:CC_SHA1_DIGEST_LENGTH];
    NSString *b64 = [data base64EncodedStringWithOptions:0];
    return [[[b64 stringByReplacingOccurrencesOfString:@"+" withString:@"."] stringByReplacingOccurrencesOfString:@"/" withString:@"_"] stringByReplacingOccurrencesOfString:@"=" withString:@"-"];
}

- (void)lookupMetadata {
    if (!self.discID.length) { self.albumArtist = @""; [self refreshLabels]; [self.toast show:@"未知专辑 · 仍可正常播放" busy:NO]; return; }
    NSString *expected = self.discID;
    NSString *url = [NSString stringWithFormat:@"https://musicbrainz.org/ws/2/discid/%@?inc=recordings+artist-credits&fmt=json",expected];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    [request setValue:@"CDGlass/0.4 (personal macOS CD player)" forHTTPHeaderField:@"User-Agent"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSArray *rawReleases = [json isKindOfClass:NSDictionary.class] ? json[@"releases"] : nil;
        NSArray *releases = [rawReleases isKindOfClass:NSArray.class] ? rawReleases : nil;
        NSDictionary *release = releases.firstObject;
        for (NSDictionary *candidate in releases) {
            NSDictionary *art = [candidate[@"cover-art-archive"] isKindOfClass:NSDictionary.class] ? candidate[@"cover-art-archive"] : nil;
            if ([art[@"front"] boolValue]) { release = candidate; break; }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![self.discID isEqualToString:expected] || !self.physical) return;
            if (!release) { self.albumArtist = @""; [self refreshLabels]; [self.toast show:@"未找到在线资料 · CD 仍可播放" busy:NO]; return; }
            self.albumTitle = release[@"title"] ?: @"音频 CD";
            NSMutableArray *artists = [NSMutableArray new];
            for (NSDictionary *credit in release[@"artist-credit"]) if ([credit isKindOfClass:NSDictionary.class] && credit[@"name"]) [artists addObject:credit[@"name"]];
            self.albumArtist = artists.count ? [artists componentsJoinedByString:@", "] : @"未知艺人";
            for (NSDictionary *medium in release[@"media"]) {
                NSArray *tracks = medium[@"tracks"];
                if (tracks.count == self.trackCount) {
                    NSMutableArray *names = [NSMutableArray new];
                    for (NSDictionary *track in tracks) [names addObject:track[@"title"] ?: @"未命名曲目"];
                    self.trackNames = names;
                    break;
                }
            }
            [self refreshLabels];
            NSMutableDictionary *known = [[self coverRecord] mutableCopy] ?: [NSMutableDictionary new];
            known[@"album"] = self.albumTitle ?: @"";
            known[@"artist"] = self.albumArtist ?: @"";
            known[@"tracks"] = self.trackNames ?: @[];
            [self writeCoverRecord:known];
            NSString *group = [release[@"release-group"] isKindOfClass:NSDictionary.class] ? release[@"release-group"][@"id"] : nil;
            if (![self hasStoredCover]) [self fetchCover:release[@"id"] group:group];
            if ([self needsCoverSearch]) [self lookupCandidateCovers];
        });
    }] resume];
}

- (void)fetchCover:(NSString *)releaseID group:(NSString *)groupID {
    if (!releaseID.length || [self hasCoverOverride]) return;
    NSString *expected = self.discID;
    NSString *url = [NSString stringWithFormat:@"https://coverartarchive.org/release/%@/front-1200",releaseID];
    [[[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:url] completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSImage *image = data ? [[NSImage alloc] initWithData:data] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![self.discID isEqualToString:expected] || [self hasCoverOverride]) return;
            if (image) { [self setCoverImage:image]; [self cacheAutomaticCoverData:data]; }
            else if (groupID.length) [self fetchPhysicalGroupCover:groupID expected:expected];
        });
    }] resume];
}

- (void)fetchPhysicalGroupCover:(NSString *)groupID expected:(NSString *)expected {
    NSString *url = [NSString stringWithFormat:@"https://coverartarchive.org/release-group/%@/front-1200",groupID];
    [[[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:url] completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSImage *image = data ? [[NSImage alloc] initWithData:data] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{ if (image && [self.discID isEqualToString:expected] && ![self hasCoverOverride]) { [self setCoverImage:image]; [self cacheAutomaticCoverData:data]; } });
    }] resume];
}

- (void)showSession {
    if (self.albumWallShown) [self closeAlbumWall:nil];
    [self crossfade:.5];
    [self applyTheme];
    [self.stage layoutSubtreeIfNeeded];
    [self.toast show:self.physical ? @"已载入实体 CD" : @"已载入" busy:NO];
#ifndef CDGLASS_SNAPSHOT
    if (!(self.window.styleMask & NSWindowStyleMaskFullScreen)) { self.wasFullscreen = YES; [self.window toggleFullScreen:nil]; }
#else
    // Tests stand in for that switch to full screen, which resizes the stage while the wall is still closing.
    NSArray *grow = [NSProcessInfo.processInfo.environment[@"CDGLASS_SIM_FULLSCREEN"] componentsSeparatedByString:@"x"];
    if (grow.count == 2) { NSRect f = self.window.frame; [self.window setFrame:NSMakeRect(f.origin.x, f.origin.y, [grow[0] doubleValue], [grow[1] doubleValue]) display:YES]; }
#endif
}

#pragma mark - Player jobs

/// Stopping or switching VLC waits for its reading thread, and that thread hangs for as long as the disk it reads
/// from does not answer. Those calls therefore go to the player's own queue; meanwhile the main thread leaves the
/// player alone (-playerBusy), and a player still stuck after CDPlayerPatience is given up for a fresh one.
- (BOOL)playerBusy { return self.playerJobsDone < self.playerJobsSent; }
- (void)playerJob:(void (^)(libvlc_media_player_t *player))job leaving:(NSString *)leaving then:(void (^)(void))then {
    libvlc_media_player_t *player = self.player;
    if (!player) return;
    NSUInteger number = ++self.playerJobsSent, generation = self.playerGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.playerQueue, ^{
        job(player);
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) app = weakSelf;
            if (!app || app.playerGeneration != generation) return;     // that player was given up meanwhile
            app.playerJobsDone = MAX(app.playerJobsDone, number);
            if (then) then();
        });
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(CDPlayerPatience * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) app = weakSelf;
        if (app && app.playerGeneration == generation && app.playerJobsDone < number) [app abandonPlayerStuckOn:leaving];
    });
}
- (void)stopPlayer {
    NSString *leaving = self.playerMediaPath;
    self.playerMediaPath = nil;
    [self playerJob:^(libvlc_media_player_t *player) { libvlc_media_player_stop(player); } leaving:leaving then:nil];
}
/// VLC's reading thread did not come back: the disk under `leaving` stopped answering. That player is left to its
/// thread (and released if it ever returns); a fresh one takes over, so everything else keeps working.
- (void)abandonPlayerStuckOn:(NSString *)leaving {
    libvlc_media_player_t *stuck = self.player;
    dispatch_queue_t queue = self.playerQueue;
    self.playerGeneration++;
    self.playerJobsSent = self.playerJobsDone = 0;
    self.playerQueue = dispatch_queue_create("local.cdglass.player", DISPATCH_QUEUE_SERIAL);
    self.player = self.vlc ? libvlc_media_player_new(self.vlc) : NULL;
    self.playerMediaPath = nil;
    if (stuck) dispatch_async(queue, ^{ libvlc_media_player_release(stuck); });
    NSString *root = CDVolumeRoot(leaving);
    if (root) CDVolumeMarkSilent(root);
    // What was asked for since goes to the new player; a track on that same disk brings up the connection error.
    if (self.trackCount && self.np.playing) [self playCurrent];
    else if (root && self.trackCount) { __weak typeof(self) weakSelf = self; [self showConnectionError:root retry:^{ [weakSelf playCurrent]; }]; }
}
/// Opening or playing, yet the position has not moved for a while: ask the track's disk (really reading from it,
/// past any cache). If it does not answer, the player is stuck on it and is replaced, and the connection error
/// comes up. (A track whose disk stopped answering before it began stays "opening" for good.)
- (void)watchForStall:(libvlc_state_t)state {
    BOOL underway = state == libvlc_Opening || state == libvlc_Buffering || state == libvlc_Playing;
    if (!underway || self.paused || self.physical || self.trackIndex >= (NSInteger)self.virtualTracks.count) { self.stallTicks = 0; return; }
    libvlc_time_t now = libvlc_media_player_get_time(self.player);
    if (now != self.stallTime) { self.stallTime = now; self.stallTicks = 0; return; }
    if (++self.stallTicks != 5) return;
    NSString *path = self.virtualTracks[self.trackIndex].path;
    if (!CDVolumeRoot(path)) return;
    NSUInteger generation = self.playerGeneration;
    __weak typeof(self) weakSelf = self;
    CDVolumeRead(path, CDDiskPatience, ^id{
        int fd = open(path.fileSystemRepresentation, O_RDONLY);
        if (fd < 0) return nil;
        fcntl(fd, F_NOCACHE, 1);
        struct stat info; char block[4096];
        BOOL read = fstat(fd, &info) == 0 && pread(fd, block, sizeof block, info.st_size > 8192 ? (off_t)(arc4random_uniform((uint32_t)MIN(info.st_size / 4096 - 1, UINT32_MAX - 1)) * 4096) : 0) >= 0;
        close(fd);
        return read ? @YES : nil;
    }, ^(id answered, NSString *silent) {
        typeof(self) app = weakSelf;
        if (app && silent && app.playerGeneration == generation) [app abandonPlayerStuckOn:path];
    });
}

- (void)playCurrent {
    if (!self.player || !self.trackCount) { [self.toast show:@"VLC 播放核心不可用" busy:NO]; return; }
    libvlc_media_t *media = NULL;
    if (self.physical) {
        NSInteger number = self.trackIndex < (NSInteger)self.physicalTrackNumbers.count ? [self.physicalTrackNumbers[self.trackIndex] integerValue] : self.trackIndex + 1;
        NSString *mrl = [NSString stringWithFormat:@"cdda://%@@%ld", self.discPath, (long)number];
        media = libvlc_media_new_location(self.vlc, mrl.UTF8String);
    } else if (self.trackIndex < (NSInteger)self.virtualTracks.count) {
        media = libvlc_media_new_path(self.vlc, self.virtualTracks[self.trackIndex].path.UTF8String);
        if (media && self.virtualStarts.count == self.trackCount) {
            double seconds = [self.virtualStarts[self.trackIndex] doubleValue] / 1000.0;
            if (seconds > 0) {
                NSString *option = [NSString stringWithFormat:@":start-time=%.3f", seconds];
                libvlc_media_add_option(media, option.UTF8String);
            }
        }
    }
    if (!media) return;
    // A track on a disk known not to answer is not handed to VLC at all.
    NSString *path = self.physical ? self.discPath : self.virtualTracks[self.trackIndex].path;
    __weak typeof(self) weakSelf = self;
    if (!self.physical && CDVolumeIsSilent(path)) {
        libvlc_media_release(media);
        self.paused = NO;
        [self setPlayingState:NO];
        [self refreshLabels];
        [self showConnectionError:CDVolumeRoot(path) retry:^{ [weakSelf playCurrent]; }];
        return;
    }
    // Switching waits for VLC to let go of the previous track, which never happens if that track's disk stopped
    // answering: so it happens on the player's own queue, and the page carries on at once.
    int volume = (int)self.np.volume;
    __block int result = 0;
    [self playerJob:^(libvlc_media_player_t *player) {
        libvlc_media_player_set_media(player, media);
        libvlc_media_release(media);
        result = libvlc_media_player_play(player);
        libvlc_audio_set_volume(player, volume);
    } leaving:self.playerMediaPath then:^{
        if (result != 0) { [weakSelf.toast show:@"无法读取此曲目，请检查 CD 或 VLC" busy:NO]; [weakSelf setPlayingState:NO]; }
    }];
    self.playerMediaPath = path;
    self.cueSeekPending = !self.physical && self.virtualStarts.count == self.trackCount && [self.virtualStarts[self.trackIndex] longLongValue] > 0;
    self.paused = NO;
    CDPlaybackClock clock; CDClockReset(&clock, self.virtualStarts.count == self.trackCount ? [self.virtualStarts[self.trackIndex] doubleValue] : 0, CACurrentMediaTime(), true); self.playbackClock = clock;
    [self setVolumeLevel:self.np.volume persist:NO];
    self.progress.doubleValue = 0;
    self.np.elapsedMS = 0; self.np.durationMS = 0; self.np.trackProgress = 0;
    self.np.albumProgress = self.trackIndex / (double)MAX(1, self.trackCount);
    self.stallTicks = 0;
    [self setPlayingState:YES];
    [self refreshLabels];
    [self.trackList scrollToCurrent:YES];
}

- (void)togglePlayback:(id)sender {
    if (!self.trackCount || !self.player) return;
    libvlc_state_t state = libvlc_media_player_get_state(self.player);    // safe even mid-switch: no input lock
    if (!self.playerBusy && (state == libvlc_Stopped || state == libvlc_Ended || state == libvlc_NothingSpecial)) { [self playCurrent]; return; }
    if (self.playerBusy) [self playerJob:^(libvlc_media_player_t *player) { libvlc_media_player_pause(player); } leaving:self.playerMediaPath then:nil];
    else libvlc_media_player_pause(self.player);
    self.paused = !self.paused;
    [self setPlayingState:!self.paused];
}
- (void)selectTrack:(NSInteger)row {
    if (row < 0 || row >= self.trackCount) return;
    if (row == self.trackIndex && self.np.playing) return;
    if (row == self.trackIndex && self.paused) { [self togglePlayback:nil]; return; }
    self.trackIndex = row;
    [self playCurrent];
}
- (void)previous:(id)sender { if (self.trackCount) { self.trackIndex = MAX(0, self.trackIndex - 1); [self playCurrent]; } }
- (void)next:(id)sender {
    if (!self.trackCount) return;
    if (self.trackIndex + 1 >= self.trackCount) {
        [self stopPlayer];
        self.paused = NO;
        [self setPlayingState:NO];
        return;
    }
    self.trackIndex++; [self playCurrent];
}

- (void)openVirtual:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = YES; panel.canChooseFiles = NO; panel.allowsMultipleSelection = NO;
    panel.message = @"选择音频文件夹。支持 CUE 曲目单、封面图片，也支持只有音频的文件夹。";
    if ([panel runModal] == NSModalResponseOK) [self loadVirtual:panel.URL];
}

#pragma mark - Anime CD library

- (BOOL)albumWallShown { return self.albumWall && !self.albumWall.hidden && !self.albumWallClosing; }
/// What the window shows right now (the player page), for the wall to shrink back into its CD. Our own window only.
- (CGImageRef)copyStageSnapshot CF_RETURNS_RETAINED {
    typedef CGImageRef (*Capture)(CGRect, uint32_t, uint32_t, uint32_t);
    static Capture capture;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ capture = (Capture)dlsym(RTLD_DEFAULT, "CGWindowListCreateImage"); });
    if (!capture || self.window.windowNumber <= 0) return NULL;
    // The stage fills the window (full-size content view), so the window's own bounds are the page.
    return capture(CGRectNull, 1 << 3 /* this window only */, (uint32_t)self.window.windowNumber, (1 << 0) | (1 << 3) /* no frame, full resolution */);
}
- (void)showAlbumWall:(id)sender {
    // The same button (and ⌘B) opens and closes the wall.
    if (self.albumWallShown) { [self closeAlbumWall:nil]; return; }
    // Coming back to the series this CD was picked from: take the page as it is now, before the wall covers it.
    NSString *returnKey = !self.physical && self.wallReturnStackKey && [self.virtualFolderPath isEqualToString:self.wallReturnPlaybackPath] ? self.wallReturnStackKey : nil;
    NSString *returnAlbum = returnKey ? self.wallReturnAlbumID : nil;
    self.wallReturnStackKey = self.wallReturnPlaybackPath = self.wallReturnAlbumID = nil;
    CGImageRef page = returnKey && !self.hero.hidden ? [self copyStageSnapshot] : NULL;
    if (!self.albumWall) {
        CDAlbumWall *wall = [[CDAlbumWall alloc] initWithFrame:self.stage.bounds];
        wall.hidden = YES;
        wall.grouped = [[NSUserDefaults standardUserDefaults] objectForKey:@"CDGlassWallGrouped"] ? [[NSUserDefaults standardUserDefaults] boolForKey:@"CDGlassWallGrouped"] : YES;
        self.albumWall = wall;
        __weak typeof(self) weakSelf = self;
        wall.onScan = ^{ [weakSelf scanLibraryFolder:nil]; };
        wall.onArchive = ^(NSArray<NSDictionary *> *albums) { [weakSelf archiveLibraryAlbums:albums]; };
        wall.onGroupedChange = ^(BOOL grouped) { [[NSUserDefaults standardUserDefaults] setBool:grouped forKey:@"CDGlassWallGrouped"]; };
        wall.onPlay = ^(NSDictionary *album) { [weakSelf playFromWall:album]; };
    }
    CDAlbumWall *wall = self.albumWall;
    // Above the player, below the corner buttons and the status line.
    [self.stage addSubview:wall positioned:NSWindowAbove relativeTo:nil];
    for (NSView *view in @[self.libraryEntryButton, self.gearButton, self.toast]) [self.stage addSubview:view positioned:NSWindowAbove relativeTo:nil];
    wall.frame = self.stage.bounds;
    [self configureWallBackdrop];
    wall.palette = self.palette;
    wall.playerStyle = self.styleIndex;
    wall.albums = self.library.albums;
    self.albumWallClosing = NO;
    self.libraryEntryButton.active = YES;
    [self setChromeHidden:NO animated:NO];
    BOOL returned = NO;
    if (returnKey.length) {
        // The page shrinks back into the CD it came from, where the player shows that CD's cover.
        NSRect object = self.hero.objectRect;
        CGFloat side = MIN(NSWidth(object), NSHeight(object));
        NSRect cover = [wall convertRect:NSMakeRect(NSMidX(object) - side / 2, NSMidY(object) - side / 2, side, side) fromView:self.hero];
        returned = [wall returnToStackWithKey:returnKey albumID:returnAlbum page:page cover:cover];
    }
    if (page) CGImageRelease(page);
    if (!returned) [wall presentAnimated:YES];
    // Nothing behind the wall needs to animate while it is up.
    NSUInteger token = ++self.albumWallToken;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.albumWallToken != token || !self.albumWallShown) return;
        self.hero.hidden = YES; self.backdrop.hidden = YES;
    });
    if (!self.libraryArtworkRefreshStarted && self.library.albums.count) {
        self.libraryArtworkRefreshStarted = YES;
        __weak typeof(self) weakSelf = self;
        [self.library refreshMissingArtwork:^(NSUInteger repaired) {
            weakSelf.albumWall.albums = weakSelf.library.albums;
            if (repaired) [weakSelf.toast show:[NSString stringWithFormat:@"已找回 %lu 张封面", (unsigned long)repaired] busy:NO];
            [weakSelf refreshLibrarySeriesArtwork];
        }];
    }
}
/// Off the main thread: the CD's folder, read from its archived copy when that is there, else from the original.
/// `silent` names a disk that did not answer; nil comes back when neither could be read.
- (NSDictionary *)readWallAlbum:(NSDictionary *)album silent:(NSString **)silent {
    NSString *archived = [album[@"libraryPath"] isKindOfClass:NSString.class] ? album[@"libraryPath"] : @"";
    NSString *source = [album[@"sourcePath"] isKindOfClass:NSString.class] ? album[@"sourcePath"] : @"";
    for (NSString *path in @[archived, source]) {
        if (!path.length) continue;
        BOOL answered = YES;
        NSDictionary *read = CDVolumeRun(path, CDDiskPatience, ^id{
            NSURL *url = [NSURL fileURLWithPath:path isDirectory:YES];
            if (![NSFileManager.defaultManager fileExistsAtPath:path]) return @{};
            return @{@"url": url, @"contents": [self readVirtualFolder:url]};
        }, &answered);
        if (!answered) { *silent = CDVolumeRoot(path) ?: path; continue; }
        if (read[@"contents"]) return read;
    }
    return nil;
}
/// A CD picked on the wall: read in the background (a disk that stopped answering must not freeze anything), then
/// the card lands where the player shows the cover — or, when the disk does not answer, it settles back and a
/// connection error offers 重试.
- (void)playFromWall:(NSDictionary *)album {
    NSUInteger token = ++self.loadToken;
    NSString *returnKey = self.albumWall.expandedStackKey;
    [self noteSlowDiskFor:[album[@"sourcePath"] isKindOfClass:NSString.class] ? album[@"sourcePath"] : nil token:token];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *silent = nil;
        NSDictionary *read = [weakSelf readWallAlbum:album silent:&silent];
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) app = weakSelf;
            if (!app || app.loadToken != token) return;
            app.loadToken++;
            if (!read) {
                [app.toast hide];
                [app.albumWall cancelLaunch];
                if (silent) [app showConnectionError:silent retry:^{ [weakSelf playFromWall:album]; }];
                else [app.toast show:@"找不到这张 CD 的文件夹（可能已被移动或删除）" busy:NO];
                return;
            }
            NSURL *url = read[@"url"];
            if (![app applyVirtualFolder:url contents:read[@"contents"]]) { [app.albumWall cancelLaunch]; return; }
            app.wallReturnStackKey = returnKey;
            app.wallReturnPlaybackPath = returnKey ? url.URLByStandardizingPath.path : nil;
            app.wallReturnAlbumID = returnKey && [album[@"id"] isKindOfClass:NSString.class] ? album[@"id"] : nil;
            [app.stage layoutSubtreeIfNeeded];
            NSRect object = app.hero.objectRect;
            CGFloat side = MIN(NSWidth(object), NSHeight(object));
            NSRect cover = NSMakeRect(NSMidX(object) - side / 2, NSMidY(object) - side / 2, side, side);
            [app.albumWall landLaunchIn:[app.albumWall convertRect:cover fromView:app.hero]];
            [app closeAlbumWall:nil];
        });
    });
}
/// A disk that is not connected, or stopped answering: say which, and offer to try again.
- (void)showConnectionError:(NSString *)root retry:(void (^)(void))retry {
    if (self.connectionAlert) return;       // one at a time; a second failure while it is up says the same
    BOOL mounted = CDVolumeMounted(root);
    NSAlert *alert = [NSAlert new];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = [NSString stringWithFormat:mounted ? @"连接不上「%@」" : @"「%@」未连接", CDVolumeName(root)];
    alert.informativeText = mounted ? @"这块硬盘没有响应，USB 或网络（SSH / SMB）连接可能已经中断。恢复连接后点「重试」。"
                                    : @"这张 CD 所在的硬盘现在没有接上。接好或重新挂载后点「重试」。";
    [alert addButtonWithTitle:@"重试"];
    [alert addButtonWithTitle:@"取消"];
    self.connectionAlert = alert;
    self.menuOpen = YES;
    __weak typeof(self) weakSelf = self;
    void (^answer)(NSModalResponse) = ^(NSModalResponse response) {
        weakSelf.connectionAlert = nil;
        weakSelf.menuOpen = NO;
        if (response != NSAlertFirstButtonReturn) return;
        CDVolumeRetry(root);
        if (retry) retry();
    };
    if (self.window.visible) [alert beginSheetModalForWindow:self.window completionHandler:answer];
    else answer([alert runModal]);
}
- (void)configureWallBackdrop {
    if (!self.albumWall) return;
    CDBackdropView *backdrop = self.albumWall.backdrop;
    backdrop.mode = self.backgroundMode;
    backdrop.blurLevel = self.blurLevel;
    backdrop.particles = self.particles;
    [backdrop applyPalette:self.palette];
    [backdrop setCoverImage:self.backdropCover];
}
- (void)refreshLibrarySeriesArtwork {
    __weak typeof(self) weakSelf = self;
    [self.library resolveSeriesArtwork:^(NSUInteger done, NSUInteger total) {
        [weakSelf.toast show:[NSString stringWithFormat:@"补充番剧主视觉 · %lu / %lu", (unsigned long)done, (unsigned long)total] busy:YES];
    } completion:^(NSUInteger repaired) {
        weakSelf.albumWall.albums = weakSelf.library.albums;
        if (repaired) [weakSelf.toast show:[NSString stringWithFormat:@"已为 %lu 张唱片补上番剧主视觉", (unsigned long)repaired] busy:NO];
        else [weakSelf.toast hide];
    }];
}
- (void)closeAlbumWall:(id)sender {
    if (!self.albumWallShown) return;
    self.albumWallClosing = YES;
    self.albumWallToken++;
    self.hero.hidden = NO; self.backdrop.hidden = NO;
    self.libraryEntryButton.active = NO;
    __weak typeof(self) weakSelf = self;
    [self.albumWall dismissAnimated:YES completion:^{ weakSelf.albumWallClosing = NO; }];
}
- (void)scanLibraryFolder:(id)sender {
    [self showAlbumWall:nil];
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = YES; panel.canChooseFiles = NO; panel.allowsMultipleSelection = NO;
    panel.message = @"选择一个目录；其中任意深度的音乐 CD 文件夹都会加入专辑墙。扫描不会移动或复制原文件。";
    if ([panel runModal] != NSModalResponseOK) return;
    [self scanLibraryAt:panel.URL];
}
- (void)scanLibraryAt:(NSURL *)folder {
    [self.toast show:@"正在递归扫描…" busy:YES];
    __weak typeof(self) weakSelf = self;
    [self.library scanFolder:folder progress:^(NSUInteger found) {
        [weakSelf.toast show:[NSString stringWithFormat:@"已发现 %lu 张 CD…", (unsigned long)found] busy:YES];
    } completion:^(NSUInteger added, NSError *error) {
        if (error.code == 2 && error.userInfo[@"CDVolumeRoot"]) {
            [weakSelf.toast hide];
            [weakSelf showConnectionError:error.userInfo[@"CDVolumeRoot"] retry:^{ [weakSelf scanLibraryAt:folder]; }];
            return;
        }
        weakSelf.albumWall.albums = weakSelf.library.albums;
        NSString *status = error ? error.localizedDescription : [NSString stringWithFormat:@"扫描完成 · 新增 %lu 张 CD · 共 %lu 张", (unsigned long)added, (unsigned long)weakSelf.library.albums.count];
        [weakSelf.toast show:status busy:NO];
        if (!error) [weakSelf.library resolveUnmatchedOnline:^(NSUInteger done, NSUInteger total) {
            [weakSelf.toast show:[NSString stringWithFormat:@"正在联网核对番剧 · %lu / %lu", (unsigned long)done, (unsigned long)total] busy:YES];
        } completion:^(NSUInteger recognized) {
            weakSelf.albumWall.albums = weakSelf.library.albums;
            [weakSelf refreshLibrarySeriesArtwork];
            if (recognized) [weakSelf.toast show:[status stringByAppendingFormat:@" · 联网识别 %lu 张", (unsigned long)recognized] busy:NO];
            else [weakSelf.toast show:status busy:NO];
        }];
    }];
}
- (void)archiveLibraryAlbums:(NSArray<NSDictionary *> *)albums {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = YES; panel.canChooseFiles = NO; panel.allowsMultipleSelection = NO;
    panel.prompt = @"归档到这里";
    panel.message = @"选择 CD 归档文件夹。唱片会按番剧分类复制到这里，原文件留在原处。";
    NSString *previous = [NSUserDefaults.standardUserDefaults stringForKey:@"CDGlassArchiveFolder"];
    // Not checked for existence here: that folder may be on a disk that does not answer. The panel copes.
    if (previous.length && !CDVolumeIsSilent(previous)) panel.directoryURL = [NSURL fileURLWithPath:previous isDirectory:YES];
    if ([panel runModal] != NSModalResponseOK) return;
    NSURL *destination = panel.URL.URLByStandardizingPath;
    [NSUserDefaults.standardUserDefaults setObject:destination.path forKey:@"CDGlassArchiveFolder"];
    [self.toast show:[NSString stringWithFormat:@"准备复制 %lu 张 CD…", (unsigned long)albums.count] busy:YES];
    __weak typeof(self) weakSelf = self;
    [self.library archiveAlbums:albums toFolder:destination progress:^(NSUInteger done, NSUInteger total) {
        [weakSelf.toast show:[NSString stringWithFormat:@"正在复制到 %@ · %lu / %lu", destination.path, (unsigned long)done, (unsigned long)total] busy:YES];
    } completion:^(NSUInteger copied, NSArray<NSString *> *errors) {
        weakSelf.albumWall.albums = weakSelf.library.albums;
        NSString *status = [NSString stringWithFormat:@"已归档 %lu 张 CD 到 %@", (unsigned long)copied, destination.path];
        if (errors.count) status = [status stringByAppendingFormat:@" · %lu 张未复制：%@", (unsigned long)errors.count, errors.firstObject];
        [weakSelf.toast show:status busy:NO];
    }];
}
- (void)playDemo:(id)sender { NSURL *url = [[NSBundle mainBundle] URLForResource:@"Demo CD" withExtension:nil]; if (url) [self loadVirtual:url]; }

- (NSString *)coverStoreDirectory {
    NSString *base = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,NSUserDomainMask,YES).firstObject stringByAppendingPathComponent:@"CD Glass/Covers"];
#ifdef CDGLASS_SNAPSHOT
    if (NSProcessInfo.processInfo.environment[@"CDGLASS_STORE"]) base = NSProcessInfo.processInfo.environment[@"CDGLASS_STORE"];
#endif
    [[NSFileManager defaultManager] createDirectoryAtPath:base withIntermediateDirectories:YES attributes:nil error:nil];
    return base;
}
- (NSString *)fingerprintForTracks:(NSArray<NSURL *> *)tracks starts:(NSArray<NSNumber *> *)starts sizes:(NSDictionary<NSString *, NSNumber *> *)sizes {
    NSMutableString *structure = [NSMutableString stringWithFormat:@"%lu|",(unsigned long)tracks.count];
    for (NSUInteger i=0; i<tracks.count; i++) {
        NSURL *file = tracks[i];
        [structure appendFormat:@"%@:%lld:%lld|",file.lastPathComponent, [sizes[file.path] longLongValue], i < starts.count ? [starts[i] longLongValue] : 0];
        if (i < self.trackNames.count) [structure appendFormat:@"%@|",self.trackNames[i]];
    }
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(structure.UTF8String,(CC_LONG)strlen(structure.UTF8String),hash);
    NSMutableString *key = [NSMutableString stringWithString:@"virtual-"];
    for (NSUInteger i=0;i<CC_SHA256_DIGEST_LENGTH;i++) [key appendFormat:@"%02x",hash[i]];
    return key;
}
- (NSDictionary *)coverRecords { return [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"CDGlassCoverRecords"] ?: @{}; }
- (NSDictionary *)coverRecord { return self.discFingerprint.length ? [self coverRecords][self.discFingerprint] : nil; }
- (BOOL)hasCoverOverride { return [[self coverRecord][@"manual"] isKindOfClass:NSString.class]; }
/// A cover kept from an earlier search, or one picked by hand.
- (BOOL)hasStoredCover {
    NSDictionary *record = [self coverRecord];
    NSString *name = record[@"manual"] ?: record[@"automatic"];
    return [name isKindOfClass:NSString.class] && name.length && [[NSFileManager defaultManager] fileExistsAtPath:[[self coverStoreDirectory] stringByAppendingPathComponent:name]];
}
/// Covers are looked up online only for an album that has none yet: no picture in its folder or its FLAC files,
/// nothing stored from an earlier search and nothing chosen by hand. One searched without success is tried again
/// after a few days. "重新搜索" in the candidate panel always searches.
- (BOOL)needsCoverSearch {
    if (self.hasLocalCover || [self hasStoredCover]) return NO;
    NSDictionary *record = [self coverRecord];
    NSDate *last = record[@"searchedAt"];
    BOOL recent = [last isKindOfClass:NSDate.class] && -last.timeIntervalSinceNow < 3 * 24 * 3600;
    return !(recent && [record[@"searchVersion"] integerValue] == 63);
}
- (void)writeCoverRecord:(NSDictionary *)record {
    if (!self.discFingerprint.length) return;
    NSMutableDictionary *all = [[self coverRecords] mutableCopy];
    all[self.discFingerprint] = record;
    [[NSUserDefaults standardUserDefaults] setObject:all forKey:@"CDGlassCoverRecords"];
}
- (BOOL)applyStoredCover {
    NSDictionary *record = [self coverRecord];
    NSString *name = record[@"manual"] ?: record[@"automatic"];
    if (!name.length) return NO;
    NSString *path = [[self coverStoreDirectory] stringByAppendingPathComponent:name];
    NSImage *image = [[NSImage alloc] initWithContentsOfFile:path];
    if (!image) return NO;
    [self setCoverImage:image];
    [self markCurrentCandidate:record[@"manual"] ? (record[@"selectedCandidate"] ?: record[@"current"]) : record[@"autoCandidate"]];
    return YES;
}
- (void)cacheAutomaticCoverData:(NSData *)data {
    if (!self.discFingerprint.length || !data.length || [self hasCoverOverride]) return;
    NSString *name = [self.discFingerprint stringByAppendingString:@"-auto.jpg"];
    if (![data writeToFile:[[self coverStoreDirectory] stringByAppendingPathComponent:name] atomically:YES]) return;
    NSMutableDictionary *record = [[self coverRecord] mutableCopy] ?: [NSMutableDictionary new];
    record[@"automatic"] = name;
    record[@"album"] = self.albumTitle ?: @"";
    record[@"tracks"] = self.trackNames ?: @[];
    [self writeCoverRecord:record];
    [self rememberLibraryCoverAtPath:[[self coverStoreDirectory] stringByAppendingPathComponent:name]];
}

- (void)rememberLibraryCoverAtPath:(NSString *)path {
    if (!self.virtualFolderPath.length || !path.length) return;
    __weak typeof(self) weakSelf = self;
    [self.library rememberArtworkAtPath:path forFolder:self.virtualFolderPath completion:^{
        if (weakSelf.albumWall && !weakSelf.albumWall.hidden) weakSelf.albumWall.albums = weakSelf.library.albums;
    }];
}

- (void)markCurrentCandidate:(NSString *)candidateID {
    NSMutableDictionary *record = [[self coverRecord] mutableCopy];
    if (!record) return;
    if (candidateID.length) record[@"current"] = candidateID; else [record removeObjectForKey:@"current"];
    [self writeCoverRecord:record];
}
- (void)chooseCover:(id)sender {
    if (!self.discFingerprint.length) return;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = NO; panel.canChooseFiles = YES;
    panel.message = @"选择此张 CD 的正确封面；之后再次载入同一 CD 会自动使用它。也可以直接把图片拖进窗口。";
    if ([panel runModal] != NSModalResponseOK) return;
    [self applyManualCoverFromURL:panel.URL];
}
- (void)applyManualCoverFromURL:(NSURL *)url {
    if (!self.discFingerprint.length) return;
    NSImage *image = [[NSImage alloc] initWithContentsOfURL:url];
    if (!image) { [self.toast show:@"无法读取所选图片" busy:NO]; return; }
    NSString *name = [NSString stringWithFormat:@"%@-manual.%@", self.discFingerprint, url.pathExtension.lowercaseString ?: @"png"];
    NSString *path = [[self coverStoreDirectory] stringByAppendingPathComponent:name];
    BOOL copied = [[NSFileManager defaultManager] copyItemAtPath:url.path toPath:path error:nil];
    if (!copied) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        copied = [[NSFileManager defaultManager] copyItemAtPath:url.path toPath:path error:nil];
    }
    if (!copied) { [self.toast show:@"无法保存所选封面" busy:NO]; return; }
    NSMutableDictionary *record = [[self coverRecord] mutableCopy] ?: [NSMutableDictionary new];
    record[@"manual"] = name; record[@"album"] = self.albumTitle ?: @""; record[@"tracks"] = self.trackNames ?: @[];
    [self writeCoverRecord:record];
    self.coverLookupToken++;
    [self setCoverImage:image];
    NSString *key = [self rememberCurrentCover];
    if (key) {
        NSMutableDictionary *updated = [[self coverRecord] mutableCopy];
        updated[@"selectedCandidate"] = key; updated[@"current"] = key;
        [self writeCoverRecord:updated];
    }
    [self rememberLibraryCoverAtPath:path];
    [self.toast show:@"已保存自选封面" busy:NO];
    [self refreshCandidatePanel];
}
- (void)resetCover:(id)sender {
    NSMutableDictionary *record = [[self coverRecord] mutableCopy];
    if (record[@"manual"]) { [record removeObjectForKey:@"manual"]; [record removeObjectForKey:@"current"]; [self writeCoverRecord:record]; }
    if (![self applyStoredCover]) [self setCoverImage:nil];
    [self findOnlineCover:nil];
}

- (NSString *)cueValue:(NSString *)line {
    NSRange first = [line rangeOfString:@"\""];
    if (first.location != NSNotFound) {
        NSRange tail = [line rangeOfString:@"\"" options:NSBackwardsSearch];
        if (tail.location > first.location) return [line substringWithRange:NSMakeRange(first.location+1,tail.location-first.location-1)];
    }
    NSRange space = [line rangeOfString:@" "];
    return space.location == NSNotFound ? @"" : [[line substringFromIndex:space.location+1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
}

- (NSArray<NSDictionary *> *)cueEntriesFromFiles:(NSArray<NSURL *> *)files title:(NSString **)albumTitle artist:(NSString **)albumArtist artwork:(NSString **)artwork {
    NSURL *cue = nil;
    for (NSURL *file in files) if ([file.pathExtension.lowercaseString isEqualToString:@"cue"]) { cue = file; break; }
    if (!cue) return nil;
    NSData *data = [NSData dataWithContentsOfURL:cue];
    NSString *content = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!content) content = [[NSString alloc] initWithData:data encoding:NSShiftJISStringEncoding];
    if (!content) return nil;
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray new];
    NSURL *currentFile = nil;
    NSMutableDictionary *currentTrack = nil;
    for (NSString *raw in [content componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *upper = line.uppercaseString;
        if ([upper hasPrefix:@"REM COVER "] || [upper hasPrefix:@"REM COVERFILE "]) {
            NSString *art = [[self cueValue:[line substringFromIndex:4]] stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
            if (artwork) *artwork = art.lastPathComponent;
        } else if ([upper hasPrefix:@"FILE "]) {
            NSString *wanted = [[[self cueValue:line] stringByReplacingOccurrencesOfString:@"\\" withString:@"/"] lastPathComponent];
            currentFile = nil;
            for (NSURL *file in files) if ([file.lastPathComponent caseInsensitiveCompare:wanted] == NSOrderedSame) { currentFile = file; break; }
        } else if ([upper hasPrefix:@"TRACK "]) {
            if (![upper hasSuffix:@" AUDIO"]) { currentTrack = nil; continue; }
            currentTrack = [NSMutableDictionary new];
            if (currentFile) currentTrack[@"file"] = currentFile;
            [entries addObject:currentTrack];
        } else if ([upper hasPrefix:@"TITLE "]) {
            NSString *value = [self cueValue:line];
            if (currentTrack) currentTrack[@"title"] = value;
            else if (albumTitle) *albumTitle = value;
        } else if ([upper hasPrefix:@"PERFORMER "] && !currentTrack && albumArtist) {
            *albumArtist = [self cueValue:line];
        } else if ([upper hasPrefix:@"INDEX 01 "] && currentTrack) {
            int minute = 0, second = 0, frame = 0;
            if (sscanf(line.UTF8String,"INDEX 01 %d:%d:%d",&minute,&second,&frame) == 3 && second < 60 && frame < 75)
                currentTrack[@"start"] = @(((minute*60+second)*1000)+(frame*1000/75));
        }
    }
    NSMutableArray<NSDictionary *> *valid = [NSMutableArray new];
    for (NSDictionary *entry in entries) if (entry[@"file"] && entry[@"start"]) [valid addObject:entry];
    return valid.count ? valid : nil;
}

- (NSImage *)embeddedFLACCover:(NSURL *)url {
    NSData *file = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:nil];
    const unsigned char *bytes = file.bytes;
    if (file.length < 8 || memcmp(bytes,"fLaC",4) != 0) return nil;
    NSUInteger offset = 4;
    while (offset + 4 <= file.length) {
        BOOL last = (bytes[offset] & 0x80) != 0;
        NSUInteger type = bytes[offset] & 0x7f;
        NSUInteger length = ((NSUInteger)bytes[offset+1]<<16)|((NSUInteger)bytes[offset+2]<<8)|bytes[offset+3];
        offset += 4;
        if (length > file.length-offset) break;
        if (type == 6 && length >= 32) {
            const unsigned char *block = bytes+offset;
            NSUInteger p = 0;
            #define FLAC_U32_AT(pos) (((uint32_t)block[pos]<<24)|((uint32_t)block[(pos)+1]<<16)|((uint32_t)block[(pos)+2]<<8)|block[(pos)+3])
            p += 4; // picture type
            if (p+4 > length) break;
            NSUInteger mime = FLAC_U32_AT(p); p+=4;
            if (mime > length-p) break; p+=mime;
            if (p+4 > length) break;
            NSUInteger description = FLAC_U32_AT(p); p+=4;
            if (description > length-p) break; p+=description;
            if (p+20 > length) break;
            p += 16; // width, height, color depth, palette count
            NSUInteger imageLength = FLAC_U32_AT(p); p+=4;
            if (imageLength <= length-p) {
                NSImage *image = [[NSImage alloc] initWithData:[NSData dataWithBytes:block+p length:imageLength]];
                if (image) return image;
            }
            #undef FLAC_U32_AT
        }
        offset += length;
        if (last) break;
    }
    return nil;
}

/// Everything a CD folder holds that loading it needs, read in one go off the main thread: the disk it is on may be
/// slow to wake, or gone. Keys: files, audio, cue (entries), cueTitle, cueArtist, cueArtwork, json, sizes, cover.
- (NSDictionary *)readVirtualFolder:(NSURL *)folder {
    NSMutableDictionary *read = [NSMutableDictionary new];
    NSArray<NSURL *> *files = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:folder includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] ?: @[];
    NSSet *exts = [NSSet setWithArray:@[@"wav",@"aiff",@"aif",@"mp3",@"m4a",@"flac",@"ogg"]];
    NSMutableArray *audio = [NSMutableArray new];
    for (NSURL *file in files) if ([exts containsObject:file.pathExtension.lowercaseString]) [audio addObject:file];
    [audio sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) { return [a.lastPathComponent localizedStandardCompare:b.lastPathComponent]; }];
    read[@"files"] = files; read[@"audio"] = audio;
    if (!audio.count) return read;
    NSString *cueTitle = nil, *cueArtist = nil, *cueArtwork = nil;
    NSArray<NSDictionary *> *cueEntries = [self cueEntriesFromFiles:files title:&cueTitle artist:&cueArtist artwork:&cueArtwork];
    if (cueEntries.count) read[@"cue"] = cueEntries;
    if (cueTitle) read[@"cueTitle"] = cueTitle;
    if (cueArtist) read[@"cueArtist"] = cueArtist;
    if (cueArtwork) read[@"cueArtwork"] = cueArtwork;
    NSData *jsonData = [NSData dataWithContentsOfURL:[folder URLByAppendingPathComponent:@"album.json"]];
    NSDictionary *json = jsonData ? [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil] : nil;
    if ([json isKindOfClass:NSDictionary.class]) read[@"json"] = json;
    // File sizes go into the disc fingerprint.
    NSMutableDictionary *sizes = [NSMutableDictionary new];
    for (NSURL *file in cueEntries.count ? [cueEntries valueForKey:@"file"] : audio) {
        NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:file.path error:nil];
        sizes[file.path] = attributes[NSFileSize] ?: @0;
    }
    read[@"sizes"] = sizes;
    NSSet *imageExts = [NSSet setWithArray:@[@"jpg",@"jpeg",@"png",@"webp",@"heic"]];
    NSArray *preferred = @[@"cover",@"folder",@"front",@"album",@"artwork"];
    NSMutableArray<NSURL *> *images = [NSMutableArray new];
    for (NSURL *file in files) if ([imageExts containsObject:file.pathExtension.lowercaseString]) [images addObject:file];
    for (NSURL *child in files) {
        NSNumber *directory = nil; [child getResourceValue:&directory forKey:NSURLIsDirectoryKey error:nil];
        if (!directory.boolValue) continue;
        NSArray<NSURL *> *nested = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:child includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
        for (NSURL *file in nested) {
            NSString *stem = file.lastPathComponent.stringByDeletingPathExtension.lowercaseString;
            if ([imageExts containsObject:file.pathExtension.lowercaseString] && ([preferred containsObject:stem] || (cueArtwork.length && [file.lastPathComponent caseInsensitiveCompare:cueArtwork] == NSOrderedSame))) [images addObject:file];
        }
    }
    [images sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        NSString *an = a.lastPathComponent.stringByDeletingPathExtension.lowercaseString;
        NSString *bn = b.lastPathComponent.stringByDeletingPathExtension.lowercaseString;
        NSUInteger ai = [preferred indexOfObject:an], bi = [preferred indexOfObject:bn];
        if (ai == NSNotFound) ai = preferred.count;
        if (bi == NSNotFound) bi = preferred.count;
        BOOL aCue = cueArtwork.length && [a.lastPathComponent caseInsensitiveCompare:cueArtwork] == NSOrderedSame;
        BOOL bCue = cueArtwork.length && [b.lastPathComponent caseInsensitiveCompare:cueArtwork] == NSOrderedSame;
        if (aCue != bCue) return aCue ? NSOrderedAscending : NSOrderedDescending;
        return ai == bi ? [a.lastPathComponent localizedStandardCompare:b.lastPathComponent] : (ai < bi ? NSOrderedAscending : NSOrderedDescending);
    }];
    for (NSURL *file in images) {
        NSImage *image = [[NSImage alloc] initWithContentsOfURL:file];
        if (image) { read[@"cover"] = image; break; }
    }
    if (!read[@"cover"]) for (NSURL *file in audio) {
        if (![file.pathExtension.lowercaseString isEqualToString:@"flac"]) continue;
        NSImage *image = [self embeddedFLACCover:file];
        if (image) { read[@"cover"] = image; break; }
    }
    return read;
}

- (void)loadVirtual:(NSURL *)folder { [self loadVirtual:folder completion:nil]; }
/// Loads a CD folder. It is read off the main thread with a time limit, so a disk that stopped answering brings up
/// a connection error with 重试 instead of freezing the app. `completion` says whether the CD is now loaded.
- (void)loadVirtual:(NSURL *)folder completion:(void (^)(BOOL loaded))completion {
    NSUInteger token = ++self.loadToken;
    [self noteSlowDiskFor:folder.path token:token];
    __weak typeof(self) weakSelf = self;
    CDVolumeRead(folder.path, CDDiskPatience, ^id{ return [weakSelf readVirtualFolder:folder]; }, ^(NSDictionary *contents, NSString *silent) {
        typeof(self) app = weakSelf;
        if (!app || app.loadToken != token) { if (completion) completion(NO); return; }
        app.loadToken++;
        if (silent) {
            [app.toast hide];
            [app showConnectionError:silent retry:^{ [weakSelf loadVirtual:folder completion:completion]; }];
            if (completion) completion(NO);
            return;
        }
        BOOL loaded = [app applyVirtualFolder:folder contents:contents];
        if (completion) completion(loaded);
    });
}
/// A sleeping drive takes a moment to spin up: say so if reading takes longer than a blink.
- (void)noteSlowDiskFor:(NSString *)path token:(NSUInteger)token {
    NSString *root = CDVolumeRoot(path);
    if (!root) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.loadToken == token) [self.toast show:[NSString stringWithFormat:@"正在读取「%@」…", CDVolumeName(root)] busy:YES];
    });
}
/// Puts a read CD folder into the player (main thread; nothing here touches the disk).
- (BOOL)applyVirtualFolder:(NSURL *)folder contents:(NSDictionary *)read {
    NSArray<NSURL *> *files = read[@"files"] ?: @[];
    NSArray<NSURL *> *audio = read[@"audio"] ?: @[];
    if (!audio.count) { [self.toast hide]; NSAlert *alert = [NSAlert new]; alert.messageText = @"没有找到音频文件"; alert.informativeText = @"请放入 WAV、AIFF、MP3、M4A、FLAC 或 OGG 文件。"; [alert runModal]; return NO; }
    NSSet *exts = [NSSet setWithArray:@[@"wav",@"aiff",@"aif",@"mp3",@"m4a",@"flac",@"ogg"]];
    self.replacingSession = YES;
    [self endSession:nil];
    self.replacingSession = NO;
    self.cueArtworkName = read[@"cueArtwork"];
    NSString *cueTitle = read[@"cueTitle"], *cueArtist = read[@"cueArtist"];
    NSArray<NSDictionary *> *cueEntries = read[@"cue"];
    self.hasCue = cueEntries.count > 0;
    self.virtualFolderPath = folder.path;
    self.trackIndex = 0; self.physical = NO;
    if (cueEntries.count) {
        NSMutableArray *tracks = [NSMutableArray new], *names = [NSMutableArray new], *starts = [NSMutableArray new], *ends = [NSMutableArray new];
        for (NSUInteger i = 0; i < cueEntries.count; i++) {
            NSDictionary *entry = cueEntries[i];
            [tracks addObject:entry[@"file"]];
            [names addObject:entry[@"title"] ?: [NSString stringWithFormat:@"曲目 %02lu",(unsigned long)i+1]];
            [starts addObject:entry[@"start"]];
            NSDictionary *next = i+1 < cueEntries.count ? cueEntries[i+1] : nil;
            [ends addObject:next && [entry[@"file"] isEqual:next[@"file"]] ? next[@"start"] : @0];
        }
        self.virtualTracks = tracks; self.trackNames = names; self.virtualStarts = starts; self.virtualEnds = ends;
    } else {
        self.virtualTracks = audio;
        NSMutableArray *names = [NSMutableArray new];
        NSRegularExpression *numberPrefix = [NSRegularExpression regularExpressionWithPattern:@"^\\s*\\d{1,3}\\s*[-._ ]\\s*" options:0 error:nil];
        for (NSURL *file in audio) {
            NSString *stem = file.lastPathComponent.stringByDeletingPathExtension;
            NSString *clean = [numberPrefix stringByReplacingMatchesInString:stem options:0 range:NSMakeRange(0,stem.length) withTemplate:@""];
            [names addObject:clean.length ? clean : stem];
        }
        self.trackNames = names; self.virtualStarts = nil; self.virtualEnds = nil;
    }
    self.trackCount = self.virtualTracks.count;
    NSDictionary *json = read[@"json"];
    self.albumTitle = [json[@"title"] isKindOfClass:NSString.class] ? json[@"title"] : (cueTitle ?: folder.lastPathComponent);
    self.albumArtist = [json[@"artist"] isKindOfClass:NSString.class] ? json[@"artist"] : (cueArtist ?: @"虚拟 CD");
    if ([json[@"tracks"] isKindOfClass:NSArray.class] && [json[@"tracks"] count] == self.trackCount) self.trackNames = json[@"tracks"];
    self.discFingerprint = [self fingerprintForTracks:self.virtualTracks starts:self.virtualStarts sizes:read[@"sizes"]];
    NSRegularExpression *catalogPattern = [NSRegularExpression regularExpressionWithPattern:@"[A-Za-z]{2,8}[-_ ]?\\d{3,6}" options:0 error:nil];
    for (NSURL *file in files) {
        if (![file.pathExtension.lowercaseString isEqualToString:@"cue"] && ![exts containsObject:file.pathExtension.lowercaseString]) continue;
        NSString *stem = file.lastPathComponent.stringByDeletingPathExtension;
        NSTextCheckingResult *match = [catalogPattern firstMatchInString:stem options:0 range:NSMakeRange(0,stem.length)];
        if (match) { self.virtualCatalogNumber = [stem substringWithRange:match.range]; break; }
    }
    [self setCoverImage:nil];
    if (read[@"cover"]) { [self setCoverImage:read[@"cover"]]; self.hasLocalCover = YES; }
    [self rememberCurrentCover];
    [self applyStoredCover];
    [self showSession]; [self playCurrent];
    if ([self needsCoverSearch]) [self lookupVirtualCover];
    return YES;
}

- (void)findOnlineCover:(id)sender {
    if (self.physical && (!self.albumTitle.length || [self.albumTitle isEqualToString:@"音频 CD"])) [self lookupMetadata];
    else [self lookupCandidateCovers];
}
- (NSString *)onlineAlbumKey {
    NSString *title = self.albumTitle ?: @"";
    NSRange colon = [title rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@":："] options:NSBackwardsSearch];
    if (colon.location != NSNotFound && colon.location + 1 < title.length) title = [title substringFromIndex:colon.location + 1];
    NSRegularExpression *noise = [NSRegularExpression regularExpressionWithPattern:@"\\[[^\\]]*\\]|\\((?:flac|wav|mp3)[^)]*\\)" options:NSRegularExpressionCaseInsensitive error:nil];
    return [[noise stringByReplacingMatchesInString:title options:0 range:NSMakeRange(0, title.length) withTemplate:@""] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}
- (void)lookupVirtualCover { [self lookupCandidateCovers]; }
- (NSString *)rememberCurrentCover {
    if (!self.sourceCover || !self.discFingerprint.length) return nil;
    NSData *data = self.sourceCover.TIFFRepresentation; if (!data) return nil;
    unsigned char hash[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(data.bytes, (CC_LONG)data.length, hash);
    NSMutableString *key = [NSMutableString new]; for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [key appendFormat:@"%02x", hash[i]];
    [self saveCandidate:@{@"id": key, @"title": self.albumTitle ?: @"当前封面", @"source": self.hasLocalCover ? @"本地图片" : @"已保存封面", @"score": @0, @"reason": @"保留的原始封面", @"page": @"", @"width": @(self.sourceCover.size.width), @"height": @(self.sourceCover.size.height)} data:data];
    [self markCurrentCandidate:key];
    return key;
}
- (NSString *)saveCandidate:(NSDictionary *)candidate data:(NSData *)data {
    if (!self.discFingerprint.length || !data.length) return nil;
    NSString *name = [NSString stringWithFormat:@"candidate-%@.img", candidate[@"id"]];
    NSString *path = [[self coverStoreDirectory] stringByAppendingPathComponent:name];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path] && ![data writeToFile:path atomically:YES]) return nil;
    NSMutableDictionary *record = [[self coverRecord] mutableCopy] ?: [NSMutableDictionary new];
    NSMutableArray *candidates = [record[@"candidates"] mutableCopy] ?: [NSMutableArray new];
    NSMutableDictionary *item = [candidate mutableCopy]; item[@"file"] = name;
    NSUInteger index = [candidates indexOfObjectPassingTest:^BOOL(NSDictionary *v, NSUInteger i, BOOL *stop) { return [v[@"id"] isEqual:candidate[@"id"]]; }];
    if (index != NSNotFound) { if ([candidates[index][@"score"] integerValue] < [item[@"score"] integerValue]) candidates[index] = item; }
    else if (candidates.count < 48) [candidates addObject:item];
    record[@"candidates"] = candidates; [self writeCoverRecord:record];
    return name;
}
- (void)lookupCandidateCovers {
    if (!self.trackCount || !self.discFingerprint.length) return;
    [self.coverSearch cancel];
    NSMutableDictionary *old = [[self coverRecord] mutableCopy] ?: [NSMutableDictionary new];
    if ([old[@"searchVersion"] integerValue] != 63) {
        NSMutableArray *keep = [NSMutableArray new];
        BOOL keptLocal = NO;
        for (NSDictionary *entry in old[@"candidates"]) {
            if ([entry[@"source"] hasPrefix:@"Wikipedia"] || [entry[@"source"] isEqual:@"萌娘百科"]) continue;
            if ([entry[@"source"] isEqual:@"本地图片"]) { if (keptLocal) continue; keptLocal = YES; }
            [keep addObject:entry];
        }
        old[@"candidates"] = keep; [self writeCoverRecord:old];
    }
    if (![[self coverRecord][@"candidates"] count]) [self rememberCurrentCover];
    NSUInteger token = ++self.coverLookupToken;
    self.coverSearch = [CDCoverSearch new];
    self.searchBusy = YES;
    self.searchSummary = @"正在检索 MusicBrainz、Apple Music、萌娘百科与 Wikipedia…";
    [self.toast show:@"正在收集候选封面…" busy:YES];
    [self refreshCandidatePanel];
    __weak typeof(self) weakSelf = self;
    self.coverSearch.onCandidate = ^(NSDictionary *candidate, NSData *data) {
        CDApp *app = weakSelf; if (!app || token != app.coverLookupToken) return;
        NSString *file = [app saveCandidate:candidate data:data]; if (!file) return;
        NSInteger score = [candidate[@"score"] integerValue];
        if (score >= 90 && score > [[app coverRecord][@"autoScore"] integerValue] && ![app hasCoverOverride]) {
            [app setCoverImage:[[NSImage alloc] initWithData:data]]; [app cacheAutomaticCoverData:data];
            NSMutableDictionary *record = [[app coverRecord] mutableCopy]; record[@"autoScore"] = @(score); record[@"autoCandidate"] = candidate[@"id"]; record[@"current"] = candidate[@"id"]; [app writeCoverRecord:record];
        }
        [app.toast show:[NSString stringWithFormat:@"正在收集候选封面 · 已找到 %lu 张", (unsigned long)[[app coverRecord][@"candidates"] count]] busy:YES];
        [app refreshCandidatePanel];
    };
    self.coverSearch.onFinish = ^(NSString *summary) {
        CDApp *app = weakSelf; if (!app || token != app.coverLookupToken) return;
        app.searchBusy = NO;
        app.searchSummary = summary;
        NSMutableDictionary *record = [[app coverRecord] mutableCopy] ?: [NSMutableDictionary new]; record[@"searchVersion"] = @63; record[@"searchedAt"] = [NSDate date]; [app writeCoverRecord:record];
        NSUInteger count = [[app coverRecord][@"candidates"] count];
        [app.toast show:count ? [NSString stringWithFormat:@"%lu 张候选封面 · 可在齿轮菜单中挑选", (unsigned long)count] : @"暂未找到封面 · 可把图片拖进窗口" busy:NO];
        [app refreshCandidatePanel];
    };
    NSString *series = @"";
    if (self.virtualFolderPath.length) {
        NSURL *folder = [NSURL fileURLWithPath:self.virtualFolderPath isDirectory:YES];
        NSDictionary *anime = [self.library animeForAlbumFolder:folder scanRoot:folder.URLByDeletingLastPathComponent];
        NSString *title = anime[@"title"] ?: @"";
        NSString *fold = [CDCoverSearch normalized:title];
        if (fold.length >= 5 && ![@[@"resources", @"downloads", @"desktop", @"documents", @"music", @"movies", @"temp", @"temporary"] containsObject:fold]) series = title;
    }
    [self.coverSearch startWithAlbum:[self onlineAlbumKey] artist:self.albumArtist catalog:self.virtualCatalogNumber tracks:self.trackNames series:series];
}

#pragma mark - Candidate sheet

- (void)showCandidateCovers:(id)sender {
    if (self.candidatePanel) return;
    if (![[self coverRecord][@"candidates"] count]) [self rememberCurrentCover];
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 800, 640) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    panel.title = @"选择专辑封面";
    panel.minSize = NSMakeSize(560, 460);
    panel.delegate = self;
    self.candidatePanel = panel;
    NSView *root = panel.contentView;
    CGFloat W = NSWidth(root.bounds), H = NSHeight(root.bounds);
    NSTextField *title = [NSTextField labelWithString:@"选择专辑封面"];
    title.font = [NSFont systemFontOfSize:21 weight:NSFontWeightSemibold];
    title.frame = NSMakeRect(24, H - 50, 360, 28);
    title.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [root addSubview:title];
    NSTextField *hint = [NSTextField labelWithString:@"点击图片即可使用 · 候选图保存在本机，下次打开同一张 CD 仍可选择"];
    hint.font = [NSFont systemFontOfSize:11.5];
    hint.textColor = NSColor.secondaryLabelColor;
    hint.frame = NSMakeRect(25, H - 72, 520, 18);
    hint.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [root addSubview:hint];
    NSButton *refresh = [NSButton buttonWithTitle:@"重新搜索" target:self action:@selector(findOnlineCover:)];
    refresh.frame = NSMakeRect(W - 226, H - 52, 100, 32);
    refresh.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    [root addSubview:refresh];
    NSButton *done = [NSButton buttonWithTitle:@"完成" target:self action:@selector(closeCandidatePanel:)];
    done.frame = NSMakeRect(W - 118, H - 52, 94, 32);
    done.keyEquivalent = @"\r";
    done.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    [root addSubview:done];
    self.candidateScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 44, W, H - 44 - 86)];
    self.candidateScroll.hasVerticalScroller = YES;
    self.candidateScroll.drawsBackground = NO;
    self.candidateScroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [root addSubview:self.candidateScroll];
    self.candidateSpinner = [NSProgressIndicator new];
    self.candidateSpinner.style = NSProgressIndicatorStyleSpinning;
    self.candidateSpinner.controlSize = NSControlSizeSmall;
    self.candidateSpinner.displayedWhenStopped = NO;
    self.candidateSpinner.frame = NSMakeRect(24, 14, 16, 16);
    self.candidateSpinner.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
    [root addSubview:self.candidateSpinner];
    self.candidateStatus = [NSTextField labelWithString:@""];
    self.candidateStatus.font = [NSFont systemFontOfSize:11];
    self.candidateStatus.textColor = NSColor.secondaryLabelColor;
    self.candidateStatus.lineBreakMode = NSLineBreakByTruncatingTail;
    self.candidateStatus.frame = NSMakeRect(46, 13, W - 70, 18);
    self.candidateStatus.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [root addSubview:self.candidateStatus];
    [self refreshCandidatePanel];
    self.menuOpen = YES;
    [self.window beginSheet:panel completionHandler:^(NSModalResponse response) { self.menuOpen = NO; }];
    if (![[self coverRecord][@"candidates"] count]) [self lookupCandidateCovers];
}

- (void)refreshCandidatePanel {
    if (!self.candidatePanel) return;
    NSArray *candidates = [self coverRecord][@"candidates"] ?: @[];
    NSArray *ranked = [candidates sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [b[@"score"] compare:a[@"score"]]; }];
    NSMutableDictionary<NSString *, NSMutableArray<NSDictionary *> *> *byPage = [NSMutableDictionary new];
    NSMutableArray<NSString *> *order = [NSMutableArray new];
    for (NSDictionary *candidate in ranked) {
        NSString *page = candidate[@"page"] ?: @"";
        NSString *key = page.length ? [@"page:" stringByAppendingString:[[page componentsSeparatedByString:@"#"] firstObject]] : [@"item:" stringByAppendingString:candidate[@"id"] ?: @""];
        if (!byPage[key]) { byPage[key] = [NSMutableArray new]; [order addObject:key]; }
        [byPage[key] addObject:candidate];
    }
    if (!self.candidateStackPositions) self.candidateStackPositions = [NSMutableDictionary new];
    NSMutableArray *stacks = [NSMutableArray new], *shown = [NSMutableArray new];
    NSString *current = [self coverRecord][@"current"] ?: [self coverRecord][@"selectedCandidate"];
    for (NSString *key in order) {
        NSArray *stack = byPage[key];
        NSUInteger position = MIN([self.candidateStackPositions[key] unsignedIntegerValue], stack.count - 1);
        if (!self.candidateStackPositions[key] && current.length) {
            NSUInteger selected = [stack indexOfObjectPassingTest:^BOOL(NSDictionary *item, NSUInteger index, BOOL *stop) { return [item[@"id"] isEqualToString:current]; }];
            if (selected != NSNotFound) position = selected;
        }
        self.candidateStackPositions[key] = @(position);
        [stacks addObject:stack]; [shown addObject:stack[position]];
    }
    self.candidateStacks = stacks;
    self.displayedCandidates = shown;
    if (self.searchBusy) [self.candidateSpinner startAnimation:nil]; else [self.candidateSpinner stopAnimation:nil];
    self.candidateStatus.frame = NSMakeRect(self.searchBusy ? 46 : 24, 13, NSWidth(self.candidatePanel.contentView.bounds) - 70, 18);
    self.candidateStatus.stringValue = self.searchSummary ?: [NSString stringWithFormat:@"共 %lu 张候选", (unsigned long)candidates.count];
    CGFloat viewW = NSWidth(self.candidateScroll.contentView.bounds), pad = 24, gap = 22;
    NSInteger columns = MAX(2, (NSInteger)floor((viewW - pad * 2 + gap) / (190 + gap)));
    CGFloat tileW = floor((viewW - pad * 2 - gap * (columns - 1)) / columns), tileH = [CDCandidateTile heightForWidth:tileW];
    NSInteger rows = (self.displayedCandidates.count + columns - 1) / columns;
    CGFloat height = MAX(NSHeight(self.candidateScroll.contentView.bounds), pad + rows * (tileH + gap));
    NSPoint origin = self.candidateScroll.contentView.bounds.origin;
    CDFlippedView *document = [[CDFlippedView alloc] initWithFrame:NSMakeRect(0, 0, viewW, height)];
    __weak typeof(self) weakSelf = self;
    for (NSUInteger i = 0; i < self.displayedCandidates.count; i++) {
        NSDictionary *item = self.displayedCandidates[i];
        CDCandidateTile *tile = [[CDCandidateTile alloc] initWithFrame:NSMakeRect(pad + (i % columns) * (tileW + gap), 8 + (i / columns) * (tileH + gap), tileW, tileH)];
        tile.image = [[NSImage alloc] initWithContentsOfFile:[[self coverStoreDirectory] stringByAppendingPathComponent:item[@"file"]]];
        tile.title = item[@"title"] ?: @"封面";
        tile.detail = [NSString stringWithFormat:@"%@ · %@×%@", item[@"source"], item[@"width"] ?: @0, item[@"height"] ?: @0];
        tile.current = current && [current isEqual:item[@"id"]];
        tile.hasSource = [item[@"page"] length] > 0;
        tile.stackCount = self.candidateStacks[i].count;
        tile.stackIndex = [self.candidateStackPositions[order[i]] unsignedIntegerValue];
        if (tile.stackCount > 1) {
            NSMutableArray<NSImage *> *backs = [NSMutableArray new];
            for (NSDictionary *other in self.candidateStacks[i]) {
                if ([other[@"id"] isEqual:item[@"id"]]) continue;
                NSImage *back = [[NSImage alloc] initWithContentsOfFile:[[self coverStoreDirectory] stringByAppendingPathComponent:other[@"file"]]];
                if (back) [backs addObject:back];
                if (backs.count == 2) break;
            }
            tile.stackPreviewImages = backs;
        }
        tile.toolTip = [NSString stringWithFormat:@"%@ · %@", item[@"title"], item[@"reason"]];
        tile.onChoose = ^{ [weakSelf selectCandidateAtIndex:i]; };
        tile.onOpenSource = ^{ [weakSelf openCandidateSourceAtIndex:i]; };
        tile.onPrevious = ^{ [weakSelf moveCandidateStack:i delta:-1]; };
        tile.onNext = ^{ [weakSelf moveCandidateStack:i delta:1]; };
        [document addSubview:tile];
    }
    if (!candidates.count) {
        NSTextField *empty = [NSTextField labelWithString:self.searchBusy ? @"正在寻找候选封面…" : @"尚无候选封面，点击右上角「重新搜索」。"];
        empty.font = [NSFont systemFontOfSize:15];
        empty.textColor = NSColor.secondaryLabelColor;
        empty.frame = NSMakeRect(pad, 40, viewW - pad * 2, 24);
        [document addSubview:empty];
    }
    self.candidateScroll.documentView = document;
    // Preserve the user's place as asynchronous providers add results.
    [self.candidateScroll.contentView scrollToPoint:NSMakePoint(0, MIN(origin.y, MAX(0, height - NSHeight(self.candidateScroll.contentView.bounds))))];
    [self.candidateScroll reflectScrolledClipView:self.candidateScroll.contentView];
}
- (void)moveCandidateStack:(NSUInteger)index delta:(NSInteger)delta {
    if (index >= self.candidateStacks.count) return;
    NSArray *stack = self.candidateStacks[index];
    if (stack.count < 2) return;
    NSDictionary *first = stack.firstObject;
    NSString *page = first[@"page"] ?: @"";
    NSString *key = page.length ? [@"page:" stringByAppendingString:[[page componentsSeparatedByString:@"#"] firstObject]] : [@"item:" stringByAppendingString:first[@"id"] ?: @""];
    NSInteger old = [self.candidateStackPositions[key] integerValue];
    self.candidateStackPositions[key] = @((old + delta + (NSInteger)stack.count) % (NSInteger)stack.count);
    [self refreshCandidatePanel];
}
- (void)selectCandidateAtIndex:(NSUInteger)index {
    if (index >= self.displayedCandidates.count) return;
    NSDictionary *item = self.displayedCandidates[index];
    NSImage *image = [[NSImage alloc] initWithContentsOfFile:[[self coverStoreDirectory] stringByAppendingPathComponent:item[@"file"]]];
    if (!image) return;
    NSMutableDictionary *record = [[self coverRecord] mutableCopy]; record[@"manual"] = item[@"file"]; record[@"selectedCandidate"] = item[@"id"]; record[@"current"] = item[@"id"]; [self writeCoverRecord:record];
    [self setCoverImage:image]; [self.toast show:@"已记住所选封面" busy:NO];
    [self rememberLibraryCoverAtPath:[[self coverStoreDirectory] stringByAppendingPathComponent:item[@"file"]]];
    [self refreshCandidatePanel];
}
- (void)openCandidateSourceAtIndex:(NSUInteger)index {
    if (index >= self.displayedCandidates.count) return;
    NSURL *url = [NSURL URLWithString:self.displayedCandidates[index][@"page"]];
    if ([url.scheme isEqual:@"https"]) [[NSWorkspace sharedWorkspace] openURL:url];
}
- (void)closeCandidatePanel:(id)sender {
    if (!self.candidatePanel) return;
    [self.window endSheet:self.candidatePanel]; [self.candidatePanel orderOut:nil]; self.candidatePanel = nil; self.candidateScroll = nil; self.candidateStatus = nil; self.candidateSpinner = nil;
    self.menuOpen = NO;
}

#pragma mark - Ending

- (void)endSession:(id)sender {
    [self stopPlayer];
    if (self.physical) self.ignoredDiscPath = self.discPath;
    self.coverLookupToken++;
    [self.coverSearch cancel]; self.coverSearch = nil; self.searchBusy = NO;
    if (self.candidatePanel) [self closeCandidatePanel:nil];
    self.searchSummary = nil;
    self.virtualFolderPath = nil; self.virtualCatalogNumber = nil; self.discFingerprint = nil; self.cueArtworkName = nil; self.hasLocalCover = NO; self.hasCue = NO;
    self.physical = NO; self.virtualTracks = nil; self.virtualStarts = nil; self.virtualEnds = nil; self.cueSeekPending = NO; self.physicalTrackNumbers = nil; self.trackNames = nil; self.discPath = nil; self.discID = nil; self.trackCount = 0; self.trackIndex = 0;
    self.missingDiscTicks = 0;
    self.albumTitle = nil; self.albumArtist = nil;
    self.paused = NO;
    [self setCoverImage:nil];
    self.progress.doubleValue = 0;
    self.np.elapsedMS = 0; self.np.durationMS = 0; self.np.trackProgress = 0; self.np.albumProgress = 0;
    [self setPlayingState:NO];
    [self.toast hide];
    if (!self.replacingSession) [self crossfade:.5];
    if (self.replacingSession) [self refreshLabels]; else [self applyTheme];
    [self setChromeHidden:NO animated:NO];
    if (!self.replacingSession) {
        if (self.wasFullscreen && (self.window.styleMask & NSWindowStyleMaskFullScreen)) [self.window toggleFullScreen:nil];
        self.wasFullscreen = NO;
    }
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self.timer invalidate];
    [self.displayTimer invalidate];
    [self.displayLink invalidate];
    // A player stuck on a disk that stopped answering must not keep the app from quitting.
    libvlc_media_player_t *player = self.player; libvlc_instance_t *vlc = self.vlc;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(self.playerQueue, ^{
        if (player) { libvlc_media_player_stop(player); libvlc_media_player_release(player); }
        if (vlc) libvlc_release(vlc);
        dispatch_semaphore_signal(done);
    });
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)));
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        CDApp *delegate = [CDApp new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
