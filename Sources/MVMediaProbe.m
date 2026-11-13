#import "MVMediaProbe.h"
#import "MVCookiePolicy.h"
#import "MVHTTPSession.h"
#import "MVLog.h"
#import <WebKit/WebKit.h>

/// A short timeout: a probe is an optimisation, and a stalled server must not
/// leave the row spinning forever.
static const NSTimeInterval kProbeTimeout = 12.0;

// Cache the cookie *snapshot*, not an already-built header: path, scheme and
// expiry must be checked independently for every request. All of this state is
// protected by MVCookieLock, including late WebKit callbacks after a clear.
static NSObject *MVCookieLock;
static NSArray<NSHTTPCookie *> *MVCookieSnapshot;
static NSDate *MVCookieSnapshotDate;
static dispatch_group_t MVCookiePending;
static NSDate *MVCookiePendingDate;
static NSUInteger MVCookieGeneration;
static BOOL MVCookiesSuspended;

static void MVPrepareCookieCache(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ MVCookieLock = [NSObject new]; });
}

@implementation MVMediaProbe

+ (instancetype)shared {
    static MVMediaProbe *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [MVMediaProbe new]; });
    return instance;
}

+ (NSString *)userAgent {
    return @"Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15"
            " (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";
}

+ (NSDictionary<NSString *, NSString *> *)headersForURL:(NSString *)url referer:(NSString *)referer {
    return [self headersForURL:url referer:referer additionalHeaders:nil];
}

+ (NSDictionary<NSString *, NSString *> *)headersForURL:(NSString *)url
                                                 referer:(NSString *)referer
                                       additionalHeaders:(NSDictionary<NSString *, NSString *> *)additionalHeaders {
    NSMutableDictionary<NSString *, NSString *> *headers = [@{
        @"User-Agent": [self userAgent], @"Accept": @"*/*",
        @"Accept-Language": @"en-US,en;q=0.9,ar;q=0.8"
    } mutableCopy];
    NSDictionary *extra = [MVCookiePolicy headersWithoutCookies:additionalHeaders];
    NSString *customReferer = nil;
    for (NSString *key in extra) {
        if ([key caseInsensitiveCompare:@"Referer"] == NSOrderedSame) {
            customReferer = extra[key];
            continue;
        }
        // HTTP field names are case-insensitive; make custom values replace
        // defaults even when their spelling differs in capitalisation.
        for (NSString *existing in [headers.allKeys copy]) {
            if ([existing caseInsensitiveCompare:key] == NSOrderedSame) [headers removeObjectForKey:existing];
        }
        headers[key] = extra[key];
    }
    NSString *page = referer.length ? referer : customReferer;
    NSURL *target = [NSURL URLWithString:url];
    if (!target.host.length) return headers;
    NSString *safeReferer = [MVCookiePolicy safeReferer:page forURL:target];
    if (safeReferer.length) headers[@"Referer"] = safeReferer;

    // No page means a user-requested URL, so it is its own context. A supplied
    // but malformed page is *not* treated as first-party.
    NSURL *context = page.length ? [NSURL URLWithString:page] : target;
    NSString *cookieHeader = [MVCookiePolicy cookieHeaderForURL:target
                                                        cookies:[self browserCookieSnapshot]
                                                     contextURL:context];
    if (cookieHeader.length) headers[@"Cookie"] = cookieHeader;
    return headers;
}

+ (void)beginClearingBrowserCookies {
    MVPrepareCookieCache();
    @synchronized (MVCookieLock) {
        MVCookiesSuspended = YES;
        MVCookieGeneration++;
        MVCookieSnapshot = nil;
        MVCookieSnapshotDate = nil;
        MVCookiePending = nil;
        MVCookiePendingDate = nil;
    }
}

+ (void)finishClearingBrowserCookies {
    MVPrepareCookieCache();
    @synchronized (MVCookieLock) {
        MVCookieGeneration++;
        MVCookieSnapshot = nil;
        MVCookieSnapshotDate = nil;
        MVCookiePending = nil;
        MVCookiePendingDate = nil;
        MVCookiesSuspended = NO;
    }
}

/// WebKit owns the cookies. A short-lived snapshot avoids querying it for every
/// HLS segment; the policy filters that snapshot for each complete URL. Requests
/// share one in-flight query, and a late result can never undo a browser clear.
+ (NSArray<NSHTTPCookie *> *)browserCookieSnapshot {
    MVPrepareCookieCache();
    dispatch_group_t pending;
    NSUInteger generation = 0;
    BOOL startFetch = NO;
    @synchronized (MVCookieLock) {
        if (MVCookiesSuspended) return @[];
        if (MVCookieSnapshotDate && -MVCookieSnapshotDate.timeIntervalSinceNow < 5.0) return MVCookieSnapshot ?: @[];
        // Do not let a WebKit callback that never arrives stall every future
        // attempt. Its late result will be ignored if a new query replaced it.
        if (MVCookiePendingDate && -MVCookiePendingDate.timeIntervalSinceNow > 2.0) {
            MVCookiePending = nil;
            MVCookiePendingDate = nil;
        }
        if (!MVCookiePending) {
            MVCookiePending = dispatch_group_create();
            dispatch_group_enter(MVCookiePending);
            MVCookiePendingDate = NSDate.date;
            startFetch = YES;
        }
        pending = MVCookiePending;
        generation = MVCookieGeneration;
    }

    if (startFetch) {
        // WebKit APIs are main-thread-bound; background downloaders wait only a
        // short, bounded time for this asynchronous snapshot.
        dispatch_async(dispatch_get_main_queue(), ^{
            [WKWebsiteDataStore.defaultDataStore.httpCookieStore getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
                @synchronized (MVCookieLock) {
                    if (!MVCookiesSuspended && generation == MVCookieGeneration && MVCookiePending == pending) {
                        MVCookieSnapshot = [cookies copy] ?: @[];
                        MVCookieSnapshotDate = NSDate.date;
                        MVCookiePending = nil;
                        MVCookiePendingDate = nil;
                    }
                }
                dispatch_group_leave(pending);
            }];
        });
    }
    // WebKit may deliver its callback on the main thread. Never block it.
    if (!NSThread.isMainThread) {
        dispatch_group_wait(pending, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)));
    }
    @synchronized (MVCookieLock) {
        if (MVCookiesSuspended || !MVCookieSnapshotDate || -MVCookieSnapshotDate.timeIntervalSinceNow >= 5.0) return @[];
        return MVCookieSnapshot ?: @[];
    }
}

- (void)probe:(MVSnifferItem *)item completion:(void (^)(MVSnifferItem *))completion {
    if (!item.url.length) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(item); });
        return;
    }
    // A magnet has nothing to HEAD.
    if (item.isTorrent) {
        item.probed = YES;
        item.totalBytes = -1;
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(item); });
        return;
    }

    NSString *url = item.url;
    NSString *referer = item.referer.length ? item.referer : item.pageURL;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDictionary *headers = [MVMediaProbe headersForURL:url referer:referer];
        [self headRequest:url headers:headers completion:^(NSDictionary *info) {
            if (!info) {
                // HEAD was refused: a one-byte ranged GET still reveals the size
                // and the real Content-Type on most servers.
                // Rebuild rather than reusing a possibly pre-clear Cookie.
                NSMutableDictionary *rangeHeaders = [[MVMediaProbe headersForURL:url referer:referer] mutableCopy];
                rangeHeaders[@"Range"] = @"bytes=0-0";
                [self rangeRequest:url headers:rangeHeaders completion:^(NSDictionary *rangeInfo) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self apply:rangeInfo to:item];
                        if (completion) completion(item);
                    });
                }];
                return;
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                [self apply:info to:item];
                if (completion) completion(item);
            });
        }];
    });
}

- (void)probeAll:(NSArray<MVSnifferItem *> *)items completion:(void (^)(void))completion {
    if (!items.count) {
        if (completion) completion();
        return;
    }
    NSMutableArray<MVSnifferItem *> *queue = [items mutableCopy];
    __block NSUInteger remaining = queue.count;
    // Sequential: one request at a time keeps a busy page from opening twenty
    // sockets at once on a phone.
    for (MVSnifferItem *item in queue) {
        [self probe:item completion:^(MVSnifferItem *probed) {
            if (--remaining == 0 && completion) completion();
        }];
    }
}

#pragma mark - Requests

- (void)headRequest:(NSString *)url
            headers:(NSDictionary<NSString *, NSString *> *)headers
         completion:(void (^)(NSDictionary *_Nullable info))completion {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:kProbeTimeout];
    request.HTTPMethod = @"HEAD";
    request.HTTPShouldHandleCookies = NO;
    for (NSString *key in headers) [request setValue:headers[key] forHTTPHeaderField:key];

    NSURLSessionDataTask *task = [MVHTTPSession.sharedSession dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || ![response isKindOfClass:NSHTTPURLResponse.class]) {
            completion(nil);
            return;
        }
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        if (http.statusCode >= 400) {
            MVLogWarn(@"probe: HEAD %ld for %@", (long)http.statusCode, url);
            completion(nil);
            return;
        }
        completion([self infoFromResponse:http]);
    }];
    [task resume];
}

- (void)rangeRequest:(NSString *)url
             headers:(NSDictionary<NSString *, NSString *> *)headers
          completion:(void (^)(NSDictionary *_Nullable info))completion {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:kProbeTimeout];
    request.HTTPMethod = @"GET";
    request.HTTPShouldHandleCookies = NO;
    for (NSString *key in headers) [request setValue:headers[key] forHTTPHeaderField:key];

    NSURLSessionDataTask *task = [MVHTTPSession.sharedSession dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || ![response isKindOfClass:NSHTTPURLResponse.class]) {
            completion(nil);
            return;
        }
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        NSMutableDictionary *info = [[self infoFromResponse:http] mutableCopy];
        // A 206 replies with Content-Range: bytes 0-0/12345 — the part after the
        // slash is the whole size even when Content-Length is just 1.
        NSString *contentRange = http.allHeaderFields[@"Content-Range"];
        if ([contentRange isKindOfClass:NSString.class]) {
            NSArray *parts = [contentRange componentsSeparatedByString:@"/"];
            if (parts.count == 2) {
                long long total = [parts[1] longLongValue];
                if (total > 0) info[@"size"] = @(total);
            }
        }
        completion(info);
    }];
    [task resume];
}

- (NSDictionary *)infoFromResponse:(NSHTTPURLResponse *)http {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    NSDictionary *all = http.allHeaderFields;

    long long size = [all[@"Content-Length"] longLongValue];
    // A HEAD often reports 0 for a chunked response; that is not a real size.
    if (size <= 0) size = [all[@"Content-Range"] longLongValue];
    info[@"size"] = @(size);

    NSString *type = all[@"Content-Type"];
    if ([type isKindOfClass:NSString.class] && type.length) {
        // "video/mp4; charset=..." — keep the MIME part only.
        info[@"mime"] = [[type componentsSeparatedByString:@";"] firstObject];
    }

    NSString *disposition = all[@"Content-Disposition"];
    if ([disposition isKindOfClass:NSString.class]) {
        NSString *filename = [self filenameFromDisposition:disposition];
        if (filename.length) info[@"filename"] = filename;
    }

    NSString *ranges = all[@"Accept-Ranges"];
    BOOL accepts = [ranges isKindOfClass:NSString.class] && [ranges.lowercaseString containsString:@"bytes"];
    info[@"ranges"] = @(accepts);

    return info;
}

- (NSString *)filenameFromDisposition:(NSString *)disposition {
    // RFC 5987: filename*=UTF-8''na%C3%AFve%20file.mp4 — decode it first.
    NSRange starRange = [disposition rangeOfString:@"filename*=" options:NSCaseInsensitiveSearch];
    if (starRange.location != NSNotFound) {
        NSString *rest = [disposition substringFromIndex:NSMaxRange(starRange)];
        NSRange quote = [rest rangeOfString:@"''"];
        if (quote.location != NSNotFound) {
            rest = [rest substringFromIndex:NSMaxRange(quote)];
        }
        rest = [rest componentsSeparatedByString:@";"].firstObject;
        rest = [rest stringByTrimmingCharactersInSet:
                [NSCharacterSet characterSetWithCharactersInString:@"\"' "]];
        NSString *decoded = rest.stringByRemovingPercentEncoding;
        if (decoded.length) return decoded;
    }
    NSRange plain = [disposition rangeOfString:@"filename=" options:NSCaseInsensitiveSearch];
    if (plain.location == NSNotFound) return nil;
    NSString *rest = [disposition substringFromIndex:NSMaxRange(plain)];
    rest = [rest componentsSeparatedByString:@";"].firstObject;
    return [rest stringByTrimmingCharactersInSet:
            [NSCharacterSet characterSetWithCharactersInString:@"\"' "]];
}

- (void)apply:(NSDictionary *)info to:(MVSnifferItem *)item {
    item.probed = YES;
    if (!info) return;   // probe failed: the item is still usable, just unknown
    NSNumber *size = info[@"size"];
    if ([size isKindOfClass:NSNumber.class] && size.longLongValue > 0) item.totalBytes = size.longLongValue;
    NSString *mime = info[@"mime"];
    if ([mime isKindOfClass:NSString.class] && mime.length) {
        item.mimeType = mime;
        // The server's Content-Type can correct a URL that has no extension.
        MVSniffKind kind = [MVSnifferItem kindForURL:item.url mime:mime];
        if (kind != MVSniffKindUnknown) item.kind = kind;
    }
    NSString *filename = info[@"filename"];
    if ([filename isKindOfClass:NSString.class] && filename.length) item.suggestedFilename = filename;
    NSNumber *ranges = info[@"ranges"];
    if ([ranges isKindOfClass:NSNumber.class]) item.acceptsRanges = ranges.boolValue;
}

@end
