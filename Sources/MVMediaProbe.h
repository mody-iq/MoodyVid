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

/// The headers every request for `url` should carry: a desktop/mobile Safari UA,
/// the Referer of the page that found it, and the site's cookies.
+ (NSDictionary<NSString *, NSString *> *)headersForURL:(NSString *)url referer:(nullable NSString *)referer;

@end

NS_ASSUME_NONNULL_END
