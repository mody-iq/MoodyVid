#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// The Files tab: browse Documents, with folders, sorting and a storage meter.
@interface MVFilesViewController : UIViewController

/// Set when this screen is pushed to show a subfolder instead of the root.
@property (nonatomic, copy, nullable) NSString *rootOverride;

/// Scrolls the list to `path` and flashes it, so a file reached from elsewhere
/// (a finished download) is visibly singled out. The path must be inside the
/// library; a path in a subfolder opens that folder first.
- (void)revealPath:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
