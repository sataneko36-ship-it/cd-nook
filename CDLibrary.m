#import "CDLibrary.h"
#import "CDVolumes.h"
#import <CommonCrypto/CommonDigest.h>
#import <ImageIO/ImageIO.h>

static NSString *CDLString(id value) { return [value isKindOfClass:NSString.class] ? value : @""; }
/// How long one CD's worth of disk work may take before its disk counts as not answering (a sleeping drive spins
/// up well within this).
static const NSTimeInterval CDLDiskPatience = 15;
/// Whether a file exists, without waiting on a disk that does not answer; then the answer is `unknown`.
static BOOL CDLExists(NSString *path, BOOL unknown) {
    if (!path.length) return NO;
    BOOL answered = YES;
    NSNumber *exists = CDVolumeRun(path, CDLDiskPatience, ^id{ return @([NSFileManager.defaultManager fileExistsAtPath:path]); }, &answered);
    return answered ? exists.boolValue : unknown;
}
static NSArray *CDLArray(id value) { return [value isKindOfClass:NSArray.class] ? value : @[]; }
static NSURL *CDLLegacyRootURL(void) {
    NSString *music = NSSearchPathForDirectoriesInDomains(NSMusicDirectory, NSUserDomainMask, YES).firstObject ?: [NSHomeDirectory() stringByAppendingPathComponent:@"Music"];
    return [NSURL fileURLWithPath:[music stringByAppendingPathComponent:@"CD Glass Library"] isDirectory:YES];
}
static NSString *CDLHash(NSString *value) {
    unsigned char bytes[CC_SHA256_DIGEST_LENGTH]; NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
    CC_SHA256(data.bytes, (CC_LONG)data.length, bytes);
    NSMutableString *result = [NSMutableString new];
    for (int i = 0; i < 8; i++) [result appendFormat:@"%02x", bytes[i]];
    return result;
}
static NSString *CDLReplace(NSString *value, NSString *pattern, NSString *replacement) {
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:nil];
    return [regex stringByReplacingMatchesInString:value options:0 range:NSMakeRange(0, value.length) withTemplate:replacement];
}
static NSString *CDLFold(NSString *value) {
    NSString *folded = [[value precomposedStringWithCanonicalMapping] stringByFoldingWithOptions:NSCaseInsensitiveSearch | NSWidthInsensitiveSearch | NSDiacriticInsensitiveSearch locale:[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]];
    return [[folded componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet] componentsJoinedByString:@""];
}
static NSString *CDLClean(NSString *value) {
    value = CDLReplace(value, @"\\[[^]]*\\]", @" ");
    value = CDLReplace(value, @"\\((?:flac|wav|mp3|aac|webp|log)[^)]*\\)", @" ");
    value = CDLReplace(value, @"(?:1080p|720p|2160p|bdrip|bdrip|bluray|x264|x265|10bit)", @" ");
    value = CDLReplace(value, @"^\\s*(?:cds?|disc|disk|ost|soundtrack|audio|music|特典|原声|音楽|音乐)[ _.-]*", @" ");
    return [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}
static NSString *CDLSeriesStem(NSString *value) {
    value = CDLClean(value);
    value = CDLReplace(value, @"(?:第[一二三四五六七八九十0-9]+[季期部]|(?:season|series|part|cour)[ ._-]*(?:[0-9]+|one|two|three|four)|[0-9]+(?:st|nd|rd|th)[ ._-]*season|[0-9]+期|s[0-9]+|r[0-9]+|Ⅱ|Ⅲ|Ⅳ|ii|iii|iv)\\s*$", @"");
    return CDLFold(value);
}
/// Splits a folded title where the script changes (kana / kanji / Latin letters and digits).
static NSArray<NSString *> *CDLScriptRuns(NSString *folded) {
    NSMutableArray *runs = [NSMutableArray new];
    NSInteger current = -1; NSUInteger start = 0;
    for (NSUInteger i = 0; i <= folded.length; i++) {
        NSInteger script = -1;
        if (i < folded.length) {
            unichar c = [folded characterAtIndex:i];
            script = (c >= 0x3040 && c <= 0x309F) ? 1 : (c >= 0x30A0 && c <= 0x30FF) ? 2 : ((c >= 0x4E00 && c <= 0x9FFF) || (c >= 0x3400 && c <= 0x4DBF)) ? 3 : c < 0x80 ? 4 : 5;
        }
        if (script != current) {
            if (i > start && current >= 0) [runs addObject:[folded substringWithRange:NSMakeRange(start, i - start)]];
            current = script; start = i;
        }
    }
    return runs;
}
static NSString *CDLSafeName(NSString *value) {
    value = CDLReplace(value, @"[/\\\\:]+", @" · ");
    value = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (value.length > 80) value = [value substringToIndex:80];
    return value.length ? value : @"未命名";
}
static NSString *CDLQueryURL(NSString *base, NSDictionary<NSString *, NSString *> *parameters) {
    NSURLComponents *parts = [NSURLComponents componentsWithString:base];
    NSMutableArray *items = [NSMutableArray new];
    for (NSString *key in parameters) [items addObject:[NSURLQueryItem queryItemWithName:key value:parameters[key]]];
    parts.queryItems = items;
    return parts.URL.absoluteString ?: @"";
}
static BOOL CDLIsImage(NSURL *url) {
    return [@[@"jpg", @"jpeg", @"png", @"webp", @"heic"] containsObject:url.pathExtension.lowercaseString];
}
static BOOL CDLUsableSeriesArtwork(NSString *path) {
    if (!path.length) return NO;
    NSNumber *usable = CDVolumeRun(path, CDLDiskPatience, ^id{
        CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
        NSDictionary *info = source ? CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source,0,NULL)) : nil;
        if (source) CFRelease(source);
        double width = [info[(id)kCGImagePropertyPixelWidth] doubleValue], height = [info[(id)kCGImagePropertyPixelHeight] doubleValue];
        return @(width >= 120 && height >= 120 && width/height >= .5 && width/height <= 1.9);
    }, NULL);
    return usable.boolValue;
}
static CGFloat CDLArtworkScore(NSURL *url, NSString *cueArtwork, BOOL nested) {
    NSString *name = url.lastPathComponent.lowercaseString;
    NSString *stem = url.lastPathComponent.stringByDeletingPathExtension.lowercaseString;
    CGFloat score = nested ? 18 : 38;
    if (cueArtwork.length && [url.lastPathComponent caseInsensitiveCompare:cueArtwork] == NSOrderedSame) score += 100;
    if ([stem isEqualToString:@"cover"] || [stem isEqualToString:@"front"]) score += 90;
    else if ([stem isEqualToString:@"folder"] || [stem isEqualToString:@"album"] || [stem isEqualToString:@"artwork"]) score += 75;
    else if ([stem isEqualToString:@"001"] || [stem isEqualToString:@"01"] || [stem isEqualToString:@"1"]) score += 18;
    if ([name containsString:@"back"] || [name containsString:@"disc"] || [name containsString:@"booklet"] || [name containsString:@"tray"]) score -= 65;
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!source) return -CGFLOAT_MAX;
    NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    CFRelease(source);
    CGFloat width = [properties[(NSString *)kCGImagePropertyPixelWidth] doubleValue];
    CGFloat height = [properties[(NSString *)kCGImagePropertyPixelHeight] doubleValue];
    if (width < 120 || height < 120) return -CGFLOAT_MAX;
    CGFloat ratio = width / MAX(height, 1);
    if (ratio < .65 || ratio > 1.55) score -= 90;
    else score += 30 * (1 - MIN(1, fabs(log(ratio))));
    return score;
}
static uint32_t CDLReadBE32(const unsigned char *bytes) {
    return ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) | ((uint32_t)bytes[2] << 8) | bytes[3];
}
static NSData *CDLNetworkData(NSString *address) {
    NSURL *url = [NSURL URLWithString:address];
    if (![url.scheme isEqualToString:@"https"]) return nil;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 8;
    [request setValue:@"CDGlass/0.12 (personal anime CD catalogue)" forHTTPHeaderField:@"User-Agent"];
    __block NSData *body = nil;
    dispatch_semaphore_t signal = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!error && [(NSHTTPURLResponse *)response statusCode] == 200 && data.length < 2 * 1024 * 1024) body = data;
        dispatch_semaphore_signal(signal);
    }];
    [task resume];
    if (dispatch_semaphore_wait(signal, dispatch_time(DISPATCH_TIME_NOW, 9 * NSEC_PER_SEC))) { [task cancel]; return nil; }
    return body;
}

@interface CDLibrary ()
@property (nonatomic, strong, readwrite) NSURL *rootURL;
@property (nonatomic, copy, readwrite) NSArray<NSDictionary *> *albums;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) NSArray<NSDictionary *> *nameEntries;
@property (nonatomic, strong) NSArray<NSDictionary *> *shortNameEntries, *tokenEntries, *splitEntries;
@property (nonatomic, strong) NSDictionary<NSNumber *, NSString *> *posters;
@end

@implementation CDLibrary
- (instancetype)init {
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject ?: [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support"];
    // Folders keep the app's earlier name (CD Glass), so libraries, covers and caches from before the rename carry over.
    NSURL *root = [NSURL fileURLWithPath:[support stringByAppendingPathComponent:@"CD Glass/Library"] isDirectory:YES];
    NSURL *index = [root URLByAppendingPathComponent:@"Library.json"];
    NSURL *legacyIndex = [CDLLegacyRootURL() URLByAppendingPathComponent:@"Library.json"];
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:index.path] && [fm fileExistsAtPath:legacyIndex.path]) {
        NSError *error = nil;
        [fm createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:&error];
        if (!error) [fm copyItemAtURL:legacyIndex toURL:index error:&error];
        // Keep the original catalogue usable if migration cannot write the new location.
        if (error) return [self initWithRootURL:CDLLegacyRootURL()];
    }
    return [self initWithRootURL:root];
}
- (instancetype)initWithRootURL:(NSURL *)rootURL {
    if ((self = [super init])) {
        _rootURL = rootURL.URLByStandardizingPath;
        _queue = dispatch_queue_create("local.cdglass.library", DISPATCH_QUEUE_SERIAL);
        [[NSFileManager defaultManager] createDirectoryAtURL:_rootURL withIntermediateDirectories:YES attributes:nil error:nil];
        NSData *data = [NSData dataWithContentsOfURL:[_rootURL URLByAppendingPathComponent:@"Library.json"]];
        NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        _albums = [CDLArray(json[@"albums"]) copy];
    }
    return self;
}
- (NSArray<NSDictionary *> *)nameEntries {
    @synchronized (self) {
        if (_nameEntries) return _nameEntries;
        NSString *testIndex = NSProcessInfo.processInfo.environment[@"CDGLASS_ANIME_INDEX"];
        NSURL *url = testIndex.length ? [NSURL fileURLWithPath:testIndex] : [[NSBundle mainBundle] URLForResource:@"AnimeTitles" withExtension:@"json"];
        NSData *data = [NSData dataWithContentsOfURL:url];
        NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSMutableArray *entries = [NSMutableArray new];
        NSMutableArray *shortEntries = [NSMutableArray new], *splitEntries = [NSMutableArray new];
        NSMutableDictionary *posters = [NSMutableDictionary new];
        NSArray *subjects = CDLArray(json[@"subjects"]);
        for (NSDictionary *subject in subjects) if (CDLString(subject[@"poster"]).length && subject[@"id"]) posters[subject[@"id"]] = subject[@"poster"];
        NSMutableDictionary<NSString *, NSDictionary *> *baseTitles = [NSMutableDictionary new];
        for (NSDictionary *subject in subjects) {
            NSString *title = CDLString(subject[@"title"]), *folded = CDLFold(CDLReplace(title, @"^(?:劇場版|剧场版|映画|電影)\\s*", @""));
            if (folded.length >= 5 && !baseTitles[folded]) baseTitles[folded] = subject;
        }
        for (NSDictionary *subject in subjects) {
            NSString *title = CDLString(subject[@"title"]), *key = CDLSeriesStem(title);
            if (!key.length) continue;
            NSString *display = CDLString(subject[@"zh"]).length ? subject[@"zh"] : title;
            display = CDLReplace(display, @"(?:第[一二三四五六七八九十0-9]+[季期部]|(?:season|part)[ ._-]*[0-9]+|[0-9]+期)\\s*$", @"");
            NSString *foldedTitle = CDLFold(CDLReplace(title, @"^(?:劇場版|剧场版|映画|電影)\\s*", @""));
            // A later season, part or film keeps the earliest full-length series title as its root.
            for (NSUInteger length = 5; length < foldedTitle.length; length++) {
                NSDictionary *base = baseTitles[[foldedTitle substringToIndex:length]];
                if (!base || (length < 7 && [[foldedTitle substringToIndex:length] canBeConvertedToEncoding:NSASCIIStringEncoding])) continue;
                key = CDLSeriesStem(CDLString(base[@"title"]));
                display = CDLString(base[@"zh"]).length ? base[@"zh"] : CDLString(base[@"title"]);
                break;
            }
            for (NSString *alias in CDLArray(subject[@"names"])) {
                NSString *needle = CDLFold(alias);
                if (needle.length >= 3 && needle.length < 5 && ![needle canBeConvertedToEncoding:NSASCIIStringEncoding]) {
                    [shortEntries addObject:@{@"needle":needle, @"key":key, @"title":display, @"subjectID":subject[@"id"] ?: @0, @"sourceTitle":title, @"sourceAlias":alias}];
                    continue;
                }
                NSDictionary *entry = @{@"needle":needle, @"key":key, @"title":display, @"subjectID":subject[@"id"] ?: @0, @"sourceTitle":title, @"sourceAlias":alias};
                // Very short aliases often occur inside unrelated release names.
                if (needle.length < 5 || ([needle canBeConvertedToEncoding:NSASCIIStringEncoding] && needle.length < 7)) continue;
                [entries addObject:entry];
                NSMutableArray *runs = [NSMutableArray new];
                NSUInteger covered = 0;
                for (NSString *run in CDLScriptRuns(needle)) if (run.length >= 3) { [runs addObject:run]; covered += run.length; }
                if (runs.count >= 2 && covered >= 6) [splitEntries addObject:@{@"runs":runs, @"entry":entry}];
            }
        }
        _shortNameEntries = [shortEntries copy];
        // Short non-Latin aliases ("えんどろ〜！") count only as a whole word of a folder name.
        _tokenEntries = [shortEntries copy];
        _splitEntries = [splitEntries copy];
        _posters = [posters copy];
        _nameEntries = [entries copy];
        return _nameEntries;
    }
}
- (NSDictionary *)animeForAlbumFolder:(NSURL *)folder scanRoot:(NSURL *)scanRoot {
    NSString *root = [scanRoot.URLByStandardizingPath.path stringByResolvingSymlinksInPath];
    NSURL *cursor = folder.URLByDeletingLastPathComponent;
    NSMutableArray<NSString *> *parents = [NSMutableArray new];
    NSMutableArray<NSString *> *bracketed = [NSMutableArray new];
    NSRegularExpression *brackets = [NSRegularExpression regularExpressionWithPattern:@"\\[([^]]+)\\]" options:0 error:nil];
    NSArray *generic = @[@"cd",@"cds",@"music",@"ost",@"bonus",@"soundtrack",@"audio",@"disc",@"discs",@"特典",@"音楽",@"音乐"];
    while (cursor && parents.count < 12) {
        NSString *raw = cursor.lastPathComponent;
        for (NSTextCheckingResult *match in [brackets matchesInString:raw options:0 range:NSMakeRange(0, raw.length)]) {
            NSString *token = CDLFold([raw substringWithRange:[match rangeAtIndex:1]]);
            if (token.length >= 3) [bracketed addObject:token];
        }
        NSString *part = CDLClean(cursor.lastPathComponent);
        NSString *fold = CDLFold(part);
        if (fold.length > 3 && ![generic containsObject:fold]) [parents addObject:part];
        NSString *cursorPath = [cursor.path stringByResolvingSymlinksInPath];
        BOOL atRoot = [cursorPath isEqualToString:root];
        if (atRoot && (parents.count || ![@[@"cd", @"cds", @"disc", @"discs"] containsObject:fold])) break;
        // A selected "CDs" directory may borrow one parent. Never climb beyond that parent.
        if (![cursorPath hasPrefix:[root stringByAppendingString:@"/"]] && !atRoot) break;
        NSURL *next = cursor.URLByDeletingLastPathComponent;
        if ([next.path isEqualToString:cursor.path]) break;
        cursor = next;
    }
    NSString *parentText = CDLFold([parents componentsJoinedByString:@" "]);
    NSString *albumText = CDLFold(folder.lastPathComponent);
    NSDictionary *best = nil; NSUInteger bestScore = 0;
    for (NSDictionary *entry in self.nameEntries) {
        NSString *needle = entry[@"needle"];
        BOOL inParent = parentText.length && [parentText containsString:needle];
        BOOL inAlbum = !inParent && [albumText containsString:needle];
        if (!inParent && !inAlbum) continue;
        NSUInteger score = needle.length + (inParent ? 100 : 0);
        if (score > bestScore) { best = entry; bestScore = score; }
    }
    if (best) return @{@"key":best[@"key"], @"title":best[@"title"], @"subjectID":best[@"subjectID"], @"basis":@"本机番剧别名索引"};
    // Release folders sometimes reorder a title ("迷路帖 うらら" for うらら迷路帖, "柑橘味香气～ citrus" for
    // citrus～柑橘味香气～): each part written in one script must appear, in any order. A short alias
    // ("えんどろ〜！") counts when it is a whole word of the folder name.
    NSMutableSet<NSString *> *words = [NSMutableSet new];
    for (NSString *part in parents) for (NSString *word in [part componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]) {
        NSString *folded = CDLFold(word);
        if (folded.length >= 4) [words addObject:folded];
    }
    for (NSDictionary *split in self.splitEntries) {
        NSDictionary *entry = split[@"entry"];
        NSString *needle = entry[@"needle"];
        if (needle.length <= bestScore || !parentText.length) continue;
        BOOL all = YES;
        for (NSString *run in split[@"runs"]) if (![parentText containsString:run]) { all = NO; break; }
        if (all) { best = entry; bestScore = needle.length; }
    }
    for (NSDictionary *entry in self.tokenEntries) {
        NSString *needle = entry[@"needle"];
        if (needle.length > bestScore && [words containsObject:needle]) { best = entry; bestScore = needle.length; }
    }
    if (best) return @{@"key":best[@"key"], @"title":best[@"title"], @"subjectID":best[@"subjectID"], @"basis":@"本机番剧别名索引"};
    for (NSDictionary *entry in [self.nameEntries arrayByAddingObjectsFromArray:self.shortNameEntries ?: @[]]) {
        NSString *needle = entry[@"needle"];
        for (NSString *token in bracketed) {
            if (![token isEqualToString:needle] && !(needle.length >= 5 && [token containsString:needle] && needle.length * 4 >= token.length * 3)) continue;
            if (needle.length > bestScore) { best = entry; bestScore = needle.length; }
        }
    }
    if (best) return @{@"key":best[@"key"], @"title":best[@"title"], @"subjectID":best[@"subjectID"], @"basis":@"母文件夹番剧别名"};
    NSString *hint = parents.firstObject ?: CDLClean(folder.lastPathComponent);
    if (!hint.length || [CDLFold(hint) isEqualToString:CDLFold(root.lastPathComponent)]) hint = @"待识别番剧";
    NSString *key = CDLSeriesStem(hint);
    return @{@"key":key.length ? key : @"unmatched", @"title":hint, @"subjectID":@0, @"basis":@"文件夹名称"};
}
- (NSDictionary *)localAnimeForTitle:(NSString *)title {
    NSString *folded = CDLFold(title);
    NSDictionary *best = nil; NSUInteger length = 0;
    for (NSDictionary *entry in self.nameEntries) {
        NSString *needle = entry[@"needle"];
        if (([folded containsString:needle] || [needle containsString:folded]) && needle.length > length && folded.length >= 5) { best = entry; length = needle.length; }
    }
    return best;
}
- (NSDictionary *)onlineAnimeForHint:(NSString *)hint {
    NSString *wanted = CDLSeriesStem(hint);
    if (wanted.length < 5 || [wanted isEqualToString:@"unmatched"]) return nil;
    // Search providers already used by the cover finder. Names alone leave no private audio content.
    for (NSString *language in @[@"zh", @"ja", @"en"]) {
        NSString *base = [NSString stringWithFormat:@"https://%@.wikipedia.org/w/api.php", language];
        NSString *address = CDLQueryURL(base, @{ @"action":@"query", @"format":@"json", @"list":@"search", @"srsearch":hint, @"srlimit":@"4" });
        NSData *data = CDLNetworkData(address);
        NSDictionary *response = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        for (NSDictionary *page in CDLArray([response[@"query"] isKindOfClass:NSDictionary.class] ? response[@"query"][@"search"] : nil)) {
            NSString *title = CDLString(page[@"title"]), *stem = CDLSeriesStem(title);
            if (stem.length < 5 || !([wanted containsString:stem] || [stem containsString:wanted]) || MIN(stem.length, wanted.length) * 2 < MAX(stem.length, wanted.length)) continue;
            NSDictionary *local = [self localAnimeForTitle:title];
            NSString *canonical = local ? local[@"key"] : stem;
            NSString *display = local ? local[@"title"] : CDLReplace(title, @"(?:第[一二三四五六七八九十0-9]+[季期部]|season[ ._-]*[0-9]+)\\s*$", @"");
            NSString *pageURL = [NSString stringWithFormat:@"https://%@.wikipedia.org/wiki/%@", language, [title stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet]];
            return @{ @"key":canonical, @"title":display, @"basis":@"Wikipedia 番剧条目", @"page":pageURL };
        }
    }
    NSString *address = CDLQueryURL(@"https://zh.moegirl.org.cn/index.php", @{ @"title":@"Special:Search", @"search":hint, @"fulltext":@"1", @"limit":@"4" });
    NSData *data = CDLNetworkData(address);
    NSString *html = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    NSXMLDocument *doc = html.length ? [[NSXMLDocument alloc] initWithXMLString:html options:NSXMLDocumentTidyHTML | NSXMLNodeLoadExternalEntitiesNever error:nil] : nil;
    for (NSXMLElement *link in [doc nodesForXPath:@"//div[contains(@class,'mw-search-result-heading')]/a[1]" error:nil]) {
        NSString *title = link.stringValue ?: @"", *stem = CDLSeriesStem(title);
        if (stem.length < 5 || !([wanted containsString:stem] || [stem containsString:wanted]) || MIN(stem.length, wanted.length) * 2 < MAX(stem.length, wanted.length)) continue;
        NSDictionary *local = [self localAnimeForTitle:title];
        NSString *page = [[NSURL URLWithString:[link attributeForName:@"href"].stringValue relativeToURL:[NSURL URLWithString:@"https://zh.moegirl.org.cn/"]] absoluteURL].absoluteString ?: @"";
        return @{ @"key":local ? local[@"key"] : stem, @"title":local ? local[@"title"] : title, @"basis":@"萌娘百科番剧条目", @"page":page };
    }
    return nil;
}
- (void)resolveUnmatchedOnline:(void (^)(NSUInteger, NSUInteger))progress completion:(void (^)(NSUInteger))completion {
    NSArray *snapshot = self.albums;
    dispatch_async(self.queue, ^{
        NSMutableDictionary<NSString *, NSMutableDictionary *> *records = [NSMutableDictionary new];
        NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *unmatched = [NSMutableDictionary new];
        for (NSDictionary *item in snapshot) {
            NSString *path = CDLString(item[@"sourcePath"]);
            if (!path.length) continue;
            records[path] = [item mutableCopy];
            if (![item[@"basis"] isEqualToString:@"文件夹名称"]) continue;
            NSString *hint = CDLString(item[@"animeTitle"]);
            if (!unmatched[hint]) unmatched[hint] = [NSMutableArray new];
            [unmatched[hint] addObject:path];
        }
        NSUInteger done = 0, recognized = 0;
        for (NSString *hint in [[unmatched allKeys] sortedArrayUsingSelector:@selector(localizedStandardCompare:)]) {
            NSDictionary *anime = [self onlineAnimeForHint:hint];
            for (NSString *path in unmatched[hint]) if (anime) {
                NSMutableDictionary *record = records[path];
                record[@"animeKey"] = anime[@"key"]; record[@"animeTitle"] = anime[@"title"];
                record[@"basis"] = anime[@"basis"]; record[@"animePage"] = anime[@"page"];
                recognized++;
            }
            done++;
            if (progress) dispatch_async(dispatch_get_main_queue(), ^{ progress(done, unmatched.count); });
        }
        NSArray *result = [[records allValues] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [CDLString(a[@"animeTitle"]) localizedStandardCompare:CDLString(b[@"animeTitle"])]; }];
        [self saveAlbums:result];
        dispatch_async(dispatch_get_main_queue(), ^{ self.albums = result; completion(recognized); });
    });
}
- (NSString *)embeddedFLACArtworkForFiles:(NSArray<NSURL *> *)files folder:(NSURL *)folder {
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSURL *file in files) {
        if (![file.pathExtension.lowercaseString isEqualToString:@"flac"]) continue;
        NSFileHandle *handle = [NSFileHandle fileHandleForReadingFromURL:file error:nil];
        if (!handle) continue;
        NSData *magic = [handle readDataOfLength:4];
        if (magic.length != 4 || memcmp(magic.bytes, "fLaC", 4) != 0) { [handle closeFile]; continue; }
        for (NSUInteger block = 0; block < 32; block++) {
            NSData *header = [handle readDataOfLength:4];
            if (header.length != 4) break;
            const unsigned char *h = header.bytes;
            NSUInteger length = ((NSUInteger)h[1] << 16) | ((NSUInteger)h[2] << 8) | h[3];
            BOOL last = (h[0] & 0x80) != 0;
            if ((h[0] & 0x7f) == 6 && length > 32 && length <= 24 * 1024 * 1024) {
                NSData *body = [handle readDataOfLength:length];
                const unsigned char *p = body.bytes; NSUInteger n = body.length, at = 4;
                if (n < 32 || at + 4 > n) break;
                NSUInteger mimeLength = CDLReadBE32(p + at); at += 4;
                if (mimeLength > n - at) break;
                NSString *mime = [[NSString alloc] initWithBytes:p + at length:mimeLength encoding:NSASCIIStringEncoding] ?: @"";
                at += mimeLength;
                if (at + 4 > n) break;
                NSUInteger descriptionLength = CDLReadBE32(p + at); at += 4;
                if (descriptionLength > n - at) break;
                at += descriptionLength;
                if (at + 20 > n) break;
                at += 16;
                NSUInteger pictureLength = CDLReadBE32(p + at); at += 4;
                if (pictureLength > n - at || pictureLength > 22 * 1024 * 1024) break;
                NSData *picture = [NSData dataWithBytes:p + at length:pictureLength];
                CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)picture, NULL);
                BOOL valid = source && CGImageSourceGetCount(source) > 0;
                if (source) CFRelease(source);
                if (!valid) break;
                NSString *extension = [mime.lowercaseString containsString:@"png"] ? @"png" : [mime.lowercaseString containsString:@"webp"] ? @"webp" : @"jpg";
                NSString *key = CDLHash([NSString stringWithFormat:@"%@:%@:%llu", folder.path, file.lastPathComponent, (unsigned long long)pictureLength]);
                NSURL *directory = [self.rootURL URLByAppendingPathComponent:@".artwork" isDirectory:YES];
                NSURL *saved = [directory URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@", key, extension]];
                [fm createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
                if ([fm fileExistsAtPath:saved.path] || [picture writeToURL:saved options:NSDataWritingAtomic error:nil]) { [handle closeFile]; return saved.path; }
                break;
            }
            if (length > 24 * 1024 * 1024) break;
            [handle seekToFileOffset:handle.offsetInFile + length];
            if (last) break;
        }
        [handle closeFile];
    }
    return @"";
}
- (NSString *)artworkForFolder:(NSURL *)folder files:(NSArray<NSURL *> *)files cueArtwork:(NSString *)cueArtwork {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *best = nil; CGFloat bestScore = -CGFLOAT_MAX;
    for (NSURL *file in files) if (CDLIsImage(file)) {
        CGFloat score = CDLArtworkScore(file, cueArtwork, NO);
        if (score > bestScore) { best = file; bestScore = score; }
    }
    if (bestScore < 60) {
        NSArray<NSURL *> *children = [fm contentsOfDirectoryAtURL:folder includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
        for (NSURL *child in children) {
            NSNumber *directory = nil; [child getResourceValue:&directory forKey:NSURLIsDirectoryKey error:nil];
            if (!directory.boolValue) continue;
            for (NSURL *image in [fm contentsOfDirectoryAtURL:child includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil]) if (CDLIsImage(image)) {
                CGFloat score = CDLArtworkScore(image, cueArtwork, YES);
                if (score > bestScore) { best = image; bestScore = score; }
            }
        }
    }
    if (bestScore >= 60) return best.path;
    NSString *embedded = [self embeddedFLACArtworkForFiles:files folder:folder];
    return embedded.length ? embedded : (bestScore > 0 ? best.path : @"");
}
// Resolve the anime's parent-folder key visual separately from the CD artwork.
// Keeping two fields prevents an anime poster from being mistaken for a verified
// album cover when the user later corrects the sleeve in the player.
- (NSString *)localSeriesArtworkForFolder:(NSURL *)folder {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *cursor = folder.URLByDeletingLastPathComponent;
    for (NSUInteger depth = 0; depth < 6 && cursor.path.length > 1; depth++, cursor = cursor.URLByDeletingLastPathComponent) {
        NSString *name = cursor.lastPathComponent.lowercaseString;
        if ([@[@"volumes",@"users",@"music",@"movies",@"downloads",@"documents",@"source",@"夢の残響",@"永遠の残響"] containsObject:name]) break;
        NSArray *files = [fm contentsOfDirectoryAtURL:cursor includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
        NSURL *best = nil; NSInteger bestScore = 0; BOOL hasVideo = NO;
        for (NSURL *file in files) {
            NSString *stem = file.lastPathComponent.stringByDeletingPathExtension.lowercaseString;
            if ([@[@"mkv",@"mp4",@"m2ts"] containsObject:file.pathExtension.lowercaseString]) hasVideo = YES;
            if (!CDLIsImage(file)) continue;
            NSInteger score = [stem isEqualToString:@"poster"] ? 100 : [stem isEqualToString:@"folder"] ? 90 : [stem isEqualToString:@"cover"] ? 80 : [stem isEqualToString:@"fanart"] ? 70 : ([stem containsString:@"keyvisual"] || [stem containsString:@"主视觉"] || [stem containsString:@"主视图"]) ? 95 : 0;
            if (score > bestScore) {
                CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)file, NULL);
                NSDictionary *info = source ? CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL)) : nil;
                if (source) CFRelease(source);
                if ([info[(id)kCGImagePropertyPixelWidth] integerValue] >= 120 && [info[(id)kCGImagePropertyPixelHeight] integerValue] >= 120) { best = file; bestScore = score; }
            }
        }
        if (best) {
            // Cache a copy so the series visual also works when archived CDs are
            // played after the original external disk has been disconnected.
            NSURL *directory = [self.rootURL URLByAppendingPathComponent:@".series-artwork" isDirectory:YES];
            [fm createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
            NSURL *copy = [directory URLByAppendingPathComponent:[[CDLHash(best.path) stringByAppendingString:@"-local"] stringByAppendingPathExtension:best.pathExtension]];
            if (![fm fileExistsAtPath:copy.path]) [fm copyItemAtURL:best toURL:copy error:nil];
            return [fm fileExistsAtPath:copy.path] ? copy.path : best.path;
        }
        if (hasVideo) break;
    }
    return @"";
}
/// The series' key visual from Bangumi (the poster path ships in the local anime index), cached per series.
- (NSString *)bangumiSeriesArtworkForAlbum:(NSDictionary *)album {
    NSNumber *subject = [album[@"subjectID"] isKindOfClass:NSNumber.class] ? album[@"subjectID"] : nil;
    if (!subject.integerValue) subject = [self localAnimeForTitle:CDLString(album[@"animeTitle"])][@"subjectID"];
    [self nameEntries];
    NSString *poster = subject ? self.posters[subject] : nil;
    if (!poster.length) return @"";
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *directory = [self.rootURL URLByAppendingPathComponent:@".series-artwork" isDirectory:YES];
    [fm createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *cached = [directory URLByAppendingPathComponent:[NSString stringWithFormat:@"bgm-%@.jpg", subject]];
    if (CDLUsableSeriesArtwork(cached.path)) return cached.path;
    NSURL *retry = [directory URLByAppendingPathComponent:[NSString stringWithFormat:@"bgm-%@.retry", subject]];
    NSDate *lastAttempt = [fm attributesOfItemAtPath:retry.path error:nil][NSFileModificationDate];
    if (lastAttempt && -lastAttempt.timeIntervalSinceNow < 6 * 3600) return @"";
    NSData *image = CDLNetworkData([@"https://lain.bgm.tv/pic/cover/l/" stringByAppendingString:poster]);
    if (image.length && [image writeToURL:cached options:NSDataWritingAtomic error:nil] && CDLUsableSeriesArtwork(cached.path)) return cached.path;
    [fm removeItemAtURL:cached error:nil];
    [@"retry later" writeToURL:retry atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return @"";
}
/// Only artwork found online by an earlier version (Wikipedia page images, often logos) may be replaced.
static BOOL CDLReplaceableSeriesArtwork(NSString *path) {
    NSString *name = path.lastPathComponent;
    return [path containsString:@"/.series-artwork/"] && [name hasSuffix:@".image"];
}
- (NSString *)wikiSeriesArtworkForAlbum:(NSDictionary *)album {
    NSString *key = CDLString(album[@"animeKey"]), *title = CDLString(album[@"animeTitle"]);
    if (!key.length || [key isEqualToString:@"unmatched"] || title.length < 2) return @"";
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *directory = [self.rootURL URLByAppendingPathComponent:@".series-artwork" isDirectory:YES];
    [fm createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *cached = [directory URLByAppendingPathComponent:[CDLHash(key) stringByAppendingString:@".image"]];
    if (CDLUsableSeriesArtwork(cached.path)) return cached.path;
    NSURL *retry = [directory URLByAppendingPathComponent:[CDLHash(key) stringByAppendingString:@".retry-v2"]];
    NSDate *lastAttempt = [fm attributesOfItemAtPath:retry.path error:nil][NSFileModificationDate];
    if (lastAttempt && -lastAttempt.timeIntervalSinceNow < 24 * 3600) return @"";
    NSString *japanese = title, *english = title;
    for (NSDictionary *entry in self.nameEntries) if ([entry[@"subjectID"] isEqual:album[@"subjectID"]]) { japanese = entry[@"sourceTitle"] ?: title; break; }
    for (NSDictionary *entry in self.nameEntries) if ([entry[@"subjectID"] isEqual:album[@"subjectID"]] && [CDLString(entry[@"sourceAlias"]) canBeConvertedToEncoding:NSASCIIStringEncoding]) { english = entry[@"sourceAlias"]; break; }
    for (NSString *language in @[@"zh", @"ja", @"en"]) {
        NSString *base = [NSString stringWithFormat:@"https://%@.wikipedia.org/w/api.php", language];
        NSString *query = [language isEqualToString:@"zh"] ? title : [language isEqualToString:@"ja"] ? japanese : english;
        NSData *data = CDLNetworkData(CDLQueryURL(base, @{@"action":@"query",@"format":@"json",@"redirects":@"1",@"titles":query,@"prop":@"pageimages",@"piprop":@"thumbnail",@"pithumbsize":@"900",@"pilicense":@"any"}));
        NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSDictionary *pages = [json[@"query"] isKindOfClass:NSDictionary.class] ? json[@"query"][@"pages"] : nil;
        if (![pages isKindOfClass:NSDictionary.class]) continue;
        for (NSDictionary *page in pages.allValues) {
            NSString *address = [page[@"thumbnail"] isKindOfClass:NSDictionary.class] ? CDLString(page[@"thumbnail"][@"source"]) : @"";
            if (!address.length || [address.lowercaseString containsString:@"logo"] || [address.lowercaseString containsString:@"wordmark"]) continue;
            NSData *image = CDLNetworkData(address); if (!image.length) continue;
            CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)image, NULL);
            NSDictionary *info = source ? CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source,0,NULL)) : nil;
            if (source) CFRelease(source);
            double width = [info[(id)kCGImagePropertyPixelWidth] doubleValue], height = [info[(id)kCGImagePropertyPixelHeight] doubleValue];
            if (width < 120 || height < 120 || width/height < .5 || width/height > 1.9) continue;
            if ([image writeToURL:cached options:NSDataWritingAtomic error:nil]) return cached.path;
        }
    }
    [@"retry tomorrow" writeToURL:retry atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return @"";
}
- (void)resolveSeriesArtwork:(void (^)(NSUInteger, NSUInteger))progress completion:(void (^)(NSUInteger))completion {
    dispatch_async(self.queue, ^{
        NSMutableDictionary *groups = [NSMutableDictionary new];
        // CDs without a sleeve of their own: the parent folder's key visual (found while scanning) wins,
        // then the series poster from Bangumi, then Wikipedia's page image. A sleeve on a disk that does not
        // answer counts as there: nothing is decided about a CD that cannot be looked at.
        BOOL (^wants)(NSDictionary *) = ^BOOL(NSDictionary *album) {
            if (CDLExists(CDLString(album[@"coverPath"]), YES)) return NO;
            NSString *series = CDLString(album[@"seriesCoverPath"]);
            return !CDLUsableSeriesArtwork(series) || CDLReplaceableSeriesArtwork(series);
        };
        for (NSDictionary *album in self.albums) {
            NSString *key = CDLString(album[@"animeKey"]);
            if (key.length && wants(album) && (!groups[key] || [album[@"subjectID"] integerValue])) groups[key] = album;
        }
        NSMutableDictionary *posters = [NSMutableDictionary new]; NSUInteger done = 0;
        for (NSString *key in groups) {
            NSDictionary *album = groups[key];
            NSString *poster = [self bangumiSeriesArtworkForAlbum:album];
            if (!poster.length && !CDLUsableSeriesArtwork(CDLString(album[@"seriesCoverPath"]))) poster = [self wikiSeriesArtworkForAlbum:album];
            if (poster.length) posters[key] = poster;
            done++; if (progress) dispatch_async(dispatch_get_main_queue(), ^{ progress(done, groups.count); });
        }
        NSMutableArray *updated = [NSMutableArray new]; NSUInteger repaired = 0;
        for (NSDictionary *album in self.albums) {
            NSMutableDictionary *item = [album mutableCopy]; NSString *poster = posters[CDLString(album[@"animeKey"])];
            if (poster.length && wants(album) && ![poster isEqualToString:CDLString(album[@"seriesCoverPath"])]) { item[@"seriesCoverPath"] = poster; repaired++; }
            [updated addObject:item];
        }
        [self saveAlbums:updated];
        dispatch_sync(dispatch_get_main_queue(), ^{ self.albums = updated; if (completion) completion(repaired); });
    });
}

- (NSDictionary *)recordForFolder:(NSURL *)folder scanRoot:(NSURL *)root files:(NSArray<NSURL *> *)files {
    NSString *album = CDLClean(folder.lastPathComponent);
    NSUInteger count = 0, cueCount = 0;
    NSString *cueArtwork = @"";
    for (NSURL *file in files) {
        NSString *ext = file.pathExtension.lowercaseString;
        if ([@[@"wav",@"aiff",@"aif",@"mp3",@"m4a",@"flac",@"ogg"] containsObject:ext]) count++;
        if ([ext isEqualToString:@"cue"]) {
            NSString *text = [NSString stringWithContentsOfURL:file encoding:NSUTF8StringEncoding error:nil];
            if (!text) text = [NSString stringWithContentsOfURL:file encoding:NSShiftJISStringEncoding error:nil];
            NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"(?m)^TITLE\\s+\\\"([^\\\"]+)\\\"" options:0 error:nil];
            NSTextCheckingResult *match = [regex firstMatchInString:text ?: @"" options:0 range:NSMakeRange(0, text.length)];
            if (match && match.numberOfRanges > 1) album = [text substringWithRange:[match rangeAtIndex:1]];
            NSRegularExpression *tracks = [NSRegularExpression regularExpressionWithPattern:@"(?m)^\\s*TRACK\\s+\\d+\\s+AUDIO\\b" options:NSRegularExpressionCaseInsensitive error:nil];
            cueCount = MAX(cueCount, [tracks numberOfMatchesInString:text ?: @"" options:0 range:NSMakeRange(0, text.length)]);
            NSRegularExpression *art = [NSRegularExpression regularExpressionWithPattern:@"(?im)^\\s*REM\\s+COVER(?:FILE)?\\s+(?:\\\"([^\\\"]+)\\\"|([^\\r\\n]+))" options:0 error:nil];
            NSTextCheckingResult *artMatch = [art firstMatchInString:text ?: @"" options:0 range:NSMakeRange(0, text.length)];
            if (artMatch) { NSRange range = [artMatch rangeAtIndex:[artMatch rangeAtIndex:1].location != NSNotFound ? 1 : 2]; if (range.location != NSNotFound) cueArtwork = [[[text substringWithRange:range] stringByReplacingOccurrencesOfString:@"\\" withString:@"/"] lastPathComponent]; }
        }
    }
    count = MAX(count, cueCount);
    NSData *metadata = [NSData dataWithContentsOfURL:[folder URLByAppendingPathComponent:@"album.json"]];
    NSDictionary *json = metadata ? [NSJSONSerialization JSONObjectWithData:metadata options:0 error:nil] : nil;
    if (CDLString(json[@"title"]).length) album = json[@"title"];
    NSDictionary *anime = [self animeForAlbumFolder:folder scanRoot:root];
    NSString *coverPath = [self artworkForFolder:folder files:files cueArtwork:cueArtwork];
    return @{@"id":CDLHash(folder.URLByStandardizingPath.path), @"sourcePath":folder.URLByStandardizingPath.path,
             @"album":album.length ? album : folder.lastPathComponent, @"animeKey":anime[@"key"], @"animeTitle":anime[@"title"],
             @"subjectID":anime[@"subjectID"], @"basis":anime[@"basis"], @"audioFiles":@(count), @"coverPath":coverPath, @"seriesCoverPath":[self localSeriesArtworkForFolder:folder], @"artworkIndexed":@YES};
}
- (void)saveAlbums:(NSArray<NSDictionary *> *)albums {
    NSDictionary *json = @{@"version":@1, @"albums":albums};
    NSData *data = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
    [data writeToURL:[self.rootURL URLByAppendingPathComponent:@"Library.json"] options:NSDataWritingAtomic error:nil];
}
- (void)scanFolder:(NSURL *)folder progress:(void (^)(NSUInteger))progress completion:(void (^)(NSUInteger, NSError * _Nullable))completion {
    NSURL *scanRoot = folder.URLByStandardizingPath;
    NSArray *existing = self.albums;
    dispatch_async(self.queue, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        // A disk that does not answer ends the scan with an error naming it, instead of a scan that never returns.
        void (^silent)(void) = ^{
            NSString *name = CDVolumeName(CDVolumeRoot(scanRoot.path) ?: scanRoot.path);
            NSError *error = [NSError errorWithDomain:@"CDLibrary" code:2 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"连接不上「%@」：硬盘没有响应或已断开", name], @"CDVolumeRoot":CDVolumeRoot(scanRoot.path) ?: scanRoot.path}];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(0, error); });
        };
        BOOL answered = YES;
        NSNumber *isDirectory = CDVolumeRun(scanRoot.path, CDLDiskPatience, ^id{
            NSNumber *directory = nil; [scanRoot getResourceValue:&directory forKey:NSURLIsDirectoryKey error:nil]; return directory;
        }, &answered);
        if (!answered) { silent(); return; }
        if (!isDirectory.boolValue) { dispatch_async(dispatch_get_main_queue(), ^{ completion(0, [NSError errorWithDomain:@"CDLibrary" code:1 userInfo:@{NSLocalizedDescriptionKey:@"所选文件夹不可读取"}]); }); return; }
        NSSet<NSString *> *relevant = [NSSet setWithArray:@[@"wav", @"aiff", @"aif", @"mp3", @"m4a", @"flac", @"ogg", @"cue", @"jpg", @"jpeg", @"png", @"webp", @"heic"]];
        NSString *libraryPath = [self.rootURL.path stringByResolvingSymlinksInPath];
        NSString *legacyLibraryPath = [CDLLegacyRootURL().path stringByResolvingSymlinksInPath];
        NSString *scanPath = [scanRoot.path stringByResolvingSymlinksInPath];
        // Walking the tree is quick on a disk that answers; a few minutes without finishing means it stopped.
        NSDictionary<NSString *, NSMutableArray<NSURL *> *> *folders = CDVolumeRun(scanRoot.path, 240, ^id{
            NSMutableDictionary<NSString *, NSMutableArray<NSURL *> *> *folders = [NSMutableDictionary new];
            NSDirectoryEnumerator *walker = [fm enumeratorAtURL:scanRoot includingPropertiesForKeys:@[NSURLIsDirectoryKey,NSURLIsSymbolicLinkKey] options:NSDirectoryEnumerationSkipsHiddenFiles | NSDirectoryEnumerationSkipsPackageDescendants errorHandler:^BOOL(NSURL *url, NSError *error) { return YES; }];
            for (NSURL *url in walker) {
                NSNumber *directory = nil, *symbolic = nil;
                [url getResourceValue:&directory forKey:NSURLIsDirectoryKey error:nil];
                [url getResourceValue:&symbolic forKey:NSURLIsSymbolicLinkKey error:nil];
                NSString *resolved = [url.path stringByResolvingSymlinksInPath];
                BOOL insideLibrary = [resolved isEqualToString:libraryPath] || [resolved hasPrefix:[libraryPath stringByAppendingString:@"/"]];
                BOOL insideLegacy = [resolved isEqualToString:legacyLibraryPath] || [resolved hasPrefix:[legacyLibraryPath stringByAppendingString:@"/"]];
                BOOL scanningLibrary = [scanPath isEqualToString:libraryPath] || [scanPath hasPrefix:[libraryPath stringByAppendingString:@"/"]];
                BOOL scanningLegacy = [scanPath isEqualToString:legacyLibraryPath] || [scanPath hasPrefix:[legacyLibraryPath stringByAppendingString:@"/"]];
                if (symbolic.boolValue || (insideLibrary && !scanningLibrary) || (insideLegacy && !scanningLegacy)) { if (directory.boolValue) [walker skipDescendants]; continue; }
                if (directory.boolValue) continue;
                if (![relevant containsObject:url.pathExtension.lowercaseString]) continue;
                NSString *key = url.URLByDeletingLastPathComponent.URLByStandardizingPath.path;
                if (!folders[key]) folders[key] = [NSMutableArray new];
                [folders[key] addObject:url];
            }
            return folders;
        }, &answered);
        if (!answered) { silent(); return; }
        NSMutableDictionary<NSString *, NSDictionary *> *merged = [NSMutableDictionary new];
        for (NSDictionary *item in existing) if (CDLString(item[@"sourcePath"]).length) merged[item[@"sourcePath"]] = item;
        NSUInteger added = 0;
        for (NSString *path in [[folders allKeys] sortedArrayUsingSelector:@selector(localizedStandardCompare:)]) {
            NSArray<NSURL *> *files = folders[path];
            BOOL audio = NO;
            for (NSURL *file in files) if ([@[@"wav",@"aiff",@"aif",@"mp3",@"m4a",@"flac",@"ogg"] containsObject:file.pathExtension.lowercaseString]) { audio = YES; break; }
            if (!audio) continue;
            NSDictionary *record = CDVolumeRun(path, CDLDiskPatience, ^id{ return [self recordForFolder:[NSURL fileURLWithPath:path isDirectory:YES] scanRoot:scanRoot files:files]; }, &answered);
            if (!answered) { silent(); return; }
            NSMutableDictionary *updated = [record mutableCopy];
            NSDictionary *old = merged[path];
            if (CDLString(old[@"libraryPath"]).length) updated[@"libraryPath"] = old[@"libraryPath"];
            else if ([[path stringByResolvingSymlinksInPath] hasPrefix:[libraryPath stringByAppendingString:@"/"]]) updated[@"libraryPath"] = path;
            if (CDLExists(CDLString(old[@"seriesCoverPath"]), NO)) updated[@"seriesCoverPath"] = old[@"seriesCoverPath"];
            if (CDLString(old[@"artworkSource"]).length && CDLExists(CDLString(old[@"coverPath"]), NO)) { updated[@"coverPath"] = old[@"coverPath"]; updated[@"artworkSource"] = old[@"artworkSource"]; }
            if (!old) added++;
            merged[path] = updated;
            NSUInteger found = merged.count;
            if (progress && found % 20 == 0) dispatch_async(dispatch_get_main_queue(), ^{ progress(found); });
        }
        NSArray *result = [[merged allValues] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            NSComparisonResult s = [CDLString(a[@"animeTitle"]) localizedStandardCompare:CDLString(b[@"animeTitle"])];
            return s == NSOrderedSame ? [CDLString(a[@"album"]) localizedStandardCompare:CDLString(b[@"album"])]:s;
        }];
        [self saveAlbums:result];
        dispatch_async(dispatch_get_main_queue(), ^{ self.albums = result; completion(added, nil); });
    });
}
/// One CD of -refreshMissingArtwork: {album: the updated record, repaired: how many pictures were found}.
- (NSDictionary *)artworkRefreshedAlbum:(NSDictionary *)album {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSUInteger repaired = 0;
    NSMutableDictionary *item = [album mutableCopy];
    NSString *current = CDLString(album[@"coverPath"]);
    NSString *folderPath = CDLString(album[@"sourcePath"]);
    if (![fm fileExistsAtPath:folderPath]) folderPath = CDLString(album[@"libraryPath"]);
    NSURL *folder = [NSURL fileURLWithPath:folderPath isDirectory:YES];
    if (![album[@"subjectID"] integerValue] && folderPath.length && [fm fileExistsAtPath:folderPath]) {
        // The original scan root is not stored; three levels up covers "Series/CDs/Album" and "Series/Extra/CD1".
        NSURL *root = folder.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent;
        NSDictionary *anime = [self animeForAlbumFolder:folder scanRoot:root.path.length > 1 ? root : folder.URLByDeletingLastPathComponent];
        if ([anime[@"subjectID"] integerValue]) {
            item[@"animeKey"] = anime[@"key"]; item[@"animeTitle"] = anime[@"title"];
            item[@"subjectID"] = anime[@"subjectID"]; item[@"basis"] = anime[@"basis"];
        }
    }
    if (!CDLUsableSeriesArtwork(CDLString(item[@"seriesCoverPath"]))) [item removeObjectForKey:@"seriesCoverPath"];
    if (!CDLUsableSeriesArtwork(CDLString(item[@"seriesCoverPath"])) && ![fm fileExistsAtPath:current] && folderPath.length) {
        NSString *poster = [self localSeriesArtworkForFolder:folder];
        if (poster.length) { item[@"seriesCoverPath"] = poster; repaired++; }
    }
    if (current.length && [fm fileExistsAtPath:current]) {
        item[@"artworkIndexed"] = @YES;
        return @{@"album":item, @"repaired":@(repaired)};
    }
    if ([album[@"artworkIndexed"] boolValue]) return @{@"album":item, @"repaired":@(repaired)};
    NSArray<NSURL *> *files = folderPath.length ? [fm contentsOfDirectoryAtURL:folder includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] : nil;
    if (files.count) {
        NSDictionary *fresh = [self recordForFolder:folder scanRoot:folder.URLByDeletingLastPathComponent files:files];
        NSString *found = CDLString(fresh[@"coverPath"]);
        if (found.length && ![found isEqualToString:current]) { item[@"coverPath"] = found; [item removeObjectForKey:@"artworkSource"]; repaired++; }
        else if (!found.length && current.length) item[@"coverPath"] = @"";
        item[@"audioFiles"] = fresh[@"audioFiles"] ?: album[@"audioFiles"] ?: @0;
    }
    item[@"artworkIndexed"] = @YES;
    return @{@"album":item, @"repaired":@(repaired)};
}
- (void)refreshMissingArtwork:(void (^)(NSUInteger))completion {
    dispatch_async(self.queue, ^{
        NSMutableArray<NSDictionary *> *updated = [NSMutableArray new];
        NSUInteger repaired = 0;
        for (NSDictionary *album in self.albums) {
            // Each CD is looked at on its own disk's terms: one on a disk that does not answer stays as it is.
            NSString *source = CDLString(album[@"sourcePath"]), *archived = CDLString(album[@"libraryPath"]);
            NSString *disk = CDVolumeIsSilent(source) && archived.length ? archived : source;
            NSDictionary *outcome = CDVolumeRun(disk, CDLDiskPatience, ^id{ return [self artworkRefreshedAlbum:album]; }, NULL);
            [updated addObject:outcome[@"album"] ?: album];
            repaired += [outcome[@"repaired"] unsignedIntegerValue];
        }
        [self saveAlbums:updated];
        dispatch_sync(dispatch_get_main_queue(), ^{ self.albums = updated; if (completion) completion(repaired); });
    });
}
- (void)rememberArtworkAtPath:(NSString *)path forFolder:(NSString *)folder completion:(void (^)(void))completion {
    if (!path.length || !folder.length || ![NSFileManager.defaultManager fileExistsAtPath:path]) return;
    NSString *canonical = [NSURL fileURLWithPath:folder isDirectory:YES].URLByStandardizingPath.path;
    dispatch_async(self.queue, ^{
        NSMutableArray *updated = [NSMutableArray new]; BOOL changed = NO;
        for (NSDictionary *album in self.albums) {
            if ([CDLString(album[@"sourcePath"]) isEqualToString:canonical] || [CDLString(album[@"libraryPath"]) isEqualToString:canonical]) {
                NSMutableDictionary *item = [album mutableCopy];
                item[@"coverPath"] = path; item[@"artworkSource"] = @"selected"; item[@"artworkIndexed"] = @YES;
                [updated addObject:item]; changed = YES;
            } else [updated addObject:album];
        }
        if (changed) [self saveAlbums:updated];
        dispatch_sync(dispatch_get_main_queue(), ^{ if (changed) self.albums = updated; if (completion) completion(); });
    });
}
/// Looks at the disk: call it off the main thread.
- (NSURL *)playableURLForAlbum:(NSDictionary *)album {
    NSString *archived = CDLString(album[@"libraryPath"]);
    if (archived.length && [[NSFileManager defaultManager] fileExistsAtPath:archived]) return [NSURL fileURLWithPath:archived isDirectory:YES];
    return [NSURL fileURLWithPath:CDLString(album[@"sourcePath"]) isDirectory:YES];
}
- (void)archiveAlbums:(NSArray<NSDictionary *> *)albums toFolder:(NSURL *)folder progress:(void (^)(NSUInteger, NSUInteger))progress completion:(void (^)(NSUInteger, NSArray<NSString *> *))completion {
    NSArray *targets = [albums copy], *existing = self.albums;
    NSURL *destinationRoot = folder.URLByStandardizingPath;
    dispatch_async(self.queue, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSMutableDictionary<NSString *, NSMutableDictionary *> *records = [NSMutableDictionary new];
        for (NSDictionary *item in existing) records[item[@"sourcePath"]] = [item mutableCopy];
        NSMutableArray<NSString *> *errors = [NSMutableArray new]; NSUInteger copied = 0, done = 0;
        for (NSDictionary *item in targets) {
            NSString *source = CDLString(item[@"sourcePath"]), *archive = CDLString(item[@"libraryPath"]);
            done++;
            NSString *series = CDLSafeName(CDLString(item[@"animeTitle"]));
            NSString *album = [NSString stringWithFormat:@"%@ · %@", CDLSafeName(CDLString(item[@"album"])), CDLString(item[@"id"])];
            NSURL *dest = [[destinationRoot URLByAppendingPathComponent:series isDirectory:YES] URLByAppendingPathComponent:album isDirectory:YES];
            NSString *resolvedSource = [source stringByResolvingSymlinksInPath];
            NSString *resolvedDestination = [dest.path stringByResolvingSymlinksInPath];
            if ([resolvedDestination isEqualToString:resolvedSource] || [resolvedDestination hasPrefix:[resolvedSource stringByAppendingString:@"/"]]) {
                [errors addObject:[NSString stringWithFormat:@"%@: 归档位置不能放在这张 CD 的原文件夹内", item[@"album"]]];
                if (progress) dispatch_async(dispatch_get_main_queue(), ^{ progress(done, targets.count); });
                continue;
            }
            // Both disks must answer first; one that does not is named in the errors and this CD is left for later.
            BOOL reachable = YES;
            CDVolumeRun(source, CDLDiskPatience, ^id{ return @([fm fileExistsAtPath:source]); }, &reachable);
            if (reachable) CDVolumeRun(destinationRoot.path, CDLDiskPatience, ^id{ return @([fm fileExistsAtPath:destinationRoot.path]); }, &reachable);
            if (!reachable) {
                NSString *disk = CDVolumeRoot(CDVolumeIsSilent(source) ? source : destinationRoot.path);
                [errors addObject:[NSString stringWithFormat:@"%@: 连接不上「%@」", item[@"album"], CDVolumeName(disk ?: source)]];
                if (progress) dispatch_async(dispatch_get_main_queue(), ^{ progress(done, targets.count); });
                continue;
            }
            if ([archive isEqualToString:dest.path] && [fm fileExistsAtPath:archive]) { if (progress) dispatch_async(dispatch_get_main_queue(), ^{ progress(done, targets.count); }); continue; }
            NSURL *temp = [dest.URLByDeletingLastPathComponent URLByAppendingPathComponent:[album stringByAppendingString:@".partial"] isDirectory:YES];
            NSError *error = nil;
            [fm createDirectoryAtURL:temp.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&error];
            if (!error && ![fm fileExistsAtPath:dest.path]) {
                [fm removeItemAtURL:temp error:nil];
                [fm createDirectoryAtURL:temp withIntermediateDirectories:YES attributes:nil error:&error];
                NSArray<NSURL *> *files = [fm contentsOfDirectoryAtURL:[NSURL fileURLWithPath:source isDirectory:YES] includingPropertiesForKeys:@[NSURLIsSymbolicLinkKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:&error];
                for (NSURL *file in files) {
                    if (error) break;
                    NSNumber *symbolic = nil; [file getResourceValue:&symbolic forKey:NSURLIsSymbolicLinkKey error:nil];
                    if (symbolic.boolValue || [@[@"mkv",@"mp4",@"avi",@"m2ts",@"ts",@"iso"] containsObject:file.pathExtension.lowercaseString]) continue;
                    [fm copyItemAtURL:file toURL:[temp URLByAppendingPathComponent:file.lastPathComponent] error:&error];
                }
                if (!error) [fm moveItemAtURL:temp toURL:dest error:&error];
                if (error) [fm removeItemAtURL:temp error:nil];
            }
            if (error) [errors addObject:[NSString stringWithFormat:@"%@: %@", item[@"album"], error.localizedDescription]];
            else if ([fm fileExistsAtPath:dest.path]) { records[source][@"libraryPath"] = dest.path; copied++; }
            if (progress) dispatch_async(dispatch_get_main_queue(), ^{ progress(done, targets.count); });
        }
        NSArray *result = [[records allValues] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [CDLString(a[@"animeTitle"]) localizedStandardCompare:CDLString(b[@"animeTitle"])]; }];
        [self saveAlbums:result];
        dispatch_async(dispatch_get_main_queue(), ^{ self.albums = result; completion(copied, errors); });
    });
}
@end
