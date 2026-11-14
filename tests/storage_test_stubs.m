#import <Foundation/Foundation.h>
// The isolated store/scanner tests never touch the user's real download stores.
@interface MVTaskStore : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly) NSArray *tasks;
@end
@implementation MVTaskStore
+ (instancetype)shared { static MVTaskStore *s; static dispatch_once_t once; dispatch_once(&once, ^{ s = [self new]; }); return s; }
- (NSArray *)tasks { return @[]; }
@end
@interface MVDownloadStore : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly) NSArray *records;
@end
@implementation MVDownloadStore
+ (instancetype)shared { static MVDownloadStore *s; static dispatch_once_t once; dispatch_once(&once, ^{ s = [self new]; }); return s; }
- (NSArray *)records { return @[]; }
@end
