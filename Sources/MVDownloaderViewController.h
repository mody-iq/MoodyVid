#import <UIKit/UIKit.h>

@interface MVDownloaderViewController : UIViewController

@property (strong, nonatomic) UITextField *urlField;
@property (strong, nonatomic) UILabel *statusLabel;
@property (strong, nonatomic) UIProgressView *progressView;
@property (strong, nonatomic) UIButton *downloadButton;
@property (strong, nonatomic) UIButton *qualityButton;
@property (strong, nonatomic) NSString *selectedQuality;

@end
