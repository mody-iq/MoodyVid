#import <UIKit/UIKit.h>
#import "MVSnifferItem.h"

NS_ASSUME_NONNULL_BEGIN

/// The one sheet a download button opens: what to fetch, and at what quality.
///
/// A video page shows the quality list first, because that is the choice the
/// user came to make; the links the sniffer found are listed under it as plain
/// files. There is no second sheet — picking a quality starts the download and
/// closes this one, which is what made the old two-step flow feel heavy.
@interface MVSnifferSheetViewController : UIViewController

- (instancetype)initWithTabIdentifier:(NSString *)tabID
                             pageURL:(nullable NSString *)pageURL
                           pageTitle:(nullable NSString *)pageTitle;

/// Called with the file rows the user tapped.
@property (nonatomic, copy, nullable) void (^onDownload)(NSArray<MVSnifferItem *> *items);
/// Called when the user picks a quality for the page itself (yt-dlp's job).
@property (nonatomic, copy, nullable) void (^onDownloadPage)(NSString *pageURL, NSString *pageTitle, NSString *quality);

@end

NS_ASSUME_NONNULL_END
