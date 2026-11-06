#import <UIKit/UIKit.h>

@interface MVDownloaderViewController : UIViewController

@property (weak, nonatomic) IBOutlet UITextField *urlField;
@property (weak, nonatomic) IBOutlet UILabel *statusLabel;
@property (weak, nonatomic) IBOutlet UIButton *downloadButton;
@property (weak, nonatomic) IBOutlet UIProgressView *progressView;
@property (copy, nonatomic) NSString *selectedQuality;

@end
