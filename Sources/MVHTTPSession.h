#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A shared session for probes/stream requests. It follows redirects without
/// forwarding the previous URL's cookies or cross-origin authorization.
@interface MVHTTPSession : NSObject <NSURLSessionTaskDelegate>

+ (NSURLSession *)sharedSession;

/// Also used by MVFastDownloader, which owns its own streaming sessions.
+ (void)handleRedirectForTask:(NSURLSessionTask *)task
                     response:(NSHTTPURLResponse *)response
                   newRequest:(NSURLRequest *)request
                   completion:(void (^)(NSURLRequest *_Nullable request))completion;

@end

NS_ASSUME_NONNULL_END
