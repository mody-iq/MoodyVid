#import <UIKit/UIKit.h>
#import "MVPython.h"

@interface MVDownloaderViewController : UIViewController <UITextFieldDelegate>
@property (strong, nonatomic) UITextField *urlField;
@property (strong, nonatomic) UILabel *statusLabel;
@property (strong, nonatomic) UIProgressView *progressView;
@property (strong, nonatomic) UIButton *downloadButton;
@property (strong, nonatomic) UIButton *qualityButton;
@property (strong, nonatomic) NSString *selectedQuality;
@end

@implementation MVDownloaderViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.selectedQuality = @"1080p";

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
    [self.qualityButton setTitle:@"الجودة: 1080p" forState:UIControlStateNormal];
    self.qualityButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [self.qualityButton addTarget:self action:@selector(showQualityMenu) forControlEvents:UIControlEventTouchUpInside];

    self.downloadButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.downloadButton setTitle:@"تحميل" forState:UIControlStateNormal];
    self.downloadButton.titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    self.downloadButton.backgroundColor = UIColor.systemBlueColor;
    self.downloadButton.layer.cornerRadius = 12;
    [self.downloadButton addTarget:self action:@selector(startDownload) forControlEvents:UIControlEventTouchUpInside];

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.text = @"هل await الرابط";
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
    [alert addAction:[UIAlertAction actionWithTitle:@"1080p" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        self.selectedQuality = @"1080p";
        [self.qualityButton setTitle:@"الجودة: 1080p" forState:UIControlStateNormal];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"720p" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        self.selectedQuality = @"720p";
        [self.qualityButton setTitle:@"الجودة: 720p" forState:UIControlStateNormal];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"صوت فقط (MP3)" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
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
            if (error) {
                self.statusLabel.text = [@"فشل: " stringByAppendingString:(error ?: @"خطأ غير معروف")];
                self.statusLabel.textColor = UIColor.systemRedColor;
                return;
            }
            self.statusLabel.text = @"تم التحميل، جاري الحفظ في الصور...";
            self.statusLabel.textColor = UIColor.systemBlueColor;
            [[MVDownloadEngine shared] saveToPhotos:filePath presentingViewController:self completion:^(BOOL success, NSString *err) {
                if (success) {
                    self.statusLabel.text = @"تم الحفظ في الصور بنجاح ✅";
                    self.statusLabel.textColor = UIColor.systemGreenColor;
                } else {
                    self.statusLabel.text = [@"فشل الحفظ: " stringByAppendingString:(err ?: @"خطأ غير معروف")];
                    self.statusLabel.textColor = UIColor.systemRedColor;
                }
            }];
        });
    }];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

@end
