#import "../CDCoverSearch.h"
#include <assert.h>

@interface CDCoverSearch (FallbackTest)
- (NSDictionary *)jsonAt:(NSString *)url;
- (NSData *)dataAt:(NSString *)url;
- (void)searchMusicBrainz;
- (void)searchApple;
- (void)searchMoegirl;
- (void)searchWiki:(NSString *)language;
- (void)searchSeriesMoegirl;
@end

@interface SilentFallbackSearch : CDCoverSearch
@property (nonatomic, strong) NSData *imageData;
@end
@implementation SilentFallbackSearch
- (void)searchMusicBrainz {}
- (void)searchApple {}
- (void)searchMoegirl {}
- (void)searchWiki:(NSString *)language {}
- (void)searchSeriesMoegirl {}
- (NSDictionary *)jsonAt:(NSString *)url {
    if (![url containsString:@"zh.wikipedia.org"]) return @{};
    if ([url containsString:@"list=search"]) return @{ @"query":@{ @"search":@[ @{ @"title":@"Gabriel Dropout", @"pageid":@42 } ] } };
    if ([url containsString:@"pageids=42"]) return @{ @"query":@{ @"pages":@{ @"42":@{ @"thumbnail":@{ @"source":@"https://upload.wikimedia.org/test.png" } } } } };
    return @{};
}
- (NSData *)dataAt:(NSString *)url { return [url isEqualToString:@"https://upload.wikimedia.org/test.png"] ? self.imageData : nil; }
@end

int main(void) { @autoreleasepool {
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:220 pixelsHigh:220 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bitmapFormat:0 bytesPerRow:0 bitsPerPixel:0];
    SilentFallbackSearch *search = [SilentFallbackSearch new];
    search.imageData = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    __block BOOL finished = NO;
    __block NSUInteger found = 0;
    search.onCandidate = ^(NSDictionary *candidate, NSData *data) {
        assert([candidate[@"score"] integerValue] < 55);
        assert([candidate[@"page"] containsString:@"Gabriel%20Dropout"]);
        assert(data.length > 0);
        found++;
    };
    search.onFinish = ^(NSString *summary) { finished = YES; };
    [search startWithAlbum:@"Unknown CD" artist:@"" catalog:@"" tracks:@[] series:@"Gabriel Dropout"];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
    while (!finished && deadline.timeIntervalSinceNow > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
    assert(finished && found == 1);
    NSLog(@"Anime series image fallback passed");
    return 0;
} }
