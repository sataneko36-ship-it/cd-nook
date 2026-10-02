#import <AppKit/AppKit.h>
@interface CDCoverSearch : NSObject
@property (atomic) BOOL cancelled;
@property (nonatomic, copy) void (^onCandidate)(NSDictionary *candidate, NSData *data);
@property (nonatomic, copy) void (^onFinish)(NSString *summary);
- (void)startWithAlbum:(NSString *)album artist:(NSString *)artist catalog:(NSString *)catalog tracks:(NSArray<NSString *> *)tracks series:(NSString *)series;
- (void)cancel;
+ (NSString *)normalized:(NSString *)text;
+ (NSArray<NSDictionary *> *)moegirlImagesInHTML:(NSString *)html pageURL:(NSString *)pageURL album:(NSString *)album tracks:(NSArray<NSString *> *)tracks;
@end
