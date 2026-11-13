#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The browser-cookie and redirect policy shared by every native downloader.
/// The matching logic is kept separate from WebKit so it can be tested without a
/// browser, and never relies on the global Foundation cookie store.
@interface MVCookiePolicy : NSObject

/// Selects cookies valid for the target and the originating page. Because this
/// cannot reproduce all WebKit SameSite/partition rules, a cookie's domain must
/// cover both hosts and schemes must match. A missing context sends no cookies.
/// A leading dot permits subdomains; otherwise only the exact host matches.
/// Cookies exposing a partition key are excluded.
+ (NSArray<NSHTTPCookie *> *)cookies:(NSArray<NSHTTPCookie *> *)cookies
                       allowedForURL:(NSURL *)url
                          contextURL:(nullable NSURL *)contextURL
                                  at:(NSDate *)date;

/// Builds the Cookie header using Foundation's cookie formatter, or nil.
+ (nullable NSString *)cookieHeaderForURL:(NSURL *)url
                                  cookies:(NSArray<NSHTTPCookie *> *)cookies
                               contextURL:(nullable NSURL *)contextURL;

/// Keeps non-cookie custom headers, ignoring malformed keys/values. Raw cookie
/// headers have no reliable domain/path/expiry and are never persisted/replayed.
+ (NSDictionary<NSString *, NSString *> *)headersWithoutCookies:(nullable NSDictionary *)headers;

/// Implements a strict-origin-when-cross-origin Referer: strip userinfo and
/// fragments, send only the origin cross-origin, and omit HTTPS-to-HTTP values.
+ (nullable NSString *)safeReferer:(nullable NSString *)referer forURL:(NSURL *)target;

/// Returns a safe redirect request. An inherited Cookie header is always
/// removed and the caller supplies cookies selected for the *new* URL. Auth
/// headers are removed on an origin change; Referer is removed on downgrade.
/// Non-HTTP(S) redirects are rejected.
+ (nullable NSMutableURLRequest *)redirectRequest:(NSURLRequest *)request
                                         fromURL:(nullable NSURL *)sourceURL
                                    cookieHeader:(nullable NSString *)cookieHeader;

@end

NS_ASSUME_NONNULL_END
