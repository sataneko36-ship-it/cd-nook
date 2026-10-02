#import "CDCoverSearch.h"
#import <CommonCrypto/CommonDigest.h>

static NSString *CDString(id value) { return [value isKindOfClass:NSString.class]?value:@""; }
static NSArray *CDArray(id value) { return [value isKindOfClass:NSArray.class]?value:@[]; }
static NSDictionary *CDDict(id value) { return [value isKindOfClass:NSDictionary.class]?value:@{}; }
static NSString *CDURL(NSString *base, NSDictionary *params) {
    NSURLComponents *u=[NSURLComponents componentsWithString:base]; NSMutableArray *items=[NSMutableArray new];
    for (NSString *k in params) [items addObject:[NSURLQueryItem queryItemWithName:k value:[params[k] description]]];
    u.queryItems=items; return u.URL.absoluteString;
}
static NSString *CDHTMLText(NSString *html) {
    NSRegularExpression *tags=[NSRegularExpression regularExpressionWithPattern:@"<[^>]*>" options:0 error:nil];
    return [tags stringByReplacingMatchesInString:html options:0 range:NSMakeRange(0,html.length) withTemplate:@" "];
}
@interface CDCoverSearch ()
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, copy) NSString *album, *artist, *catalog, *series;
@property (nonatomic, strong) NSArray<NSString *> *tracks, *queries;
@property (nonatomic, strong) NSMutableSet *urls;
@property (nonatomic, strong) NSMutableArray *notes;
@property (nonatomic) NSInteger accepted;
@property (nonatomic) NSInteger albumMatches;
@property (nonatomic) CFTimeInterval lastMB;
@end
@implementation CDCoverSearch
+ (NSString *)normalized:(NSString *)text {
    text=[[CDString(text) precomposedStringWithCanonicalMapping] stringByFoldingWithOptions:NSDiacriticInsensitiveSearch|NSWidthInsensitiveSearch|NSCaseInsensitiveSearch locale:[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]];
    return [[text componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet] componentsJoinedByString:@""];
}
- (void)cancel { self.cancelled=YES; [self.session invalidateAndCancel]; }
- (NSData *)dataAt:(NSString *)url {
    if (self.cancelled || ![url hasPrefix:@"https://"]) return nil;
    NSMutableURLRequest *r=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    if (!r.URL) return nil;
    r.timeoutInterval=12; [r setValue:@"CDGlass/0.6 (personal macOS CD player; cover metadata lookup)" forHTTPHeaderField:@"User-Agent"];
    __block NSData *result=nil; dispatch_semaphore_t done=dispatch_semaphore_create(0);
    NSURLSessionDataTask *task=[self.session dataTaskWithRequest:r completionHandler:^(NSData *data,NSURLResponse *response,NSError *error) {
        NSInteger status=[(NSHTTPURLResponse *)response statusCode];
        if (!error && status>=200 && status<300 && data.length<24*1024*1024) result=data;
        dispatch_semaphore_signal(done);
    }]; [task resume];
    if (dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,14*NSEC_PER_SEC))) { [task cancel]; return nil; }
    return self.cancelled?nil:result;
}
- (NSDictionary *)jsonAt:(NSString *)url {
    NSData *data=[self dataAt:url]; return data?CDDict([NSJSONSerialization JSONObjectWithData:data options:0 error:nil]):@{};
}
- (NSDictionary *)musicBrainz:(NSString *)path params:(NSDictionary *)params {
    // MusicBrainz requires at most one request per second per client.
    NSTimeInterval delay=1.1-(CFAbsoluteTimeGetCurrent()-self.lastMB);
    if (delay>0) [NSThread sleepForTimeInterval:delay];
    self.lastMB=CFAbsoluteTimeGetCurrent();
    NSMutableDictionary *p=[params mutableCopy]; p[@"fmt"]=@"json";
    return [self jsonAt:CDURL([@"https://musicbrainz.org/ws/2/" stringByAppendingString:path],p)];
}
- (void)note:(NSString *)text { @synchronized(self) { [self.notes addObject:text]; } }
- (void)emitURL:(NSString *)url title:(NSString *)title source:(NSString *)source page:(NSString *)page score:(NSInteger)score reason:(NSString *)reason {
    if (self.cancelled || !url.length) return;
    if ([url hasPrefix:@"http://coverartarchive.org/"] || [url hasPrefix:@"http://archive.org/"]) url=[@"https://" stringByAppendingString:[url substringFromIndex:7]];
    @synchronized(self) { if ([self.urls containsObject:url] || self.urls.count>=40) return; [self.urls addObject:url]; }
    NSData *data=[self dataAt:url]; if (!data) return;
    NSBitmapImageRep *rep=[NSBitmapImageRep imageRepWithData:data];
    if (!rep || rep.pixelsWide<160 || rep.pixelsHigh<160) return;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
    NSMutableString *key=[NSMutableString new]; for(int i=0;i<CC_SHA256_DIGEST_LENGTH;i++) [key appendFormat:@"%02x",digest[i]];
    NSDictionary *candidate=@{@"id":key,@"title":title?:@"封面",@"source":source,@"page":page?:@"",@"imageURL":url,@"score":@(score),@"reason":reason?:@"",@"width":@(rep.pixelsWide),@"height":@(rep.pixelsHigh)};
    @synchronized(self) { self.accepted++; if (score >= 55) self.albumMatches++; }
    dispatch_async(dispatch_get_main_queue(), ^{ if (!self.cancelled && self.onCandidate) self.onCandidate(candidate,data); });
}
- (void)startWithAlbum:(NSString *)album artist:(NSString *)artist catalog:(NSString *)catalog tracks:(NSArray<NSString *> *)tracks series:(NSString *)series {
    self.album=album?:@""; self.artist=artist?:@""; self.catalog=catalog?:@""; self.tracks=tracks?:@[]; self.series=series?:@"";
    self.urls=[NSMutableSet new]; self.notes=[NSMutableArray new];
    NSMutableArray *queries=[NSMutableArray new]; NSMutableSet *seen=[NSMutableSet new];
    for (NSString *text in [@[self.album] arrayByAddingObjectsFromArray:self.tracks]) {
        NSString *normalized=[CDCoverSearch normalized:text];
        if (normalized.length<3 || [seen containsObject:normalized] || [normalized containsString:@"instrumental"] || [normalized containsString:@"offvocal"] || [normalized containsString:@"カラオケ"]) continue;
        [queries addObject:text]; [seen addObject:normalized]; if(queries.count==3) break;
    }
    self.queries=queries;
    NSURLSessionConfiguration *config=[NSURLSessionConfiguration ephemeralSessionConfiguration]; config.timeoutIntervalForRequest=12; config.timeoutIntervalForResource=18; config.HTTPMaximumConnectionsPerHost=2;
    self.session=[NSURLSession sessionWithConfiguration:config];
    dispatch_group_t group=dispatch_group_create();
    dispatch_queue_t queue=dispatch_get_global_queue(QOS_CLASS_UTILITY,0);
    dispatch_group_async(group,queue,^{ @autoreleasepool { [self searchMusicBrainz]; } });
    dispatch_group_async(group,queue,^{ @autoreleasepool { [self searchApple]; } });
    dispatch_group_async(group,queue,^{ @autoreleasepool { [self searchMoegirl]; } });
    dispatch_group_async(group,queue,^{ @autoreleasepool { for(NSString *language in @[@"ja",@"zh",@"en"]) { if(self.cancelled) break; [self searchWiki:language]; } } });
    dispatch_group_notify(group,queue,^{
        if (!self.cancelled && self.albumMatches == 0 && [CDCoverSearch normalized:self.series].length >= 4) {
            dispatch_group_t fallback = dispatch_group_create();
            dispatch_group_async(fallback,queue,^{ @autoreleasepool { [self searchSeriesWiki]; } });
            dispatch_group_async(fallback,queue,^{ @autoreleasepool { [self searchSeriesMoegirl]; } });
            dispatch_group_wait(fallback,DISPATCH_TIME_FOREVER);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.cancelled && self.onFinish) self.onFinish([NSString stringWithFormat:@"检索完成 · %ld 张候选%@",(long)self.accepted,self.notes.count?[@" · " stringByAppendingString:[self.notes componentsJoinedByString:@"；"]]:@""]);
            [self.session finishTasksAndInvalidate];
        });
    });
}
- (NSInteger)trackScore:(NSArray<NSString *> *)names {
    NSInteger matches=0,ordered=0;
    NSMutableSet *set=[NSMutableSet new]; for(NSString *name in names) [set addObject:[CDCoverSearch normalized:name]];
    for(NSUInteger i=0;i<self.tracks.count;i++) {
        NSString *name=[CDCoverSearch normalized:self.tracks[i]];
        if(name.length<3) continue;
        if([set containsObject:name]) matches++;
        if(i<names.count && [name isEqualToString:[CDCoverSearch normalized:names[i]]]) ordered++;
    }
    return MIN(40,matches*15+ordered*5)+(names.count==self.tracks.count?10:0);
}
- (BOOL)titleMatches:(NSString *)title {
    NSString *a=[CDCoverSearch normalized:self.album], *b=[CDCoverSearch normalized:title];
    return a.length>=3 && b.length>=3 && ([a containsString:b] || [b containsString:a]);
}
- (void)searchMusicBrainz {
    NSMutableArray *releases=[NSMutableArray new]; NSMutableSet *ids=[NSMutableSet new];
    NSString *(^escape)(NSString *)=^NSString *(NSString *x){return [[x stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"] stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];};
    NSMutableArray *queries=[NSMutableArray new];
    if(self.catalog.length) [queries addObject:[NSString stringWithFormat:@"catno:\"%@\"",escape(self.catalog)]];
    if(self.album.length) [queries addObject:[NSString stringWithFormat:@"release:\"%@\"",escape(self.album)]];
    for(NSString *query in queries) {
        NSDictionary *json=[self musicBrainz:@"release/" params:@{@"query":query,@"limit":@"5"}];
        for(NSDictionary *r in CDArray(json[@"releases"])) {
            NSString *rid=CDString(r[@"id"]); if(!rid.length || [ids containsObject:rid] || [r[@"score"] integerValue]<75) continue;
            NSMutableDictionary *item=[r mutableCopy]; item[@"catalogMatch"]=@([query hasPrefix:@"catno:"]); [releases addObject:item]; [ids addObject:rid];
        }
    }
    // A song can identify a release even when the directory's album title is wrong.
    if(releases.count<2 && self.tracks.count) {
        NSDictionary *json=[self musicBrainz:@"recording/" params:@{@"query":[NSString stringWithFormat:@"recording:\"%@\"",escape(self.tracks[0])],@"limit":@"3"}];
        for(NSDictionary *recording in CDArray(json[@"recordings"])) for(NSDictionary *r in CDArray(recording[@"releases"])) {
            NSString *rid=CDString(r[@"id"]); if(rid.length && ![ids containsObject:rid]) { [releases addObject:r]; [ids addObject:rid]; }
        }
    }
    NSInteger count=0;
    for(NSDictionary *release in releases) {
        if(self.cancelled || count++>=4) break;
        NSString *rid=CDString(release[@"id"]);
        NSDictionary *full=[self musicBrainz:[@"release/" stringByAppendingString:rid] params:@{@"inc":@"recordings+release-groups"}];
        NSInteger best=0; for(NSDictionary *medium in CDArray(full[@"media"])) {
            NSMutableArray *names=[NSMutableArray new]; for(NSDictionary *track in CDArray(medium[@"tracks"])) [names addObject:CDString(track[@"title"]).length?track[@"title"]:CDString(CDDict(track[@"recording"])[@"title"])];
            best=MAX(best,[self trackScore:names]);
        }
        NSInteger score=([release[@"catalogMatch"] boolValue]?85:([self titleMatches:CDString(release[@"title"])]?45:20))+best;
        if(score<55) continue;
        NSString *api=[@"https://coverartarchive.org/release/" stringByAppendingString:rid];
        NSDictionary *art=[self jsonAt:api];
        if(!CDArray(art[@"images"]).count) {
            NSString *gid=CDString(CDDict(full[@"release-group"])[@"id"]);
            if(gid.length) art=[self jsonAt:[@"https://coverartarchive.org/release-group/" stringByAppendingString:gid]];
        }
        NSInteger pages=0;
        for(NSDictionary *image in CDArray(art[@"images"])) {
            if(pages++>=6) break;
            BOOL front=[image[@"front"] boolValue];
            NSString *url=CDString(CDDict(image[@"thumbnails"])[@"1200"]); if(!url.length) url=CDString(image[@"image"]);
            NSString *type=[CDArray(image[@"types"]) componentsJoinedByString:@" / "];
            [self emitURL:url title:[NSString stringWithFormat:@"%@ · %@",CDString(release[@"title"]),type.length?type:@"内页"] source:@"MusicBrainz" page:[@"https://musicbrainz.org/release/" stringByAppendingString:rid] score:front?MIN(100,score):MIN(74,score-15) reason:[NSString stringWithFormat:@"%@ · 曲目结构得分 %ld",[release[@"catalogMatch"] boolValue]?@"唱片编号匹配":@"专辑 / 曲名匹配",(long)best]];
        }
    }
}
- (void)searchApple {
    NSMutableDictionary *collections=[NSMutableDictionary new];
    for(NSString *query in self.queries) {
        if(self.cancelled) return;
        NSDictionary *json=[self jsonAt:CDURL(@"https://itunes.apple.com/search",@{@"term":query,@"media":@"music",@"entity":@"song",@"country":@"jp",@"limit":@"35"})];
        for(NSDictionary *song in CDArray(json[@"results"])) {
            if(!song[@"collectionId"] || !CDString(song[@"artworkUrl100"]).length) continue;
            NSInteger score=[self titleMatches:CDString(song[@"collectionName"])]?45:0;
            NSString *name=[CDCoverSearch normalized:CDString(song[@"trackName"])];
            for(NSString *track in self.tracks) if(name.length>=3 && [name isEqualToString:[CDCoverSearch normalized:track]]) { score+=30; break; }
            if([song[@"trackCount"] integerValue]==self.tracks.count) score+=10;
            NSString *key=[song[@"collectionId"] description];
            if(score>[collections[key][@"score"] integerValue]) { NSMutableDictionary *item=[song mutableCopy]; item[@"score"]=@(score); collections[key]=item; }
        }
    }
    NSArray *ranked=[collections.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [b[@"score"] compare:a[@"score"]];}];
    NSInteger count=0;
    for(NSDictionary *album in ranked) {
        if(count++>=4 || self.cancelled) break;
        NSDictionary *full=[self jsonAt:CDURL(@"https://itunes.apple.com/lookup",@{@"id":[album[@"collectionId"] description],@"entity":@"song",@"country":@"jp",@"limit":@"100"})];
        NSMutableArray *names=[NSMutableArray new]; for(NSDictionary *song in CDArray(full[@"results"])) if([song[@"wrapperType"] isEqual:@"track"]) [names addObject:CDString(song[@"trackName"])];
        NSInteger structure=[self trackScore:names];
        NSInteger score=([self titleMatches:CDString(album[@"collectionName"])]?45:20)+structure;
        if(score<50) continue;
        NSString *url=[CDString(album[@"artworkUrl100"]) stringByReplacingOccurrencesOfString:@"100x100" withString:@"1200x1200"];
        [self emitURL:url title:CDString(album[@"collectionName"]) source:@"Apple Music" page:CDString(album[@"collectionViewUrl"]) score:MIN(95,score) reason:[NSString stringWithFormat:@"核对曲名、顺序及 %lu 首曲目",(unsigned long)names.count]];
    }
}
+ (NSXMLDocument *)document:(NSString *)html {
    NSRegularExpression *scripts=[NSRegularExpression regularExpressionWithPattern:@"<(script|style)\\b[^>]*>[\\s\\S]*?</\\1>" options:NSRegularExpressionCaseInsensitive error:nil];
    html=[scripts stringByReplacingMatchesInString:html options:0 range:NSMakeRange(0,html.length) withTemplate:@""];
    return [[NSXMLDocument alloc] initWithXMLString:html options:NSXMLDocumentTidyHTML|NSXMLNodeLoadExternalEntitiesNever error:nil];
}
+ (NSArray<NSDictionary *> *)moegirlImagesInHTML:(NSString *)html pageURL:(NSString *)pageURL album:(NSString *)album tracks:(NSArray<NSString *> *)tracks {
    NSXMLDocument *doc=[self document:html]; if(!doc) return @[];
    NSArray *roots=[doc nodesForXPath:@"//div[contains(concat(' ',normalize-space(@class),' '),' mw-parser-output ')]" error:nil];
    NSXMLNode *root=roots.firstObject; if(!root) return @[];
    NSString *text=[self normalized:root.stringValue];
    NSInteger matches=0; for(NSString *track in tracks) { NSString *key=[self normalized:track]; if(key.length>=3 && [text containsString:key]) matches++; }
    NSString *albumKey=[self normalized:album]; BOOL albumMatch=albumKey.length>=3 && [text containsString:albumKey];
    if(!matches && !albumMatch) return @[];
    NSMutableArray *results=[NSMutableArray new]; NSMutableSet *seen=[NSMutableSet new];
    NSString *pageTitle=[[[doc nodesForXPath:@"//h1" error:nil] firstObject] stringValue];
    if(!pageTitle.length) pageTitle=[[[[doc nodesForXPath:@"//title" error:nil] firstObject] stringValue] componentsSeparatedByString:@" - 萌娘百科"].firstObject;
    if(!pageTitle.length) pageTitle=album;
    for(NSXMLElement *img in [root nodesForXPath:@".//img" error:nil]) {
        NSInteger width=[[img attributeForName:@"width"].stringValue integerValue], height=[[img attributeForName:@"height"].stringValue integerValue];
        if(width<160 || height<160 || (double)width/MAX(height,1)<.82 || (double)width/MAX(height,1)>1.22) continue;
        NSString *src=[img attributeForName:@"src"].stringValue?:@"";
        if([src.lowercaseString containsString:@".svg"] || [src containsString:@"qrcode"] || [src containsString:@"logo"]) continue;
        NSXMLNode *context=[[img nodesForXPath:@"ancestor::table[contains(@class,'infobox')][1]" error:nil] firstObject];
        if(!context) continue;
        NSString *around=context.stringValue?:@"";
        BOOL cover=NO; for(NSString *word in @[@"封面",@"ジャケット",@"cover",@"Cover",@"专辑",@"專輯",@"CD"]) if([around containsString:word]) { cover=YES; break; }
        if(!cover) continue;
        NSString *contextKey=[self normalized:around];
        BOOL contextMatch=albumKey.length>=3 && [contextKey containsString:albumKey];
        for(NSString *track in tracks) { NSString *key=[self normalized:track]; if(key.length>=3 && [contextKey containsString:key]) contextMatch=YES; }
        if(!contextMatch) continue;
        // Use only image URLs actually provided by the page, preserving watermark / transform parameters.
        NSString *srcset=[img attributeForName:@"srcset"].stringValue;
        if(srcset.length) { NSString *last=[[srcset componentsSeparatedByString:@","] lastObject]; NSString *high=[[[last stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] componentsSeparatedByString:@" "] firstObject]; if(high.length) src=high; }
        src=[[NSURL URLWithString:src relativeToURL:[NSURL URLWithString:pageURL]] absoluteURL].absoluteString;
        if(!src.length || [seen containsObject:src]) continue; [seen addObject:src];
        [results addObject:@{@"url":src,@"title":pageTitle,@"score":@(MIN(85,55+matches*10+(albumMatch?10:0))),@"reason":[NSString stringWithFormat:@"歌曲条目 · 命中 %ld 首曲名 · 封面图片",(long)matches]}];
        if(results.count>=6) break;
    }
    return results;
}
- (void)searchMoegirl {
    NSInteger queryCount=0; NSMutableSet *pages=[NSMutableSet new]; BOOL loaded=NO;
    for(NSString *query in self.queries) {
        if(queryCount++>=2 || self.cancelled) break;
        NSString *search=CDURL(@"https://zh.moegirl.org.cn/index.php",@{@"title":@"Special:Search",@"search":query,@"fulltext":@"1",@"limit":@"5"});
        NSData *data=[self dataAt:search]; NSString *html=data?[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]:nil;
        if(!html.length) continue;
        NSXMLDocument *doc=[CDCoverSearch document:html];
        NSArray *links=[doc nodesForXPath:@"//div[contains(@class,'mw-search-result-heading')]/a[1]" error:nil];
        NSInteger count=0;
        for(NSXMLElement *link in links) {
            if(count++>=2 || self.cancelled) break;
            NSString *href=[link attributeForName:@"href"].stringValue;
            NSString *page=[[NSURL URLWithString:href relativeToURL:[NSURL URLWithString:@"https://zh.moegirl.org.cn/"]] absoluteURL].absoluteString;
            if(!page.length || [pages containsObject:page]) continue; [pages addObject:page];
            NSData *body=[self dataAt:page]; NSString *pageHTML=body?[[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding]:nil;
            if(!pageHTML.length) continue; loaded=YES;
            for(NSDictionary *image in [CDCoverSearch moegirlImagesInHTML:pageHTML pageURL:page album:self.album tracks:self.tracks]) {
                [self emitURL:image[@"url"] title:image[@"title"] source:@"萌娘百科" page:page score:[image[@"score"] integerValue] reason:image[@"reason"]];
            }
        }
    }
    if(!loaded && !self.cancelled) [self note:@"萌娘百科暂未返回可读取条目"];
}
- (void)searchWiki:(NSString *)language {
    if(!self.queries.count) return;
    NSString *base=[NSString stringWithFormat:@"https://%@.wikipedia.org/w/api.php",language];
    NSMutableSet *seen=[NSMutableSet new]; NSInteger pages=0;
    // Search album and a distinctive song. Page text validates track context before image selection.
    for(NSString *query in [self.queries subarrayWithRange:NSMakeRange(0,MIN(2,self.queries.count))]) {
        NSDictionary *search=[self jsonAt:CDURL(base,@{@"action":@"query",@"format":@"json",@"list":@"search",@"srsearch":query,@"srlimit":@"2"})];
        for(NSDictionary *result in CDArray(CDDict(search[@"query"])[@"search"])) {
            NSString *pageid=[result[@"pageid"] description]; if(!pageid || [seen containsObject:pageid] || pages>=3 || self.cancelled) continue;
            [seen addObject:pageid]; pages++;
            NSDictionary *parsed=CDDict([self jsonAt:CDURL(base,@{@"action":@"parse",@"format":@"json",@"pageid":pageid,@"prop":@"text|images"})][@"parse"]);
            NSString *html=CDString(CDDict(parsed[@"text"])[@"*"]); NSString *text=[CDCoverSearch normalized:CDHTMLText(html)];
            NSInteger matched=0; for(NSString *track in self.tracks) { NSString *t=[CDCoverSearch normalized:track]; if(t.length>=3 && [text containsString:t]) matched++; }
            BOOL albumMatch=[self titleMatches:CDString(result[@"title"])];
            if(!matched && !albumMatch) continue;
            NSMutableArray *imageTitles=[NSMutableArray new];
            for(NSString *name in CDArray(parsed[@"images"])) {
                NSString *lower=name.lowercaseString;
                if(!([lower hasSuffix:@".jpg"] || [lower hasSuffix:@".jpeg"] || [lower hasSuffix:@".png"])) continue;
                BOOL cover=NO; for(NSString *word in @[@"cover",@"album",@"single",@"jacket",@"封面",@"ジャケット"]) if([lower containsString:word]) cover=YES;
                // An infobox song/album image may have a name without the word "cover".
                NSRange range=[html rangeOfString:name];
                if(range.location==NSNotFound) range=[html rangeOfString:[name stringByReplacingOccurrencesOfString:@" " withString:@"_"]];
                if(range.location!=NSNotFound) {
                    NSUInteger start=range.location>700?range.location-700:0;
                    NSString *context=[html substringWithRange:NSMakeRange(start,MIN((NSUInteger)1600,html.length-start))];
                    if([context containsString:@"infobox"] && albumMatch) cover=YES;
                }
                if(!cover || [lower containsString:@"logo"] || [lower containsString:@"flag"] || [lower containsString:@"icon"]) continue;
                [imageTitles addObject:[@"File:" stringByAppendingString:name]]; if(imageTitles.count>=6) break;
            }
            if(!imageTitles.count) continue;
            NSDictionary *images=[self jsonAt:CDURL(base,@{@"action":@"query",@"format":@"json",@"titles":[imageTitles componentsJoinedByString:@"|"],@"prop":@"imageinfo",@"iiprop":@"url|size|extmetadata",@"iiurlwidth":@"1200"})];
            for(NSDictionary *file in CDDict(CDDict(images[@"query"])[@"pages"]).allValues) {
                NSDictionary *info=CDDict(CDArray(file[@"imageinfo"]).firstObject); double w=[info[@"width"] doubleValue],h=[info[@"height"] doubleValue];
                if(w<160 || h<160 || w/h<.82 || w/h>1.22) continue;
                NSString *url=CDString(info[@"thumburl"]); if(!url.length) url=CDString(info[@"url"]);
                NSString *article = [NSString stringWithFormat:@"https://%@.wikipedia.org/wiki/%@", language, [CDString(result[@"title"]) stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet]];
                [self emitURL:url title:CDString(result[@"title"]) source:[NSString stringWithFormat:@"Wikipedia · %@",language] page:article score:MIN(82,55+matched*10+(albumMatch?10:0)) reason:[NSString stringWithFormat:@"百科封面 · 命中 %ld 首曲名",(long)matched]];
            }
        }
    }
}
- (BOOL)seriesTitleMatches:(NSString *)title {
    NSString *wanted = [CDCoverSearch normalized:self.series], *found = [CDCoverSearch normalized:title];
    if (wanted.length < 4 || found.length < 4) return NO;
    return ([found containsString:wanted] || [wanted containsString:found]) && MIN(found.length, wanted.length) * 2 >= MAX(found.length, wanted.length);
}
- (void)searchSeriesWiki {
    for (NSString *language in @[@"zh", @"ja", @"en"]) {
        if (self.cancelled) return;
        NSString *base = [NSString stringWithFormat:@"https://%@.wikipedia.org/w/api.php", language];
        NSDictionary *search = [self jsonAt:CDURL(base, @{ @"action":@"query", @"format":@"json", @"list":@"search", @"srsearch":self.series, @"srlimit":@"3" })];
        NSUInteger acceptedPages = 0;
        for (NSDictionary *hit in CDArray(CDDict(search[@"query"])[@"search"])) {
            NSString *title = CDString(hit[@"title"]), *pageID = [hit[@"pageid"] description];
            if (![self seriesTitleMatches:title] || !pageID.length || acceptedPages++ >= 2 || self.cancelled) continue;
            NSString *article = [NSString stringWithFormat:@"https://%@.wikipedia.org/wiki/%@", language, [title stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet]];
            NSDictionary *details = CDDict([self jsonAt:CDURL(base, @{ @"action":@"query", @"format":@"json", @"pageids":pageID, @"prop":@"pageimages|images", @"piprop":@"thumbnail", @"pithumbsize":@"1200", @"imlimit":@"25" })][@"query"]);
            NSDictionary *page = CDDict(CDDict(details[@"pages"])[pageID]);
            NSString *lead = CDString(CDDict(page[@"thumbnail"])[@"source"]);
            if (lead.length) [self emitURL:lead title:title source:[NSString stringWithFormat:@"Wikipedia · %@", language] page:article score:32 reason:@"番剧主图 · CD 封面未匹配时的备选"];
            NSMutableArray *names = [NSMutableArray new];
            for (NSDictionary *file in CDArray(page[@"images"])) {
                NSString *name = CDString(file[@"title"]), *lower = name.lowercaseString;
                if (!([lower hasSuffix:@".jpg"] || [lower hasSuffix:@".jpeg"] || [lower hasSuffix:@".png"])) continue;
                if ([lower containsString:@"logo"] || [lower containsString:@"icon"] || [lower containsString:@"flag"] || [lower containsString:@"map"] || [lower containsString:@"character"]) continue;
                [names addObject:name]; if (names.count >= 7) break;
            }
            if (!names.count) continue;
            NSDictionary *imageData = [self jsonAt:CDURL(base, @{ @"action":@"query", @"format":@"json", @"titles":[names componentsJoinedByString:@"|"], @"prop":@"imageinfo", @"iiprop":@"url|size", @"iiurlwidth":@"1200" })];
            NSUInteger pictures = 0;
            for (NSDictionary *file in CDDict(CDDict(imageData[@"query"])[@"pages"]).allValues) {
                NSDictionary *info = CDDict(CDArray(file[@"imageinfo"]).firstObject);
                CGFloat width = [info[@"width"] doubleValue], height = [info[@"height"] doubleValue];
                if (width < 160 || height < 160 || width / height < .65 || width / height > 1.5) continue;
                NSString *url = CDString(info[@"thumburl"]); if (!url.length) url = CDString(info[@"url"]);
                if (url.length && pictures++ < 5) [self emitURL:url title:[NSString stringWithFormat:@"%@ · 番剧图片", title] source:[NSString stringWithFormat:@"Wikipedia · %@", language] page:article score:22 reason:@"同一番剧条目中的图片 · 手动选择"];
            }
        }
    }
}
- (void)searchSeriesMoegirl {
    NSString *search = CDURL(@"https://zh.moegirl.org.cn/index.php", @{ @"title":@"Special:Search", @"search":self.series, @"fulltext":@"1", @"limit":@"4" });
    NSData *data = [self dataAt:search];
    NSString *html = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    NSXMLDocument *doc = html.length ? [CDCoverSearch document:html] : nil;
    NSUInteger pages = 0;
    for (NSXMLElement *link in [doc nodesForXPath:@"//div[contains(@class,'mw-search-result-heading')]/a[1]" error:nil]) {
        NSString *title = link.stringValue ?: @"";
        if (![self seriesTitleMatches:title] || pages++ >= 2 || self.cancelled) continue;
        NSString *href = [link attributeForName:@"href"].stringValue;
        NSString *page = [[NSURL URLWithString:href relativeToURL:[NSURL URLWithString:@"https://zh.moegirl.org.cn/"]] absoluteURL].absoluteString;
        NSData *body = [self dataAt:page];
        NSXMLDocument *article = body ? [CDCoverSearch document:[[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] ?: @""] : nil;
        NSUInteger pictures = 0;
        for (NSXMLElement *img in [article nodesForXPath:@"//table[contains(@class,'infobox')]//img" error:nil]) {
            NSInteger w = [[img attributeForName:@"width"].stringValue integerValue], h = [[img attributeForName:@"height"].stringValue integerValue];
            if (w < 160 || h < 160 || w / (double)MAX(h, 1) < .65 || w / (double)MAX(h, 1) > 1.5) continue;
            NSString *src = [img attributeForName:@"src"].stringValue ?: @"";
            NSString *srcset = [img attributeForName:@"srcset"].stringValue;
            if (srcset.length) { NSString *last = [srcset componentsSeparatedByString:@","].lastObject; NSString *larger = [[last stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] componentsSeparatedByString:@" "].firstObject; if (larger.length) src = larger; }
            src = [[NSURL URLWithString:src relativeToURL:[NSURL URLWithString:page]] absoluteURL].absoluteString;
            if (src.length && pictures++ < 5) [self emitURL:src title:[NSString stringWithFormat:@"%@ · 番剧图片", title] source:@"萌娘百科" page:page score:28 reason:@"番剧条目图片 · CD 封面未匹配时的备选"];
        }
    }
}
@end
