#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Lets the user choose entries from a supported playlist before queueing them.
@interface MVPlaylistViewController : UITableViewController
- (instancetype)initWithURL:(NSString *)url;
+ (void)presentFrom:(UIViewController *)presenter url:(NSString *)url;
@end

NS_ASSUME_NONNULL_END
