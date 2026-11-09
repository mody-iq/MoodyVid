#import <UIKit/UIKit.h>
#import "MVSnifferItem.h"

NS_ASSUME_NONNULL_BEGIN

/// The sheet that lists everything the sniffer found in a tab.
///
/// Rows are grouped by kind (videos first, then audio, files, streams), each with
/// its own icon, name and size. Every row can be downloaded or its link copied,
/// and the sheet offers "Download all" plus a "download this page with yt-dlp"
/// action for pages whose stream the sniffer cannot reach directly.
@interface MVSnifferSheetViewController : UIViewController

- (instancetype)initWithTabIdentifier:(NSString *)tabID
                             pageURL:(nullable NSString *)pageURL
                           pageTitle:(nullable NSString *)pageTitle;

/// Called with the items the user asked to download (one row, or all).
@property (nonatomic, copy, nullable) void (^onDownload)(NSArray<MVSnifferItem *> *items);
/// Called when the user asks to hand the page to yt-dlp.
@property (nonatomic, copy, nullable) void (^onDownloadPageWithYTDlp)(NSString *pageURL, NSString *pageTitle);

@end

NS_ASSUME_NONNULL_END
