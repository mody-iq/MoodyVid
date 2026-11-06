#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// The Files tab: browse Documents, with folders, sorting and a storage meter.
@interface MVFilesViewController : UIViewController

/// Set when this screen is pushed to show a subfolder instead of the root.
@property (nonatomic, copy, nullable) NSString *rootOverride;

@end

NS_ASSUME_NONNULL_END
