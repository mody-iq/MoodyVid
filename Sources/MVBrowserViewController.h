#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// The in-app browser, opened from the Quick Access tiles on Home.
///
/// It is a plain WKWebView with an injected script that finds the video the page
/// is playing and puts a Download button over it. Some sites hide their stream
/// behind blob URLs or DRM, so the sniffer also records media requests the page
/// makes; the user picks from whatever was found.
@interface MVBrowserViewController : UIViewController

/// Opens the browser on `url`. When `url` has no scheme, https:// is assumed.
+ (void)presentFrom:(UIViewController *)presenter url:(NSString *)url;

/// Sites shown as Quick Access tiles on Home. Each is name, symbol, hex tint and
/// the address the tile opens.
+ (NSArray<NSDictionary<NSString *, NSString *> *> *)quickAccessSites;

@end

NS_ASSUME_NONNULL_END
