#import "../CDCoverSearch.h"
#include <assert.h>
int main(int argc,const char **argv) { @autoreleasepool {
 assert([[CDCoverSearch normalized:@"ガヴリール １２３"] isEqual:[CDCoverSearch normalized:@"ガヴリール123"]]);
 NSString *html=@"<html><h1>歌曲</h1><div class='mw-parser-output'><table class='infobox'><tr><td>专辑封面 Song One Song Two<img width='280' height='280' src='https://example.org/cover.jpg' srcset='https://example.org/cover-large.jpg 2x'></td></tr></table><img width='32' height='32' src='https://example.org/icon.png'><img width='280' height='280' src='https://example.org/logo.png'></div></html>";
 NSArray *images=[CDCoverSearch moegirlImagesInHTML:html pageURL:@"https://example.org/song" album:@"Album" tracks:@[@"Song One",@"Song Two"]];
 assert(images.count==1); assert([images[0][@"url"] isEqual:@"https://example.org/cover-large.jpg"]);
 assert([CDCoverSearch moegirlImagesInHTML:html pageURL:@"https://example.org/song" album:@"Other" tracks:@[@"Unrelated"]].count==0);
 if(argc>1) {
  NSString *real=[NSString stringWithContentsOfFile:[NSString stringWithUTF8String:argv[1]] encoding:NSUTF8StringEncoding error:nil];
  NSArray *found=[CDCoverSearch moegirlImagesInHTML:real pageURL:@"https://zh.moegirl.org.cn/珈百璃的飞踢" album:@"ガヴリールドロップキック" tracks:@[@"ガヴリールドロップキック",@"反転Devil & Angel"]];
  NSLog(@"real Moegirl page: %@",found); assert(found.count>0);
 }
 NSLog(@"Normalization, cover filtering, unrelated-page rejection passed");
 if(argc>2) {
  __block BOOL finished=NO; CDCoverSearch *search=[CDCoverSearch new];
  search.onCandidate=^(NSDictionary *c,NSData *d){NSLog(@"CANDIDATE %@ score=%@ %@ %@x%@",c[@"source"],c[@"score"],c[@"title"],c[@"width"],c[@"height"]);};
  search.onFinish=^(NSString *summary){NSLog(@"FINISH %@",summary);finished=YES;};
  [search startWithAlbum:@"ガヴリールドロップキック" artist:@"ガヴリール" catalog:@"ZMCZ-10930" tracks:@[@"ガヴリールドロップキック",@"反転Devil & Angel",@"ガヴリールドロップキック (instrumental)",@"反転Devil & Angel (instrumental)"] series:@"ガヴリールドロップアウト"];
  NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:150];
  while(!finished && deadline.timeIntervalSinceNow>0) [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.1]];
  [search cancel]; assert(finished);
 }
} }
