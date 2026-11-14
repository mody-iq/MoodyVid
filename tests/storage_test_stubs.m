#import <Foundation/Foundation.h>
// The isolated store/scanner tests never touch the user's real download stores.
static NSMutableArray *testTasks;
static NSMutableArray *testRecords;
@interface MVTaskStore : NSObject
+ (instancetype)shared;
+ (void)setTestTasks:(NSArray *)tasks;
@property (nonatomic, readonly) NSArray *tasks;
- (void)remove:(id)task;
@end
@implementation MVTaskStore
+ (instancetype)shared { static MVTaskStore *s; static dispatch_once_t once; dispatch_once(&once, ^{ s = [self new]; }); return s; }
+ (void)setTestTasks:(NSArray *)tasks { testTasks = [tasks mutableCopy]; }
- (NSArray *)tasks { return [testTasks copy] ?: @[]; }
- (void)remove:(id)task { [testTasks removeObjectIdenticalTo:task]; }
@end
@interface MVDownloadStore : NSObject
+ (instancetype)shared;
+ (void)setTestRecords:(NSArray *)records;
@property (nonatomic, readonly) NSArray *records;
- (void)remove:(id)record;
@end
@implementation MVDownloadStore
+ (instancetype)shared { static MVDownloadStore *s; static dispatch_once_t once; dispatch_once(&once, ^{ s = [self new]; }); return s; }
+ (void)setTestRecords:(NSArray *)records { testRecords = [records mutableCopy]; }
- (NSArray *)records { return [testRecords copy] ?: @[]; }
- (void)remove:(id)record { [testRecords removeObjectIdenticalTo:record]; }
@end
