#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// The in-app browser: a multi-tab WKWebView with a home page, a media sniffer
/// and a download sheet.
///
/// It is the front door of the app. Any page can be browsed, every media or file
/// link the page touches is collected, and whatever is found can be sent to the
/// download manager with one tap. A page whose stream cannot be reached directly
/// (a blob player, a site yt-dlp knows) is handed to the Python engine instead.
@interface MVBrowserViewController : UIViewController

/// Opens the browser on `url`. When `url` has no scheme, https:// is assumed.
/// Re-uses the parked browser when one exists.
+ (void)presentFrom:(UIViewController *)presenter url:(NSString *)url;

/// Sites shown as Quick Access tiles on Home. Derived from the browser's own
/// shortcut grid so the two lists cannot drift apart.
+ (NSArray<NSDictionary<NSString *, NSString *> *> *)quickAccessSites;

@end

NS_ASSUME_NONNULL_END
