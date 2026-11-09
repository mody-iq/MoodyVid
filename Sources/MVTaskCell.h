#import <UIKit/UIKit.h>
#import "MVDownloadTask.h"

NS_ASSUME_NONNULL_BEGIN

/// A Downloads row for a task the new manager owns (a direct file today; HLS and
/// torrents later). It follows the existing row design: a title, a status line,
/// and a round trailing button that is a progress ring while running and an icon
/// when finished.
@interface MVTaskCell : UITableViewCell

- (void)configureWithTask:(MVDownloadTask *)task;

/// The trailing button's action. The controller decides what it means for the
/// task's current state (pause, resume or open the menu).
@property (nonatomic, copy, nullable) void (^onAction)(void);

@end

NS_ASSUME_NONNULL_END
