#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN

/// One browser tab.
///
/// A tab owns its own WKWebView, which keeps its own history, scroll position and
/// page state. Only the active tab's web view is in the view hierarchy; the rest
/// stay alive in memory so switching back is instant and does not reload. The
/// sniffer's findings are kept separately, in MVSnifferStore, keyed by
/// `identifier`.
@interface MVBrowserTab : NSObject

@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, copy, nullable) NSString *title;
@property (nonatomic, copy, nullable) NSString *url;
/// Where the page was scrolled to, restored when the tab is reselected.
@property (nonatomic) double savedScrollY;
/// YES for a tab opened by a page (a popup), which is closed automatically.
@property (nonatomic) BOOL isPopup;
@property (nonatomic) BOOL loading;
@property (nonatomic) double progress;

/// YES when there is a title to show, else the host, else "New Tab".
- (NSString *)displayTitle;

@end

NS_ASSUME_NONNULL_END
