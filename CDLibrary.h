#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// A local catalogue of CD folders. Scanning only indexes; archiving copies on request.
@interface CDLibrary : NSObject
@property (nonatomic, strong, readonly) NSURL *rootURL;
@property (nonatomic, copy, readonly) NSArray<NSDictionary *> *albums;
- (instancetype)initWithRootURL:(NSURL *)rootURL;
- (void)scanFolder:(NSURL *)folder
         progress:(void (^ _Nullable)(NSUInteger found))progress
       completion:(void (^)(NSUInteger added, NSError * _Nullable error))completion;
- (void)archiveAlbums:(NSArray<NSDictionary *> *)albums
            toFolder:(NSURL *)folder
             progress:(void (^ _Nullable)(NSUInteger done, NSUInteger total))progress
           completion:(void (^)(NSUInteger copied, NSArray<NSString *> *errors))completion;
/// The archived copy when it is there, else the original folder. Looks at the disk: call it off the main thread.
- (NSURL *)playableURLForAlbum:(NSDictionary *)album;
/// Exposed for deterministic local recognition tests.
- (NSDictionary *)animeForAlbumFolder:(NSURL *)folder scanRoot:(NSURL *)scanRoot;
/// Upgrade older catalogue entries by indexing embedded, CUE and nested artwork.
- (void)refreshMissingArtwork:(void (^)(NSUInteger repaired))completion;
- (void)resolveSeriesArtwork:(void (^ _Nullable)(NSUInteger done, NSUInteger total))progress completion:(void (^)(NSUInteger repaired))completion;
- (void)rememberArtworkAtPath:(NSString *)path forFolder:(NSString *)folder completion:(void (^ _Nullable)(void))completion;
/// Resolve folder-name-only groups against existing wiki providers, then persist verified matches.
- (void)resolveUnmatchedOnline:(void (^ _Nullable)(NSUInteger done, NSUInteger total))progress
                   completion:(void (^)(NSUInteger recognized))completion;
@end

NS_ASSUME_NONNULL_END
