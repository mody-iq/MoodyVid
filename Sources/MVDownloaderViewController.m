#import "MVDownloaderViewController.h"
#import "MVDownloadEngine.h"

@implementation MVDownloaderViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.selectedQuality = @"best";
    self.urlField.delegate = self;
    self.statusLabel.text = @"أدخل رابط الفيديو";
    self.progressView.hidden = YES;
    self.downloadButton.enabled = YES;
    self.downloadButton.alpha = 1.0f;
}

- (IBAction)downloadTapped:(id)sender {
    NSString *url = self.urlField.text;
    if (url.length == 0) {
        self.statusLabel.text = @"الرابط فارغ";
        self.statusLabel.textColor = UIColor.systemRedColor;
        return;
    }
    self.downloadButton.enabled = NO;
    self.downloadButton.alpha = 0.5f;
    self.progressView.hidden = NO;
    self.statusLabel.text = @"جاري التحليل...";
    self.statusLabel.textColor = UIColor.labelColor;

    [[MVDownloadEngine shared] downloadURL:url quality:self.selectedQuality completion:^(NSString *filePath, NSString *error) {
        self.downloadButton.enabled = YES;
        self.downloadButton.alpha = 1.0f;
        self.progressView.hidden = YES;
        if (error) {
            self.statusLabel.text = [@"المحرك غير جاهز: " stringByAppendingString:(error ?: @"خطأ غير معروف")];
            self.statusLabel.textColor = UIColor.systemRedColor;
        } else {
            self.statusLabel.text = @"تم التحميل بنجاح";
            self.statusLabel.textColor = UIColor.systemGreenColor;
        }
    }];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

@end
