#import "MVCookiePolicy.h"
#import "MVHTTPPolicy.h"

@implementation MVCookiePolicy

+ (NSInteger)portForURL:(NSURL *)url {
    if (url.port) return url.port.integerValue;
    if ([url.scheme.lowercaseString isEqualToString:@"https"]) return 443;
    if ([url.scheme.lowercaseString isEqualToString:@"http"]) return 80;
    return -1;
}

+ (BOOL)sameOrigin:(NSURL *)a other:(NSURL *)b {
    if (!a.host.length || !b.host.length || !a.scheme.length || !b.scheme.length) return NO;
    return [a.scheme.lowercaseString isEqualToString:b.scheme.lowercaseString] &&
           [a.host.lowercaseString isEqualToString:b.host.lowercaseString] &&
           [self portForURL:a] == [self portForURL:b];
}

+ (NSArray<NSHTTPCookie *> *)cookies:(NSArray<NSHTTPCookie *> *)cookies
                       allowedForURL:(NSURL *)url
                          contextURL:(NSURL *)contextURL
                                  at:(NSDate *)date {
    NSString *scheme = url.scheme.lowercaseString;
    if (!url.host.length || !contextURL.host.length ||
        !([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) ||
        ![scheme isEqualToString:contextURL.scheme.lowercaseString]) return @[];

    NSString *host = url.host.lowercaseString;
    NSString *contextHost = contextURL.host.lowercaseString;
    NSString *path = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:YES].percentEncodedPath;
    if (!path.length) path = @"/";
    NSMutableArray<NSHTTPCookie *> *allowed = [NSMutableArray array];
    for (NSHTTPCookie *cookie in cookies) {
        if (![cookie isKindOfClass:NSHTTPCookie.class]) continue;
        NSString *domain = cookie.domain.lowercaseString;
        if (!MVHTTPCookieDomainMatches(host.UTF8String, domain.UTF8String)) continue;
        // WebKit does not expose a complete SameSite context through
        // getAllCookies. Require the originating page to be in this cookie's
        // scope too, instead of replaying third-party cookies in native code.
        if (!MVHTTPCookieDomainMatches(contextHost.UTF8String, domain.UTF8String)) continue;
        if (!MVHTTPCookiePathMatches(path.UTF8String, cookie.path.UTF8String)) continue;
        if (cookie.isSecure && ![scheme isEqualToString:@"https"]) continue;
        if (cookie.expiresDate && [cookie.expiresDate compare:date] != NSOrderedDescending) continue;
        if (cookie.portList.count && ![cookie.portList containsObject:@([self portForURL:url])]) continue;
        // A partition key is represented in WebKit's NSHTTPCookie properties.
        // There is no public API here to reproduce the complete partition
        // context, so fail closed when the key is present.
        id partition = cookie.properties[@"StoragePartition"];
        if (partition && (![partition isKindOfClass:NSString.class] || [partition length])) continue;
        [allowed addObject:cookie];
    }
    // RFC 6265 recommends the more specific path first for duplicate names.
    [allowed sortUsingComparator:^NSComparisonResult(NSHTTPCookie *a, NSHTTPCookie *b) {
        if (a.path.length == b.path.length) return NSOrderedSame;
        return a.path.length > b.path.length ? NSOrderedAscending : NSOrderedDescending;
    }];
    return allowed;
}

+ (NSString *)cookieHeaderForURL:(NSURL *)url
                         cookies:(NSArray<NSHTTPCookie *> *)cookies
                      contextURL:(NSURL *)contextURL {
    NSArray<NSHTTPCookie *> *allowed = [self cookies:cookies allowedForURL:url contextURL:contextURL at:NSDate.date];
    if (!allowed.count) return nil;
    return [NSHTTPCookie requestHeaderFieldsWithCookies:allowed][@"Cookie"];
}

+ (NSDictionary<NSString *, NSString *> *)headersWithoutCookies:(NSDictionary *)headers {
    if (![headers isKindOfClass:NSDictionary.class]) return @{};
    NSMutableDictionary<NSString *, NSString *> *clean = [NSMutableDictionary dictionary];
    [headers enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
        if (![key isKindOfClass:NSString.class] || ![value isKindOfClass:NSString.class]) return;
        if ([key caseInsensitiveCompare:@"Cookie"] == NSOrderedSame ||
            [key caseInsensitiveCompare:@"Cookie2"] == NSOrderedSame) return;
        clean[key] = value;
    }];
    return clean;
}

+ (NSString *)safeReferer:(NSString *)referer forURL:(NSURL *)target {
    if (!referer.length || !target.host.length) return nil;
    NSURLComponents *components = [NSURLComponents componentsWithString:referer];
    NSURL *source = components.URL;
    NSString *sourceScheme = source.scheme.lowercaseString;
    NSString *targetScheme = target.scheme.lowercaseString;
    if (!source.host.length ||
        !([sourceScheme isEqualToString:@"http"] || [sourceScheme isEqualToString:@"https"]) ||
        !([targetScheme isEqualToString:@"http"] || [targetScheme isEqualToString:@"https"])) return nil;
    if ([sourceScheme isEqualToString:@"https"] && [targetScheme isEqualToString:@"http"]) return nil;
    components.user = nil;
    components.password = nil;
    components.fragment = nil;
    if (![self sameOrigin:source other:target]) {
        components.path = @"/";
        components.query = nil;
    }
    return components.URL.absoluteString;
}

+ (NSMutableURLRequest *)redirectRequest:(NSURLRequest *)request
                                 fromURL:(NSURL *)sourceURL
                            cookieHeader:(NSString *)cookieHeader {
    NSURL *target = request.URL;
    NSString *scheme = target.scheme.lowercaseString;
    if (!target.host.length || !([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"])) return nil;

    NSMutableURLRequest *safe = [request mutableCopy];
    // URLSession may otherwise copy the old header to a different host/path or
    // add cookies from the system's unrelated shared cookie storage.
    safe.HTTPShouldHandleCookies = NO;
    [safe setValue:nil forHTTPHeaderField:@"Cookie"];
    [safe setValue:nil forHTTPHeaderField:@"Cookie2"];
    if (![self sameOrigin:sourceURL other:target]) {
        [safe setValue:nil forHTTPHeaderField:@"Authorization"];
        [safe setValue:nil forHTTPHeaderField:@"Proxy-Authorization"];
    }
    NSString *referer = [safe valueForHTTPHeaderField:@"Referer"];
    [safe setValue:[self safeReferer:referer forURL:target] forHTTPHeaderField:@"Referer"];
    if (cookieHeader.length) [safe setValue:cookieHeader forHTTPHeaderField:@"Cookie"];
    return safe;
}

@end
