#import <UIKit/UIKit.h>
#import "MVDownloadRow.h"

NS_ASSUME_NONNULL_BEGIN

/// The bottom sheet shown when a download card is tapped: everything the app
/// knows about one download, plus its actions.
///
/// It only reads the row and forwards the verbs to `MVDownloadActions`, so it
/// works the same for a yt-dlp record and a manager task. The controller that
/// presents it keeps ownership of presenting the player and the share sheet.
@interface MVDetailsSheet : UIViewController

- (instancetype)initWithRow:(MVDownloadRow *)row;

/// Called when the user asks to play a finished file.
@property (nonatomic, copy, nullable) void (^onPlay)(MVDownloadRow *row);
/// Called when the user asks to share a finished file.
@property (nonatomic, copy, nullable) void (^onShare)(MVDownloadRow *row);
/// Called when the user asks to delete the row.
@property (nonatomic, copy, nullable) void (^onDelete)(MVDownloadRow *row);
/// Called when the user asks to save a finished file to Photos.
@property (nonatomic, copy, nullable) void (^onSaveToPhotos)(MVDownloadRow *row);

@end

NS_ASSUME_NONNULL_END
