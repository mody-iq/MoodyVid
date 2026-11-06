#import "MVDownloaderViewController.h"
#import "MVDownloadEngine.h"

@interface MVDownloaderViewController () <UITextFieldDelegate>
@end

@implementation MVDownloaderViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.selectedQuality = @"best";

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];

    UIView *content = [[UIView alloc] init];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:content];

    UILabel *title = [[UILabel alloc] init];
    title.text = @"تحميل فيديو";
    title.font = [UIFont systemFontOfSize:28 weight:UIFontWeightBold];
    title.textColor = UIColor.labelColor;
    title.textAlignment = NSTextAlignmentCenter;

    self.urlField = [[UITextField alloc] init];
    self.urlField.placeholder = @"لصق رابط الفيديو هنا";
    self.urlField.borderStyle = UITextBorderStyleRoundedRect;
    self.urlField.font = [UIFont systemFontOfSize:17];
    self.urlField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.urlField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.urlField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.urlField.returnKeyType = UIReturnKeyDone;
    self.urlField.delegate = self;

    self.qualityButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.qualityButton setTitle:@"الجودة: أفضل جودة" forState:UIControlStateNormal];
    self.qualityButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [self.qualityButton addTarget:self action:@selector(showQualityMenu) forControlEvents:UIControlEventTouchUpInside];

    self.downloadButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.downloadButton setTitle:@"تحميل" forState:UIControlStateNormal];
    // UIButtonTypeSystem tints its title with the system accent colour, which is
    // unreadable on the blue background we set below.
    [self.downloadButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [self.downloadButton setTitleColor:[UIColor.whiteColor colorWithAlphaComponent:0.6] forState:UIControlStateDisabled];
    self.downloadButton.titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    self.downloadButton.backgroundColor = UIColor.systemBlueColor;
    self.downloadButton.layer.cornerRadius = 12;
    [self.downloadButton addTarget:self action:@selector(startDownload) forControlEvents:UIControlEventTouchUpInside];

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.text = @"أدخل رابط الفيديو";
    self.statusLabel.font = [UIFont systemFontOfSize:15];
    self.statusLabel.textColor = UIColor.secondaryLabelColor;
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 0;

    self.progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.progressView.progress = 0.0f;
    self.progressView.hidden = YES;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[title, self.urlField, self.qualityButton, self.downloadButton, self.statusLabel, self.progressView]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentFill;
    stack.spacing = 16;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:stack];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [content.leadingAnchor constraintEqualToAnchor:scroll.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:scroll.trailingAnchor],
        [content.topAnchor constraintEqualToAnchor:scroll.topAnchor],
        [content.bottomAnchor constraintEqualToAnchor:scroll.bottomAnchor],
        [content.widthAnchor constraintEqualToAnchor:scroll.widthAnchor],
        [stack.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [stack.widthAnchor constraintEqualToAnchor:content.widthAnchor constant:-48],
        [stack.topAnchor constraintEqualToAnchor:content.topAnchor constant:24],
        [stack.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-24],
        [self.urlField.heightAnchor constraintEqualToConstant:44],
        [self.qualityButton.heightAnchor constraintEqualToConstant:44],
        [self.downloadButton.heightAnchor constraintEqualToConstant:52],
        [self.progressView.heightAnchor constraintEqualToConstant:4]
    ]];
}

- (void)showQualityMenu {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"اختر الجودة"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [alert addAction:[UIAlertAction actionWithTitle:@"أفضل جودة متاحة" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        self.selectedQuality = @"best";
        [self.qualityButton setTitle:@"الجودة: أفضل جودة" forState:UIControlStateNormal];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"حتى 720p" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        self.selectedQuality = @"720p";
        [self.qualityButton setTitle:@"الجودة: حتى 720p" forState:UIControlStateNormal];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"حتى 480p" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        self.selectedQuality = @"480p";
        [self.qualityButton setTitle:@"الجودة: حتى 480p" forState:UIControlStateNormal];
    }]];
    // The file keeps its original sound container (usually M4A); we do not transcode.
    [alert addAction:[UIAlertAction actionWithTitle:@"صوت فقط (M4A)" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        self.selectedQuality = @"audio";
        [self.qualityButton setTitle:@"الجودة: صوت فقط" forState:UIControlStateNormal];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)startDownload {
    NSString *url = self.urlField.text;
    if (!url.length) {
        self.statusLabel.text = @"الرجاء لصق رابط أولاً";
        self.statusLabel.textColor = UIColor.systemRedColor;
        return;
    }

    self.downloadButton.enabled = NO;
    self.downloadButton.alpha = 0.6f;
    self.progressView.hidden = NO;
    self.progressView.progress = 0.0f;
    self.statusLabel.text = @"جاري التحميل...";
    self.statusLabel.textColor = UIColor.secondaryLabelColor;

    [[MVDownloadEngine shared] downloadURL:url quality:self.selectedQuality completion:^(NSString *filePath, NSString *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.downloadButton.enabled = YES;
            self.downloadButton.alpha = 1.0f;
            self.progressView.hidden = YES;
            // A file path means the download itself worked; a non-nil error is then
            // only a warning about saving it to the photo library.
            if (filePath.length) {
                self.statusLabel.text = error ?: @"تم التحميل بنجاح";
                self.statusLabel.textColor = error ? UIColor.systemOrangeColor : UIColor.systemGreenColor;
                return;
            }
            self.statusLabel.text = [@"فشل: " stringByAppendingString:(error ?: @"خطأ غير معروف")];
            self.statusLabel.textColor = UIColor.systemRedColor;
        });
    }];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

@end
