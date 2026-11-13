#import "MVHTTPSession.h"
#import "MVCookiePolicy.h"
#import "MVMediaProbe.h"

@implementation MVHTTPSession

+ (NSURLSession *)sharedSession {
    static NSURLSession *session;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *config = NSURLSessionConfiguration.defaultSessionConfiguration;
        config.HTTPShouldSetCookies = NO;
        config.HTTPCookieStorage = nil;
        config.URLCredentialStorage = nil;
        config.URLCache = nil;
        session = [NSURLSession sessionWithConfiguration:config delegate:[MVHTTPSession new] delegateQueue:nil];
    });
    return session;
}

+ (void)handleRedirectForTask:(NSURLSessionTask *)task
                     response:(NSHTTPURLResponse *)response
                   newRequest:(NSURLRequest *)request
                   completion:(void (^)(NSURLRequest *))completion {
    // Strip inherited credentials before doing anything with the new URL.
    NSMutableURLRequest *safe = [MVCookiePolicy redirectRequest:request fromURL:response.URL cookieHeader:nil];
    if (!safe) { completion(nil); return; }

    NSURLRequest *original = task.originalRequest;
    NSString *context = [original valueForHTTPHeaderField:@"Referer"];
    if (!context.length && [original valueForHTTPHeaderField:@"Cookie"].length) {
        // A user-entered URL may have no Referer. Keep its initial URL as the
        // context rather than treating a cross-host redirect as first-party.
        context = original.URL.absoluteString;
    }
    // No original Referer and no original cookie means there is no proof this
    // request opted into browser cookies (e.g. a torrent tracker). Fail closed.
    if (context.length) {
        NSDictionary *headers = [MVMediaProbe headersForURL:safe.URL.absoluteString referer:context];
        NSString *cookie = headers[@"Cookie"];
        if (cookie.length) [safe setValue:cookie forHTTPHeaderField:@"Cookie"];
    }
    completion(safe);
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest *))completionHandler {
    [MVHTTPSession handleRedirectForTask:task response:response newRequest:request completion:completionHandler];
}

@end
