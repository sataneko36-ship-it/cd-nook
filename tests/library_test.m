#import "../CDLibrary.h"
#include <assert.h>

static void WaitFor(BOOL *finished) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:30];
    while (!*finished && deadline.timeIntervalSinceNow > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
    assert(*finished);
}
static NSData *Artwork(void) {
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:256 pixelsHigh:256 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    unsigned char *pixels = bitmap.bitmapData;
    for (NSUInteger y = 0; y < 256; y++) for (NSUInteger x = 0; x < 256; x++) {
        NSUInteger p = (y * 256 + x) * 4;
        pixels[p] = (unsigned char)x; pixels[p+1] = (unsigned char)y; pixels[p+2] = 170; pixels[p+3] = 255;
    }
    return [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}
static void AddBE32(NSMutableData *data, uint32_t value) {
    unsigned char bytes[] = {(unsigned char)(value >> 24), (unsigned char)(value >> 16), (unsigned char)(value >> 8), (unsigned char)value};
    [data appendBytes:bytes length:4];
}
static NSData *FLACWithArtwork(NSData *image) {
    NSMutableData *picture = [NSMutableData new];
    const char *mime = "image/png";
    AddBE32(picture, 3); AddBE32(picture, 9); [picture appendBytes:mime length:9];
    AddBE32(picture, 0); AddBE32(picture, 256); AddBE32(picture, 256);
    AddBE32(picture, 32); AddBE32(picture, 0); AddBE32(picture, (uint32_t)image.length);
    [picture appendData:image];
    NSMutableData *flac = [NSMutableData dataWithBytes:"fLaC" length:4];
    unsigned char header[] = {0x86, (unsigned char)(picture.length >> 16), (unsigned char)(picture.length >> 8), (unsigned char)picture.length};
    [flac appendBytes:header length:4]; [flac appendData:picture];
    return flac;
}

int main(void) { @autoreleasepool {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *temp = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString] isDirectory:YES];
    NSURL *source = [temp URLByAppendingPathComponent:@"source" isDirectory:YES];
    NSURL *library = [temp URLByAppendingPathComponent:@"library" isDirectory:YES];
    NSArray *folders = @[
        [source URLByAppendingPathComponent:@"進撃の巨人/CDs/Original OST" isDirectory:YES],
        [source URLByAppendingPathComponent:@"進撃の巨人 Season 2/Extras/CDs/Character Song" isDirectory:YES],
        [source URLByAppendingPathComponent:@"鬼滅の刃/Season 3/Disc 1" isDirectory:YES],
        [source URLByAppendingPathComponent:@"Attack on Titan Season 3/CDE/Theme" isDirectory:YES]
    ];
    for (NSURL *folder in folders) {
        assert([fm createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil]);
        assert([@"dummy" writeToURL:[folder URLByAppendingPathComponent:@"disc.flac"] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    }
    NSData *image = Artwork(); assert(image.length);
    NSURL *scanFolder = [folders[0] URLByAppendingPathComponent:@"Scans" isDirectory:YES];
    assert([fm createDirectoryAtURL:scanFolder withIntermediateDirectories:YES attributes:nil error:nil]);
    assert([image writeToURL:[scanFolder URLByAppendingPathComponent:@"front.png"] atomically:YES]);
    assert([FLACWithArtwork(image) writeToURL:[folders[1] URLByAppendingPathComponent:@"disc.flac"] atomically:YES]);
    assert([image writeToURL:[folders[2] URLByAppendingPathComponent:@"art-foo.png"] atomically:YES]);
    assert([@"REM COVER \"art-foo.png\"\nTRACK 01 AUDIO\n" writeToURL:[folders[2] URLByAppendingPathComponent:@"disc.cue"] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    NSString *cue = @"TITLE \"Original OST\"\nTRACK 01 AUDIO\nTRACK 02 AUDIO\nTRACK 03 AUDIO\n";
    assert([cue writeToURL:[folders[0] URLByAppendingPathComponent:@"disc.cue"] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    NSURL *seriesFolder = [source URLByAppendingPathComponent:@"Attack on Titan Season 3"];
    assert([image writeToURL:[seriesFolder URLByAppendingPathComponent:@"poster.png"] atomically:YES]);
    CDLibrary *catalog = [[CDLibrary alloc] initWithRootURL:library];
    NSURL *bracketedCD = [source URLByAppendingPathComponent:@"[DBD-Raws][缘之空][1080p]/特典CD/依媛奈绪" isDirectory:YES];
    NSDictionary *bracketedAnime = [catalog animeForAlbumFolder:bracketedCD scanRoot:source];
    assert([bracketedAnime[@"title"] isEqualToString:@"缘之空"]);
    __block BOOL scanned = NO;
    [catalog scanFolder:source progress:nil completion:^(NSUInteger added, NSError *error) { assert(!error); assert(added == 4); scanned = YES; }];
    WaitFor(&scanned);
    assert(catalog.albums.count == 4);
    NSDictionary *first = nil, *second = nil, *alias = nil, *third = nil;
    for (NSDictionary *item in catalog.albums) {
        NSString *path = item[@"sourcePath"];
        if ([path containsString:@"Original OST"]) first = item;
        if ([path containsString:@"Character Song"]) second = item;
        if ([path containsString:@"Attack on Titan"]) alias = item;
        if ([path containsString:@"鬼滅の刃"]) third = item;
    }
    assert(first && second && alias && third);
    assert(![alias[@"coverPath"] length]);
    assert([fm fileExistsAtPath:alias[@"seriesCoverPath"]]);
    assert([alias[@"seriesCoverPath"] containsString:@".series-artwork"]);
    assert([first[@"coverPath"] hasSuffix:@"Scans/front.png"]);
    assert([fm fileExistsAtPath:second[@"coverPath"]]);
    assert([second[@"coverPath"] containsString:@".artwork/"]);
    assert([third[@"coverPath"] hasSuffix:@"art-foo.png"]);
    assert([first[@"animeKey"] isEqual:second[@"animeKey"]]);
    assert([first[@"animeKey"] isEqual:alias[@"animeKey"]]);
    assert([first[@"audioFiles"] integerValue] == 3);
    NSURL *musicRoot = [temp URLByAppendingPathComponent:@"Music" isDirectory:YES];
    NSURL *directCD = [musicRoot URLByAppendingPathComponent:@"Unknown Original OST" isDirectory:YES];
    NSDictionary *direct = [catalog animeForAlbumFolder:directCD scanRoot:musicRoot];
    assert([direct[@"title"] isEqualToString:@"Unknown Original OST"]);
    __block BOOL archived = NO;
    NSURL *chosenArchive = [temp URLByAppendingPathComponent:@"chosen archive" isDirectory:YES];
    [catalog archiveAlbums:@[first] toFolder:chosenArchive progress:nil completion:^(NSUInteger copied, NSArray<NSString *> *errors) { assert(copied == 1); assert(errors.count == 0); archived = YES; }];
    WaitFor(&archived);
    NSDictionary *updated = nil;
    for (NSDictionary *item in catalog.albums) if ([item[@"id"] isEqual:first[@"id"]]) updated = item;
    assert(updated && [updated[@"libraryPath"] length]);
    assert([updated[@"libraryPath"] hasPrefix:chosenArchive.path]);
    assert(![fm fileExistsAtPath:[library URLByAppendingPathComponent:updated[@"animeTitle"]].path]);
    assert([fm fileExistsAtPath:[[catalog playableURLForAlbum:updated] URLByAppendingPathComponent:@"disc.cue"].path]);
    assert([fm fileExistsAtPath:[[catalog playableURLForAlbum:updated] URLByAppendingPathComponent:@"disc.flac"].path]);
    NSURL *secondArchive = [temp URLByAppendingPathComponent:@"another archive" isDirectory:YES];
    __block BOOL movedArchive = NO;
    [catalog archiveAlbums:@[updated] toFolder:secondArchive progress:nil completion:^(NSUInteger copied, NSArray<NSString *> *errors) { assert(copied == 1); assert(errors.count == 0); movedArchive = YES; }];
    WaitFor(&movedArchive);
    for (NSDictionary *item in catalog.albums) if ([item[@"id"] isEqual:first[@"id"]]) updated = item;
    assert([updated[@"libraryPath"] hasPrefix:secondArchive.path]);
    assert([fm fileExistsAtPath:[chosenArchive URLByAppendingPathComponent:updated[@"animeTitle"]].path]);
    __block BOOL rejectedNestedArchive = NO;
    [catalog archiveAlbums:@[second] toFolder:[NSURL fileURLWithPath:second[@"sourcePath"] isDirectory:YES] progress:nil completion:^(NSUInteger copied, NSArray<NSString *> *errors) {
        assert(copied == 0 && errors.count == 1);
        rejectedNestedArchive = YES;
    }];
    WaitFor(&rejectedNestedArchive);
    NSURL *manual = [temp URLByAppendingPathComponent:@"manual.png"];
    assert([image writeToURL:manual atomically:YES]);
    __block BOOL remembered = NO;
    [catalog rememberArtworkAtPath:manual.path forFolder:second[@"sourcePath"] completion:^{ remembered = YES; }];
    WaitFor(&remembered);
    __block BOOL rescanned = NO;
    [catalog scanFolder:source progress:nil completion:^(NSUInteger added, NSError *error) { assert(!error); assert(added == 0); rescanned = YES; }];
    WaitFor(&rescanned);
    assert(catalog.albums.count == 4);
    for (NSDictionary *item in catalog.albums) if ([item[@"id"] isEqual:second[@"id"]]) {
        assert([item[@"coverPath"] isEqualToString:manual.path]);
        assert([item[@"artworkSource"] isEqualToString:@"selected"]);
    }
    NSURL *legacyRoot = [temp URLByAppendingPathComponent:@"legacy" isDirectory:YES];
    assert([fm createDirectoryAtURL:legacyRoot withIntermediateDirectories:YES attributes:nil error:nil]);
    NSMutableDictionary *legacyItem = [second mutableCopy];
    legacyItem[@"coverPath"] = @""; [legacyItem removeObjectForKey:@"artworkIndexed"];
    NSData *legacyJSON = [NSJSONSerialization dataWithJSONObject:@{@"version":@1, @"albums":@[legacyItem]} options:0 error:nil];
    assert([legacyJSON writeToURL:[legacyRoot URLByAppendingPathComponent:@"Library.json"] atomically:YES]);
    CDLibrary *legacy = [[CDLibrary alloc] initWithRootURL:legacyRoot];
    __block BOOL repaired = NO;
    [legacy refreshMissingArtwork:^(NSUInteger count) { assert(count == 1); repaired = YES; }];
    WaitFor(&repaired);
    assert([fm fileExistsAtPath:legacy.albums.firstObject[@"coverPath"]]);
    [fm removeItemAtURL:temp error:nil];
    // Release folders that reorder a title still find the series; a lone common word does not.
    NSDictionary *(^match)(NSString *) = ^NSDictionary *(NSString *relative) {
        NSURL *cd = [source URLByAppendingPathComponent:relative isDirectory:YES];
        [fm createDirectoryAtURL:cd withIntermediateDirectories:YES attributes:nil error:nil];
        return [catalog animeForAlbumFolder:cd scanRoot:source];
    };
    assert([match(@"迷路帖 うらら Urara Meirochou [VCB-Studio]/CDs/[170726] SPCD 05 (flac)")[@"subjectID"] integerValue] == 173303);
    assert([match(@"柑橘味香气～ citrus Citrus [VCB-Studio]/CDs/[180403] SPCD (flac)")[@"subjectID"] integerValue] == 198098);
    assert([match(@"勇者企劃 えんどろ〜！ Endro~! [VCB-Studio]/CDs/[190626] SPCD 04 (flac)")[@"subjectID"] integerValue] == 254895);
    assert([match(@"魔王 うちの娘の為ならば、俺はもしかしたら も倒せるかもしれない。 Uchinoko/CDs/[190925] OST (flac)")[@"subjectID"] integerValue] == 275352);
    assert([match(@"初音未来 Magical Mirai 2018 Hatsune Miku Magical Mirai 2018/[181128] Official Album (flac)")[@"subjectID"] integerValue] == 0);
    NSLog(@"Recursive scan, season grouping, reordered titles, nested/CUE/FLAC artwork, legacy repair, selection persistence and archive copy passed");
    return 0;
} }
