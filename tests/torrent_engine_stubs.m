// Isolate torrent scheduler tests from user stores, network and UI.
#import <Foundation/Foundation.h>

static NSArray *testTasks;
static NSArray *testRecords;
@interface MVTaskStore : NSObject
+ (instancetype)shared;
+ (void)setTestTasks:(NSArray *)tasks;
@property (nonatomic, readonly) NSArray *tasks;
- (id)taskWithIdentifier:(NSString *)identifier;
@end
@implementation MVTaskStore
+ (instancetype)shared { static MVTaskStore *s; static dispatch_once_t once; dispatch_once(&once, ^{ s = [self new]; }); return s; }
+ (void)setTestTasks:(NSArray *)tasks { testTasks = [tasks copy]; }
- (NSArray *)tasks { return testTasks ?: @[]; }
- (id)taskWithIdentifier:(NSString *)identifier {
    for (id task in self.tasks) if ([[task identifier] isEqualToString:identifier]) return task;
    return nil;
}
@end

@interface MVDownloadStore : NSObject
+ (instancetype)shared;
+ (void)setTestRecords:(NSArray *)records;
@property (nonatomic, readonly) NSArray *records;
@end
@implementation MVDownloadStore
+ (instancetype)shared { static MVDownloadStore *s; static dispatch_once_t once; dispatch_once(&once, ^{ s = [self new]; }); return s; }
+ (void)setTestRecords:(NSArray *)records { testRecords = [records copy]; }
- (NSArray *)records { return testRecords ?: @[]; }
@end

@interface MVCookiePolicy : NSObject
+ (NSDictionary *)headersWithoutCookies:(NSDictionary *)headers;
@end
@implementation MVCookiePolicy
+ (NSDictionary *)headersWithoutCookies:(NSDictionary *)headers { return headers ?: @{}; }
@end

@interface MVLang : NSObject
+ (NSString *)t:(NSString *)key;
@end
@implementation MVLang
+ (NSString *)t:(NSString *)key { return key; }
@end

@interface MVLog : NSObject
+ (void)log:(NSString *)level format:(NSString *)format, ...;
@end
@implementation MVLog
+ (void)log:(NSString *)level format:(NSString *)format, ... { (void)level; (void)format; }
@end

@interface MVMediaProbe : NSObject
+ (NSDictionary *)headersForURL:(NSString *)url referer:(NSString *)referer;
@end
@implementation MVMediaProbe
+ (NSDictionary *)headersForURL:(NSString *)url referer:(NSString *)referer { (void)url; (void)referer; return @{}; }
@end

@interface MVHTTPSession : NSObject
+ (NSURLSession *)sharedSession;
@end
@implementation MVHTTPSession
+ (NSURLSession *)sharedSession { return nil; }
@end
