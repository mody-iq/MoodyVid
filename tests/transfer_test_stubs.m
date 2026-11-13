// Isolate transfer/manifest tests from WebKit, UIKit and the user's files.
#import <Foundation/Foundation.h>

@interface MVPaths : NSObject
+ (NSString *)downloads;
+ (BOOL)path:(NSString *)path overlapsPath:(NSString *)other;
+ (NSString *)directoryForCategory:(NSString *)category;
+ (NSString *)sanitizeFilename:(NSString *)name;
+ (NSString *)uniquePathInDirectory:(NSString *)directory filename:(NSString *)name;
@end
@implementation MVPaths
+ (NSString *)downloads {
    NSString *directory = NSProcessInfo.processInfo.environment[@"MV_TRANSFER_TEST_DIR"] ?: NSTemporaryDirectory();
    [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    return directory;
}
+ (BOOL)path:(NSString *)path overlapsPath:(NSString *)other {
    if (!path.length || !other.length) return NO;
    for (NSInteger resolved = 0; resolved <= 1; resolved++) {
        NSString *a = resolved ? path.stringByResolvingSymlinksInPath : path;
        NSString *b = resolved ? other.stringByResolvingSymlinksInPath : other;
        a = a.stringByStandardizingPath.precomposedStringWithCanonicalMapping.lowercaseString;
        b = b.stringByStandardizingPath.precomposedStringWithCanonicalMapping.lowercaseString;
        if ([a isEqualToString:b] || [a hasPrefix:[b stringByAppendingString:@"/"]] ||
            [b hasPrefix:[a stringByAppendingString:@"/"]]) return YES;
    }
    return NO;
}
+ (NSString *)directoryForCategory:(NSString *)category { (void)category; return [self downloads]; }
+ (NSString *)sanitizeFilename:(NSString *)name { return name.lastPathComponent.length ? name.lastPathComponent : @"file"; }
+ (NSString *)uniquePathInDirectory:(NSString *)directory filename:(NSString *)name {
    NSString *safe = [self sanitizeFilename:name];
    NSString *path = [directory stringByAppendingPathComponent:safe];
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) return path;
    return [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-%@", NSUUID.UUID.UUIDString, safe]];
}
@end

// Mutable fixtures let cleanup tests model references from other records.
static NSArray *testTasks;
static NSArray *testRecords;
@interface MVTaskStore : NSObject
+ (instancetype)shared;
+ (void)setTestTasks:(NSArray *)tasks;
@property (nonatomic, readonly) NSArray *tasks;
@end
@implementation MVTaskStore
+ (instancetype)shared { static MVTaskStore *s; static dispatch_once_t once; dispatch_once(&once, ^{ s = [self new]; }); return s; }
+ (void)setTestTasks:(NSArray *)tasks { testTasks = [tasks copy]; }
- (NSArray *)tasks { return testTasks ?: @[]; }
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

@interface MVCookiePolicy : NSObject
+ (NSDictionary *)headersWithoutCookies:(NSDictionary *)headers;
@end
@implementation MVCookiePolicy
+ (NSDictionary *)headersWithoutCookies:(NSDictionary *)headers { return headers ?: @{}; }
@end

@interface MVMediaProbe : NSObject
+ (NSDictionary *)headersForURL:(NSString *)url referer:(NSString *)referer;
+ (NSDictionary *)headersForURL:(NSString *)url referer:(NSString *)referer additionalHeaders:(NSDictionary *)headers;
@end
@implementation MVMediaProbe
+ (NSDictionary *)headersForURL:(NSString *)url referer:(NSString *)referer { return @{}; }
+ (NSDictionary *)headersForURL:(NSString *)url referer:(NSString *)referer additionalHeaders:(NSDictionary *)headers { return headers ?: @{}; }
@end

@interface MVHTTPSession : NSObject
+ (NSURLSession *)sharedSession;
+ (void)handleRedirectForTask:(NSURLSessionTask *)task response:(NSHTTPURLResponse *)response
                   newRequest:(NSURLRequest *)request completion:(void (^)(NSURLRequest *))completion;
@end
@implementation MVHTTPSession
+ (NSURLSession *)sharedSession {
    static NSURLSession *session;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        config.URLCache = nil;
        config.HTTPShouldSetCookies = NO;
        session = [NSURLSession sessionWithConfiguration:config];
    });
    return session;
}
+ (void)handleRedirectForTask:(NSURLSessionTask *)task response:(NSHTTPURLResponse *)response
                   newRequest:(NSURLRequest *)request completion:(void (^)(NSURLRequest *))completion { completion(request); }
@end

// Parser tests do not exercise AVFoundation's muxing or track recognition.
@interface MVMediaConverter : NSObject
+ (BOOL)hasVideoTrack:(NSString *)path;
+ (BOOL)hasAudioTrack:(NSString *)path;
+ (void)muxVideo:(NSString *)video audio:(NSString *)audio to:(NSString *)output
      completion:(void (^)(BOOL, NSString *))completion;
@end
@implementation MVMediaConverter
+ (BOOL)hasVideoTrack:(NSString *)path { return NO; }
+ (BOOL)hasAudioTrack:(NSString *)path { return NO; }
+ (void)muxVideo:(NSString *)video audio:(NSString *)audio to:(NSString *)output
      completion:(void (^)(BOOL, NSString *))completion { completion(NO, @"not used in tests"); }
@end
