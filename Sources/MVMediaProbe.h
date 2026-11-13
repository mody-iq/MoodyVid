#import <Foundation/Foundation.h>
#import "MVSnifferItem.h"

NS_ASSUME_NONNULL_BEGIN

/// Asks a server what a URL is before the app commits to downloading it.
///
/// A HEAD request gives size, Content-Type, Accept-Ranges and the filename from
/// Content-Disposition without transferring the file. Some servers answer HEAD
/// with 405 or lie about Range support, so a failed HEAD falls back to a one-byte
/// ranged GET. Everything is best effort: a probe that fails leaves the item
/// usable, just without a known size.
///
/// The browser's cookies, User-Agent and Referer are attached, because a CDN
/// usually refuses a request without the Referer the page sent.
@interface MVMediaProbe : NSObject

+ (instancetype)shared;

/// Probes `item` and fills in totalBytes, mimeType, suggestedFilename,
/// acceptsRanges and probed. `completion` always runs on the main queue.
- (void)probe:(MVSnifferItem *)item completion:(void (^_Nullable)(MVSnifferItem *item))completion;

/// Probes the first entry of `items` at a time, then calls `completion` once with
/// the same array. Used when a tab is opened so a page's whole list is measured
/// without hammering the server all at once.
- (void)probeAll:(NSArray<MVSnifferItem *> *)items completion:(void (^_Nullable)(void))completion;

/// Headers for this URL, with a privacy-preserving Referer and cookies filtered
/// against both the target and the page. Cookie retrieval is best-effort and
/// normally happens off the main thread; the main thread never waits for WebKit.
+ (NSDictionary<NSString *, NSString *> *)headersForURL:(NSString *)url referer:(nullable NSString *)referer;

/// Also applies custom non-cookie headers. Stored/raw Cookie and Cookie2 values
/// are ignored; fresh, scoped browser cookies are selected for every request.
+ (NSDictionary<NSString *, NSString *> *)headersForURL:(NSString *)url
                                                 referer:(nullable NSString *)referer
                                       additionalHeaders:(nullable NSDictionary<NSString *, NSString *> *)additionalHeaders;

/// Suspend cookie snapshots while website data is being cleared, then discard
/// any in-flight snapshot before enabling them again. Already-created requests
/// and running downloads are not cancelled.
+ (void)beginClearingBrowserCookies;
+ (void)finishClearingBrowserCookies;

@end

NS_ASSUME_NONNULL_END
