#import <AppKit/AppKit.h>
#import <vlc/vlc.h>
#import "CDPlaybackClock.h"
#import "CDCoverSearch.h"
#import "CDTheme.h"
#import "CDViews.h"
#import "CDHeroes.h"
#import "CDRetroPlayer.h"
#import "CDLibrary.h"
#import "CDAlbumWall.h"

NS_ASSUME_NONNULL_BEGIN

@interface CDWindow : NSWindow
@property (nonatomic, copy, nullable) void (^keyAction)(NSEvent *event);
@end

/// Root view of the window: lays out the current style, reports pointer activity and accepts dropped folders / images.
@interface CDStageView : CDFlippedView
@property (nonatomic, copy, nullable) void (^onLayout)(void);
@property (nonatomic, copy, nullable) void (^onActivity)(void);
@property (nonatomic, copy, nullable) NSString * _Nullable (^onDragEnter)(NSArray<NSURL *> *urls);
@property (nonatomic, copy, nullable) void (^onDragExit)(void);
@property (nonatomic, copy, nullable) BOOL (^onDrop)(NSArray<NSURL *> *urls);
@end

@interface CDApp : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property (nonatomic, strong) CDWindow *window;
@property (nonatomic, strong) CDStageView *stage;
@property (nonatomic, strong) CDBackdropView *backdrop;
@property (nonatomic, strong) CDHeroView *hero;
@property (nonatomic, strong) CDNowPlaying *np;
@property (nonatomic, strong) NSTextField *indexLabel, *titleLabel, *subtitleLabel, *elapsedLabel, *remainingLabel;
@property (nonatomic, strong) CDSoftButton *playButton, *prevButton, *nextButton, *gearButton, *muteButton, *openButton, *demoButton, *libraryButton, *libraryEntryButton;
@property (nonatomic, strong) CDSliderView *progress, *volumeSlider;
@property (nonatomic, strong) CDTrackListView *trackList;
@property (nonatomic, strong) CDToastView *toast;
@property (nonatomic, strong) CDDropOverlay *dropOverlay;
@property (nonatomic, strong) CDLibrary *library;
@property (nonatomic, strong, nullable) CDAlbumWall *albumWall;
@property (nonatomic) BOOL libraryArtworkRefreshStarted, albumWallClosing;
@property (nonatomic) NSUInteger albumWallToken;
@property (nonatomic, copy, nullable) NSString *wallReturnStackKey, *wallReturnPlaybackPath, *wallReturnAlbumID;
@property (nonatomic, readonly) BOOL albumWallShown;
@property (nonatomic, strong, nullable) CADisplayLink *displayLink;
@property (nonatomic) CFTimeInterval lastFrame, lastActivity;
@property (nonatomic) BOOL chromeHidden, menuOpen;
@property (nonatomic) CGFloat u;
@property (nonatomic) NSInteger styleIndex, themeIndex, backgroundMode, blurLevel, enhancementMode, cassetteLook;
@property (nonatomic) BOOL particles, listPreference;
@property (nonatomic) NSInteger savedVolume;
@property (nonatomic) CDPlaybackClock playbackClock;
@property (nonatomic, strong, nullable) CDCoverSearch *coverSearch;
@property (nonatomic) BOOL searchBusy;
@property (nonatomic, strong, nullable) NSPanel *candidatePanel;
@property (nonatomic, strong, nullable) NSScrollView *candidateScroll;
@property (nonatomic, strong, nullable) NSTextField *candidateStatus;
@property (nonatomic, strong, nullable) NSProgressIndicator *candidateSpinner;
@property (nonatomic, strong, nullable) NSArray<NSDictionary *> *displayedCandidates;
@property (nonatomic, strong, nullable) NSArray<NSArray<NSDictionary *> *> *candidateStacks;
@property (nonatomic, strong, nullable) NSMutableDictionary<NSString *, NSNumber *> *candidateStackPositions;
@property (nonatomic, copy, nullable) NSString *searchSummary;
@property (nonatomic, strong, nullable) NSTimer *timer, *displayTimer;
@property (nonatomic, strong, nullable) NSArray<NSURL *> *virtualTracks;
@property (nonatomic, strong, nullable) NSArray<NSNumber *> *virtualStarts, *virtualEnds;
@property (nonatomic, strong, nullable) NSArray<NSNumber *> *physicalTrackNumbers;
@property (nonatomic, strong, nullable) NSArray<NSString *> *trackNames;
@property (nonatomic, copy, nullable) NSString *discPath, *albumTitle, *albumArtist, *discID, *virtualFolderPath, *virtualCatalogNumber;
@property (nonatomic) NSUInteger coverLookupToken;
@property (nonatomic) BOOL hasLocalCover, hasCue;
@property (nonatomic, copy, nullable) NSString *cueArtworkName;
@property (nonatomic, copy, nullable) NSString *ignoredDiscPath;
@property (nonatomic) NSInteger trackIndex, trackCount;
@property (nonatomic) NSInteger missingDiscTicks;
@property (nonatomic) BOOL physical, paused, wasFullscreen, ending, replacingSession;
@property (nonatomic) BOOL cueSeekPending;
@property (nonatomic, copy, nullable) NSString *discFingerprint;
@property (nonatomic, strong, nullable) NSImage *sourceCover;
@property (nonatomic) NSUInteger enhancementToken;
@property (nonatomic, nullable) libvlc_instance_t *vlc;
@property (nonatomic, nullable) libvlc_media_player_t *player;
/// Stops and switches run here (they wait for VLC's reading thread); see -playerJob:leaving:then:.
@property (nonatomic, strong) dispatch_queue_t playerQueue;
@property (nonatomic) NSUInteger playerJobsSent, playerJobsDone, playerGeneration;
@property (nonatomic, copy, nullable) NSString *playerMediaPath;       // what the player was last given
@property (nonatomic) NSInteger stallTicks;                          // seconds "playing" without the position moving
@property (nonatomic) long long stallTime;
@property (nonatomic) NSUInteger loadToken;                           // the latest CD asked for; older reads are dropped
@property (nonatomic, strong, nullable) NSAlert *connectionAlert;
/// Trial whole-window blur: σ as a percentage of the window's width.
@property (nonatomic) double globalBlur;
@property (nonatomic) BOOL globalBlurOn;
@property (nonatomic, strong, nullable) NSPanel *blurPanel;
@property (nonatomic, strong, nullable) NSSlider *blurSlider;
@property (nonatomic, strong, nullable) NSTextField *blurField, *blurNote;
@property (nonatomic, strong, nullable) NSButton *blurSwitch;

- (void)loadVirtual:(NSURL *)folder;
- (void)playDemo:(nullable id)sender;
- (void)endSession:(nullable id)sender;
- (void)applyTheme;
- (void)installHero;
- (void)layoutStage;
- (void)setChromeHidden:(BOOL)hidden animated:(BOOL)animated;
- (void)showCandidateCovers:(nullable id)sender;
@end

NS_ASSUME_NONNULL_END
