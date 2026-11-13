// Test the real MVMediaProbe snapshot cache with a fake WebKit store. In
// particular, an old asynchronous callback must not restore cookies after a
// clear; the cache stores cookies, not a header reused for every path.
#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <unistd.h>
#import "MVMediaProbe.h"

// These classes are referenced by other MVMediaProbe methods but never called
// by this test. Stubs keep the test independent of the app and its log files.
@interface MVLog : NSObject
+ (void)log:(NSString *)level format:(NSString *)format, ...;
@end
@implementation MVLog
+ (void)log:(NSString *)level format:(NSString *)format, ... {}
@end
@interface MVHTTPSession : NSObject
+ (NSURLSession *)sharedSession;
@end
@implementation MVHTTPSession
+ (NSURLSession *)sharedSession { return NSURLSession.sharedSession; }
@end

static int failures;
#define CHECK(condition, description) do { \
    if (!(condition)) { fprintf(stderr, "FAIL: %s\n", description); failures++; } \
} while (0)

static dispatch_group_t requests;
static void (^oldCallback)(NSArray<NSHTTPCookie *> *);
static NSHTTPCookie *oldCookie;
static NSHTTPCookie *freshCookie;
static NSDictionary *firstResult;
static NSDictionary *freshResult;
static NSUInteger fetchCount;

static NSString *const kURL = @"https://example.com/private/video";
static NSString *const kPage = @"https://example.com/page";

@interface FakeCookieStore : NSObject
- (void)getAllCookies:(void (^)(NSArray<NSHTTPCookie *> *))completion;
@end
@implementation FakeCookieStore
- (void)getAllCookies:(void (^)(NSArray<NSHTTPCookie *> *))completion {
    CHECK(NSThread.isMainThread, "WebKit cookie fetch is called on the main thread");
    fetchCount++;
    if (fetchCount == 1) {
        oldCallback = [completion copy];
        [MVMediaProbe beginClearingBrowserCookies];
        NSDictionary *duringClear = [MVMediaProbe headersForURL:kURL referer:kPage];
        CHECK(!duringClear[@"Cookie"], "cookie snapshots are suspended during clear");
        [MVMediaProbe finishClearingBrowserCookies];
        // Request again after clear, before the older callback has finished.
        dispatch_group_enter(requests);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            freshResult = [MVMediaProbe headersForURL:kURL referer:kPage];
            dispatch_group_leave(requests);
        });
    } else if (fetchCount == 2) {
        completion(@[freshCookie]);
        // A stale result arriving last must not overwrite the fresh snapshot.
        oldCallback(@[oldCookie]);
        oldCallback = nil;
    } else {
        completion(@[]);
    }
}
@end

@interface FakeWebsiteDataStore : NSObject
@property (nonatomic, strong) FakeCookieStore *cookieStore;
@end
@implementation FakeWebsiteDataStore
- (id)httpCookieStore { return self.cookieStore; }
@end

static FakeWebsiteDataStore *fakeStore;
static id FakeDefaultDataStore(id receiver, SEL selector) { return fakeStore; }

static NSHTTPCookie *Cookie(NSString *name, NSString *path) {
    return [NSHTTPCookie cookieWithProperties:@{
        NSHTTPCookieName: name, NSHTTPCookieValue: @"value",
        NSHTTPCookieDomain: @"example.com", NSHTTPCookiePath: path,
        NSHTTPCookieVersion: @"0", NSHTTPCookieSecure: @"TRUE"
    }];
}

int main(void) {
    @autoreleasepool {
        oldCookie = Cookie(@"old", @"/");
        freshCookie = Cookie(@"fresh", @"/private");
        CHECK(oldCookie && freshCookie, "cookie fixtures created");
        if (!oldCookie || !freshCookie) return 1;
        fakeStore = [FakeWebsiteDataStore new];
        fakeStore.cookieStore = [FakeCookieStore new];
        Method method = class_getClassMethod(WKWebsiteDataStore.class, @selector(defaultDataStore));
        CHECK(method != NULL, "WebKit store method exists");
        if (!method) return 1;
        IMP original = method_setImplementation(method, (IMP)FakeDefaultDataStore);

        requests = dispatch_group_create();
        dispatch_group_enter(requests);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            firstResult = [MVMediaProbe headersForURL:kURL referer:kPage];
            dispatch_group_leave(requests);
        });
        __block BOOL finished = NO;
        dispatch_group_notify(requests, dispatch_get_main_queue(), ^{
            CHECK(fetchCount == 2, "fresh request fetched a new snapshot after clear");
            CHECK(![firstResult[@"Cookie"] containsString:@"old="], "in-flight old cookie not returned");
            CHECK([freshResult[@"Cookie"] containsString:@"fresh=value"], "fresh cookie returned after clear");
            CHECK(![freshResult[@"Cookie"] containsString:@"old="], "late old callback was ignored");
            NSDictionary *otherPath = [MVMediaProbe headersForURL:@"https://example.com/public" referer:kPage];
            CHECK(!otherPath[@"Cookie"], "cached snapshot is filtered for each path");
            NSDictionary *lookalike = [MVMediaProbe headersForURL:@"https://evil-example.com/private/video"
                                                          referer:@"https://evil-example.com/"];
            CHECK(!lookalike[@"Cookie"], "cached snapshot is filtered for each host");
            NSDictionary *otherContext = [MVMediaProbe headersForURL:kURL referer:@"https://unrelated.test/master.m3u8"];
            CHECK(!otherContext[@"Cookie"], "a resource cannot acquire cookies unrelated to its manifest context");
            NSDictionary *sameContext = [MVMediaProbe headersForURL:kURL referer:@"https://example.com/master.m3u8"];
            CHECK([sameContext[@"Cookie"] containsString:@"fresh=value"], "a matching manifest context can use scoped cookies");
            [MVMediaProbe beginClearingBrowserCookies];
            NSDictionary *cleared = [MVMediaProbe headersForURL:kURL referer:kPage];
            CHECK(!cleared[@"Cookie"] && fetchCount == 2, "clear discards cached snapshot without refetching");
            [MVMediaProbe finishClearingBrowserCookies];
            finished = YES;
        });
        // dispatch_main() can retire the process's initial thread on macOS,
        // causing main-queue work to fail an NSThread.isMainThread check even
        // though production iOS services the queue on its UI thread. Keep the
        // actual main thread alive and service its run loop instead.
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:20];
        while (!finished && deadline.timeIntervalSinceNow > 0) {
            [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        }
        CHECK(finished, "cookie-cache callbacks finished before the deadline");
        method_setImplementation(method, original);
        if (failures) fprintf(stderr, "%d COOKIE CACHE FAILURE(S)\n", failures);
        else puts("ALL COOKIE CACHE TESTS PASSED");
        return failures ? 1 : 0;
    }
}
