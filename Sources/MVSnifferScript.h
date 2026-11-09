#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The JavaScript the browser injects into every frame at document start.
///
/// It has one job: report URLs that look like media or files, and the page's own
/// media elements, to the native side through the `moodyvidSniff` message
/// handler. It never changes the page and never throws into it — every entry
/// point is wrapped, and a broken page simply produces no reports.
///
/// Notes that matter for correctness:
///  * `blob:` URLs cannot be fetched by the app, so the *page* URL is reported
///    instead and yt-dlp is asked to try the page.
///  * `data:` URLs are never reported (they are inline and useless to download).
///  * The script is injected in the page content world and runs in all frames, so
///    an iframe's video is found too.
@interface MVSnifferScript : NSObject

/// The script source. `handlerName` is the WKScriptMessageHandler name to post
/// to. The string is built once and cached.
+ (NSString *)sourceForHandler:(NSString *)handlerName;

@end

NS_ASSUME_NONNULL_END
