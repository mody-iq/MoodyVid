// Foundation-only tests for cookie filtering, redirect sanitization, task header
// persistence, log redaction and safe export. See scripts/privacy-tests.sh.
#import <Foundation/Foundation.h>
#import "MVCookiePolicy.h"
#import "MVDownloadTask.h"
#import "MVLog.h"
#import <unistd.h>

static int failures = 0;
#define CHECK(condition, description) do { \
    if (!(condition)) { fprintf(stderr, "FAIL: %s\n", description); failures++; } \
} while (0)

// Keep the real logger's file operations in a disposable fixture, not the test
// runner's actual Application Support directory.
static NSString *testDirectory;
@interface MVPaths : NSObject
+ (NSString *)applicationSupport;
@end
@implementation MVPaths
+ (NSString *)applicationSupport { return testDirectory; }
@end

static NSURL *U(NSString *value) { return value ? [NSURL URLWithString:value] : nil; }

static NSHTTPCookie *Cookie(NSString *name, NSString *domain, NSString *path, BOOL secure, NSDate *expires) {
    NSMutableDictionary *properties = [@{
        NSHTTPCookieName: name,
        NSHTTPCookieValue: @"value",
        NSHTTPCookieDomain: domain,
        NSHTTPCookiePath: path,
        NSHTTPCookieVersion: @"0"
    } mutableCopy];
    if (secure) properties[NSHTTPCookieSecure] = @"TRUE";
    if (expires) properties[NSHTTPCookieExpires] = expires;
    return [NSHTTPCookie cookieWithProperties:properties];
}

static BOOL Allows(NSHTTPCookie *cookie, NSString *target, NSString *context, NSDate *now) {
    if (!cookie) return NO;
    return [MVCookiePolicy cookies:@[cookie] allowedForURL:U(target) contextURL:U(context) at:now].count == 1;
}

static void testCookies(void) {
    // Expiry is still in the real future when Foundation creates the fixture;
    // inject a later policy time to test expiry without relying on whether a
    // particular Foundation version accepts already-expired cookies.
    NSDate *now = [NSDate.date dateByAddingTimeInterval:120];
    NSHTTPCookie *host = Cookie(@"host", @"example.com", @"/", NO, nil);
    NSHTTPCookie *domain = Cookie(@"domain", @".example.com", @"/", NO, nil);
    NSHTTPCookie *path = Cookie(@"path", @"example.com", @"/private", NO, nil);
    NSHTTPCookie *secure = Cookie(@"secure", @"example.com", @"/", YES, nil);
    NSHTTPCookie *expired = Cookie(@"expired", @"example.com", @"/", NO, [now dateByAddingTimeInterval:-1]);
    CHECK(host && domain && path && secure && expired, "Foundation created cookie fixtures");
    if (!host || !domain || !path || !secure || !expired) return;
    CHECK([domain.domain hasPrefix:@"."], "Foundation preserves domain-cookie leading dot");
    CHECK(secure.isSecure, "Foundation created a Secure cookie");
    CHECK(expired.expiresDate && [expired.expiresDate compare:now] == NSOrderedAscending,
          "Foundation preserved the expiry fixture");
    CHECK(Allows(host, @"https://example.com/a", @"https://example.com/page", now), "exact host cookie");
    CHECK(!Allows(host, @"https://sub.example.com/a", @"https://example.com/page", now), "host-only cookie cannot reach subdomain");
    CHECK(!Allows(host, @"https://evil-example.com/a", @"https://example.com/page", now), "lookalike host rejected");
    CHECK(Allows(domain, @"https://cdn.example.com/a", @"https://www.example.com/page", now), "domain cookie covers both same-site hosts");
    CHECK(!Allows(domain, @"https://cdn.example.com/a", @"https://unrelated.test/page", now), "third-party context rejected");
    CHECK(!Allows(domain, @"https://cdn.example.com/a", @"http://www.example.com/page", now), "mixed-scheme context rejected");
    CHECK(!Allows(host, @"https://example.com/a", nil, now), "unknown context sends no cookie");
    CHECK(Allows(path, @"https://example.com/private/video", @"https://example.com/", now), "cookie path boundary accepted");
    CHECK(!Allows(path, @"https://example.com/private2", @"https://example.com/", now), "path prefix without boundary rejected");
    CHECK(!Allows(path, @"https://example.com/private%2Fvideo", @"https://example.com/", now), "encoded slash is not a path boundary");
    CHECK(Allows(secure, @"https://example.com/", @"https://example.com/", now), "secure cookie on HTTPS");
    CHECK(!Allows(secure, @"http://example.com/", @"http://example.com/", now), "secure cookie not sent on HTTP");
    CHECK(!Allows(expired, @"https://example.com/", @"https://example.com/", now), "expired cookie rejected");
    CHECK(!Allows(host, @"ftp://example.com/", @"ftp://example.com/", now), "non-HTTP scheme rejected");

    NSHTTPCookie *portCookie = [NSHTTPCookie cookieWithProperties:@{
        NSHTTPCookieName: @"port", NSHTTPCookieValue: @"value", NSHTTPCookieDomain: @"example.com",
        NSHTTPCookiePath: @"/", NSHTTPCookieVersion: @"1", NSHTTPCookiePort: @"8443"
    }];
    CHECK(portCookie.portList.count == 1, "Foundation created a port-restricted cookie");
    CHECK(Allows(portCookie, @"https://example.com:8443/", @"https://example.com/", now), "allowed cookie port");
    CHECK(!Allows(portCookie, @"https://example.com/", @"https://example.com/", now), "other cookie port rejected");
    NSMutableDictionary *partitionProperties = [host.properties mutableCopy];
    partitionProperties[@"StoragePartition"] = @"https://first.test";
    NSHTTPCookie *partitioned = [NSHTTPCookie cookieWithProperties:partitionProperties];
    if (partitioned.properties[@"StoragePartition"]) {
        CHECK(!Allows(partitioned, @"https://example.com/", @"https://example.com/", now), "partitioned cookie rejected");
    } else {
        puts("SKIP: Foundation did not preserve the test partition key; verify WebKit on iOS");
    }

    NSHTTPCookie *foreign = Cookie(@"foreign", @"other.test", @"/", NO, nil);
    CHECK(foreign != nil, "Foundation created a foreign cookie fixture");
    if (!foreign) return;
    NSString *header = [MVCookiePolicy cookieHeaderForURL:U(@"https://example.com/private/video")
                                                   cookies:@[host, path, secure, foreign]
                                                contextURL:U(@"https://example.com/")];
    CHECK([header containsString:@"host=value"], "selected cookie appears in header");
    CHECK(![header containsString:@"foreign="], "foreign cookie absent from header");
}

static void testRedirects(void) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:U(@"https://other.test/private")];
    [request setValue:@"old=secret" forHTTPHeaderField:@"Cookie"];
    [request setValue:@"other=secret" forHTTPHeaderField:@"Cookie2"];
    [request setValue:@"Bearer secret" forHTTPHeaderField:@"Authorization"];
    [request setValue:@"Basic secret" forHTTPHeaderField:@"Proxy-Authorization"];
    [request setValue:@"https://user:pass@example.com/page?token=private#fragment" forHTTPHeaderField:@"Referer"];
    NSMutableURLRequest *cross = [MVCookiePolicy redirectRequest:request fromURL:U(@"https://example.com/a") cookieHeader:@"fresh=yes"];
    CHECK([[cross valueForHTTPHeaderField:@"Cookie"] isEqualToString:@"fresh=yes"], "redirect uses only destination cookie");
    CHECK([cross valueForHTTPHeaderField:@"Cookie2"] == nil, "redirect removes Cookie2");
    CHECK([cross valueForHTTPHeaderField:@"Authorization"] == nil, "cross-origin auth removed");
    CHECK([cross valueForHTTPHeaderField:@"Proxy-Authorization"] == nil, "cross-origin proxy auth removed");
    CHECK([[cross valueForHTTPHeaderField:@"Referer"] isEqualToString:@"https://example.com/"], "cross-origin Referer contains only origin");
    CHECK(!cross.HTTPShouldHandleCookies, "redirect cannot add shared-store cookies");
    CHECK([[request valueForHTTPHeaderField:@"Cookie"] isEqualToString:@"old=secret"], "input request unchanged");

    request.URL = U(@"https://example.com:443/new");
    NSMutableURLRequest *same = [MVCookiePolicy redirectRequest:request fromURL:U(@"https://example.com/old") cookieHeader:nil];
    CHECK([same valueForHTTPHeaderField:@"Authorization"] != nil, "same-origin auth retained");
    CHECK([same valueForHTTPHeaderField:@"Cookie"] == nil, "old cookie removed even on same host");
    request.URL = U(@"https://example.com:444/new");
    NSMutableURLRequest *portChange = [MVCookiePolicy redirectRequest:request fromURL:U(@"https://example.com/old") cookieHeader:nil];
    CHECK([portChange valueForHTTPHeaderField:@"Authorization"] == nil, "port change is cross-origin");
    request.URL = U(@"http://example.com/new");
    NSMutableURLRequest *down = [MVCookiePolicy redirectRequest:request fromURL:U(@"https://example.com/old") cookieHeader:nil];
    CHECK([down valueForHTTPHeaderField:@"Referer"] == nil, "HTTPS to HTTP strips Referer");
    CHECK([down valueForHTTPHeaderField:@"Authorization"] == nil, "HTTPS to HTTP strips auth");
    request.URL = U(@"file:///tmp/file");
    CHECK([MVCookiePolicy redirectRequest:request fromURL:U(@"https://example.com/") cookieHeader:nil] == nil, "non-HTTP redirect rejected");

    NSString *referer = [MVCookiePolicy safeReferer:@"https://user:pass@example.com/page?q=1#frag" forURL:U(@"https://example.com/video")];
    CHECK([referer isEqualToString:@"https://example.com/page?q=1"], "same-origin Referer strips credentials and fragment");
    CHECK([MVCookiePolicy safeReferer:@"https://example.com/page" forURL:U(@"http://example.com/video")] == nil, "direct HTTPS downgrade strips Referer");
}

static void testStoredHeaders(void) {
    NSDictionary *raw = @{@"cOOkie": @"session=old", @"COOKIE2": @"other=old", @"User-Agent": @"custom"};
    MVDownloadTask *task = [MVDownloadTask taskFromDictionary:@{@"url": @"https://example.com/file", @"headers": raw}];
    CHECK(task.headers.count == 1, "legacy raw cookie headers removed on load");
    CHECK([task.headers[@"User-Agent"] isEqualToString:@"custom"], "non-cookie custom header retained");
    CHECK([task.dictionary[@"headers"] count] == 1, "raw cookies not persisted again");
    task.headers = raw;
    CHECK(task.headers.count == 1, "setter rejects raw cookies too");

    task.url = @"https://stream.test/master.m3u8";
    task.referer = nil;
    CHECK([task.resourceContextURL isEqualToString:task.url], "manual stream uses its manifest as resource context");
    NSHTTPCookie *unrelated = Cookie(@"bank", @"bank.test", @"/", YES, nil);
    CHECK(unrelated && !Allows(unrelated, @"https://bank.test/segment", task.resourceContextURL, NSDate.date),
          "manual manifest cannot make an unrelated resource first-party");
    task.referer = @"https://bank.test/page";
    CHECK([task.resourceContextURL isEqualToString:task.referer], "stream uses its page when present");
    CHECK(Allows(unrelated, @"https://bank.test/segment", task.resourceContextURL, NSDate.date),
          "page-scoped resource still receives its matching cookie");
}

static void testRedaction(void) {
    NSArray<NSArray<NSString *> *> *cases = @[
        @[@"open https://alice:pass@example.test/private?token=urlSecret#frag", @"alice", @"pass", @"example.test", @"urlSecret"],
        @[@"magnet:?xt=urn:btih:myHash&tr=https%3A%2F%2Ftracker.test", @"myHash", @"tracker.test"],
        @[@"magnet%3A%3Fxt=urn%3Abtih%3AmyHash", @"myHash"],
        @[@"url=https%3A%2F%2Fexample.test%2Fprivate", @"example.test", @"private"],
        @[@"url=https%3A//example.test/private", @"example.test", @"private"],
        @[@"url=https:%2F/example.test/private", @"example.test", @"private"],
        @[@"url=https:\\/\\/example.test\\/private", @"example.test", @"private"],
        @[@"Cookie: a=cookieSecret; b=secondSecret", @"cookieSecret", @"secondSecret"],
        @[@"\"Authorization\": \"Bearer headerSecret\"", @"headerSecret"],
        @[@"access_token=tokenSecret password=otherSecret", @"tokenSecret", @"otherSecret"],
        @[@"api_key: \"apiSecret\"", @"apiSecret"],
        @[@"Bearer bearerSecret", @"bearerSecret"]
    ];
    for (NSArray<NSString *> *fixture in cases) {
        NSString *clean = [MVLog redactedText:fixture.firstObject];
        CHECK([clean containsString:@"[redacted]"], "redactor replaces a sensitive value");
        for (NSUInteger i = 1; i < fixture.count; i++) {
            CHECK(![clean containsString:fixture[i]], "sensitive fixture absent after redaction");
        }
        CHECK([[MVLog redactedText:clean] isEqualToString:clean], "redaction is idempotent");
    }
    CHECK([[MVLog redactedText:@"download failed: HTTP 403"] isEqualToString:@"download failed: HTTP 403"], "non-sensitive diagnostic retained");
}

static void finish(int code) {
    [NSFileManager.defaultManager removeItemAtPath:testDirectory error:nil];
    if (code) fprintf(stderr, "%d PRIVACY TEST FAILURE(S)\n", failures);
    else puts("ALL NATIVE PRIVACY TESTS PASSED");
    fflush(stdout);
    fflush(stderr);
    exit(code);
}

static void testLogFiles(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:testDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [testDirectory stringByAppendingPathComponent:@"MoodyVid.log"];
    NSString *old = [path stringByAppendingPathExtension:@"1"];
    [@"legacy https://example.test/?token=liveSecret\n" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [@"old Cookie: rotatedSecret\n" writeToFile:old atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [MVLog log:@"I" format:@"new https://example.test/?token=newSecret"];
    [MVLog prepareRedactedLogsWithCompletion:^(NSArray<NSURL *> *files, NSError *error) {
        CHECK(error == nil && files.count == 2, "live and rotated logs exported");
        for (NSURL *url in files) {
            CHECK(![url.path isEqualToString:path] && ![url.path isEqualToString:old], "share uses temporary copies");
            NSString *text = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
            CHECK(text != nil, "redacted copy is readable");
            CHECK(![text containsString:@"liveSecret"] && ![text containsString:@"rotatedSecret"] && ![text containsString:@"newSecret"], "copies contain no fixture secrets");
        }
        NSString *live = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        NSString *rotated = [NSString stringWithContentsOfFile:old encoding:NSUTF8StringEncoding error:nil];
        CHECK(![live containsString:@"liveSecret"] && ![live containsString:@"newSecret"], "legacy and new live log sanitized on disk");
        CHECK(![rotated containsString:@"rotatedSecret"], "rotated legacy log sanitized on disk");
        if (files.count) [fm removeItemAtURL:files.firstObject.URLByDeletingLastPathComponent error:nil];

        // An unverifiable non-UTF-8 legacy file is never handed to the share sheet.
        const unsigned char invalidBytes[] = {0xff, 0xfe, 's', 'e', 'c', 'r', 'e', 't'};
        [[NSData dataWithBytes:invalidBytes length:sizeof(invalidBytes)] writeToFile:old atomically:YES];
        [MVLog prepareRedactedLogsWithCompletion:^(NSArray<NSURL *> *badFiles, NSError *badError) {
            CHECK(badError != nil && badFiles.count == 0, "invalid log makes export fail closed");
            [MVLog clear];
            [MVLog prepareRedactedLogsWithCompletion:^(NSArray<NSURL *> *empty, NSError *clearError) {
                CHECK(clearError == nil && empty.count == 0, "clear removes both log files");
                finish(failures ? 1 : 0);
            }];
        }];
    }];
}

int main(void) {
    @autoreleasepool {
        testDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"MoodyVid-Privacy-Test-%@", NSUUID.UUID.UUIDString]];
        testCookies();
        testRedirects();
        testStoredHeaders();
        testRedaction();
        testLogFiles();
        alarm(20); // A broken asynchronous callback must not hang CI forever.
        dispatch_main();
    }
}
