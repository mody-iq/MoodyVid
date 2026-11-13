// Exercise MVHTTPSession's real URLSession redirect delegate against a local
// server. The cookie provider is a deterministic fake; WebKit itself is tested
// separately on an iPhone. No browser or shared cookie store is touched.
#import <Foundation/Foundation.h>
#import "MVHTTPSession.h"

// MVHTTPSession only calls this one method on the provider. Defining a minimal
// stub avoids loading WebKit or the developer's browser cookies in this test.
@interface MVMediaProbe : NSObject
+ (NSDictionary<NSString *, NSString *> *)headersForURL:(NSString *)url referer:(NSString *)referer;
@end

static int failures = 0;
#define CHECK(condition, description) do { \
    if (!(condition)) { fprintf(stderr, "FAIL: %s\n", description); failures++; } \
} while (0)

@implementation MVMediaProbe
+ (NSDictionary<NSString *, NSString *> *)headersForURL:(NSString *)url referer:(NSString *)referer {
    NSURL *target = [NSURL URLWithString:url];
    if ([target.path hasPrefix:@"/destination"] && referer.length) return @{@"Cookie": @"fresh=destination"};
    return @{};
}
@end

static NSDictionary *Fetch(NSString *base, NSString *path, BOOL attachCredentials) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[base stringByAppendingString:path]]];
    request.HTTPShouldHandleCookies = NO;
    if (attachCredentials) {
        [request setValue:@"old=secret" forHTTPHeaderField:@"Cookie"];
        [request setValue:@"stale=secret" forHTTPHeaderField:@"Cookie2"];
        [request setValue:@"Bearer originalSecret" forHTTPHeaderField:@"Authorization"];
        [request setValue:[base stringByAppendingString:@"/page?token=secret"] forHTTPHeaderField:@"Referer"];
    }
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSDictionary *result = nil;
    __block NSError *requestError = nil;
    NSURLSessionDataTask *task = [MVHTTPSession.sharedSession dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            requestError = error;
            if (data) result = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            dispatch_semaphore_signal(done);
        }];
    [task resume];
    long timeout = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    CHECK(!timeout, "local HTTP request completed");
    CHECK(requestError == nil, "local HTTP request did not fail");
    CHECK([result isKindOfClass:NSDictionary.class], "server returned JSON");
    return result;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 3) return 2;
        NSString *first = [NSString stringWithUTF8String:argv[1]];
        NSString *second = [NSString stringWithUTF8String:argv[2]];
        (void)second;
        NSURLSessionConfiguration *config = MVHTTPSession.sharedSession.configuration;
        CHECK(!config.HTTPShouldSetCookies && config.HTTPCookieStorage == nil,
              "session does not use the shared cookie store");
        CHECK(config.URLCredentialStorage == nil && config.URLCache == nil,
              "session does not use shared credentials or cache");

        NSDictionary *same = Fetch(first, @"/start-same", YES);
        CHECK([same[@"initial"][@"cookie"] isEqualToString:@"old=secret"], "manually scoped cookie is sent on initial request");
        CHECK([same[@"initial"][@"authorization"] isEqualToString:@"Bearer originalSecret"], "initial authorization is sent");
        CHECK([same[@"final"][@"cookie"] isEqualToString:@"fresh=destination"], "same-origin redirect reselects cookie");
        CHECK(![same[@"final"][@"cookie2"] length], "same-origin redirect strips Cookie2");

        NSDictionary *cross = Fetch(first, @"/start-cross", YES);
        CHECK([cross[@"final"][@"cookie"] isEqualToString:@"fresh=destination"], "cross-origin redirect reselects cookie");
        CHECK(![cross[@"final"][@"authorization"] length], "cross-origin redirect does not send authorization");
        CHECK(![cross[@"final"][@"cookie2"] length], "cross-origin redirect strips Cookie2");
        NSString *referer = cross[@"final"][@"referer"];
        CHECK(!referer.length || [referer isEqualToString:[first stringByAppendingString:@"/"]], "cross-origin Referer is at most the origin");

        NSDictionary *tracker = Fetch(first, @"/start-tracker", NO);
        CHECK(![tracker[@"initial"][@"cookie"] length], "tracker starts without browser cookies");
        CHECK(![tracker[@"final"][@"cookie"] length], "tracker redirect does not acquire browser cookies");

        [MVHTTPSession.sharedSession invalidateAndCancel];
        if (failures) fprintf(stderr, "%d REDIRECT INTEGRATION FAILURE(S)\n", failures);
        else puts("ALL LOCAL REDIRECT INTEGRATION TESTS PASSED");
        return failures ? 1 : 0;
    }
}
