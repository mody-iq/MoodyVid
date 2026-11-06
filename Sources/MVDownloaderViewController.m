#import <UIKit/UIKit.h>
#import "MVPython.h"

NS_ASSUME_NONNULL_BEGIN

@interface MVDownloaderViewController : UIViewController
@end

@implementation MVDownloaderViewController {
    UITextField *_urlField;
    UILabel *_statusLabel;
    UIProgressView *_progressView;
    UIButton *_downloadButton;
    UIButton *_qualityButton;
    NSString *_selectedQuality;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    _selectedQuality = @"1080p";

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

    _urlField = [[UITextField alloc] init];
    _urlField.placeholder = @"لصق رابط الفيديو هنا";
    _urlField.borderStyle = UITextBorderStyleRoundedRect;
    _urlField.font = [UIFont systemFontOfSize:17];
    _urlField.autocorrectionType = UITextAutocorrectionTypeNo;
    _urlField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _urlField.clearButtonMode = UITextFieldViewModeWhileEditing;
    _urlField.returnKeyType = UIReturnKeyDone;
    _urlField.delegate = self;

    _qualityButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_qualityButton setTitle:@"الجودة: 1080p" forState:UIControlStateNormal];
    [_qualityButton titleLabel].font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [_qualityButton addTarget:self action:@selector(showQualityMenu) forControlEvents:UIControlEventTouchUpInside];

    _downloadButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_downloadButton setTitle:@"تحميل" forState:UIControlStateNormal];
    [_downloadButton titleLabel].font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    _downloadButton.backgroundColor = UIColor.systemBlueColor;
    _downloadButton.layer.cornerRadius = 12;
    [_downloadButton addTarget:self action:@selector(startDownload) forControlEvents:UIControlEventTouchUpInside];

    _statusLabel = [[UILabel alloc] init];
    _statusLabel.text = @"هل await الرابط";
    _statusLabel.font = [UIFont systemFontOfSize:15];
    _statusLabel.textColor = UIColor.secondaryLabelColor;
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    _statusLabel.numberOfLines = 0;

    _progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    _progressView.progress = 0.0f;
    _progressView.hidden = YES;

    CGFloat spacing = 16;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[title, _urlField, _qualityButton, _downloadButton, _statusLabel, _progressView]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentFill;
    stack.spacing = spacing;
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
        [_urlField.heightAnchor constraintEqualToConstant:44],
        [_qualityButton.heightAnchor constraintEqualToConstant:44],
        [_downloadButton.heightAnchor constraintEqualToConstant:52],
        [_progressView.heightAnchor constraintEqualToConstant:4]
    ]];
}

- (void)showQualityMenu {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"اختر الجودة"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [alert addAction:[UIAlertAction actionWithTitle:@"1080p" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        _selectedQuality = @"1080p";
        [_qualityButton setTitle:@"الجودة: 1080p" forState:UIControlStateNormal];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"720p" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        _selectedQuality = @"720p";
        [_qualityButton setTitle:@"الجودة: 720p" forState:UIControlStateNormal];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"صوت فقط (MP3)" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        _selectedQuality = @"audio";
        [_qualityButton setTitle:@"الجودة: صوت فقط" forState:UIControlStateNormal];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)startDownload {
    NSString *url = _urlField.text;
    if (!url.length) {
        _statusLabel.text = @"الرجاء لصق رابط أولاً";
        _statusLabel.textColor = UIColor.systemRedColor;
        return;
    }

    _downloadButton.enabled = NO;
    _downloadButton.alpha = 0.6f;
    _progressView.hidden = NO;
    _progressView.progress = 0.0f;
    _statusLabel.text = @"جاري التحضير...";
    _statusLabel.textColor = UIColor.secondaryLabelColor;

    __weak MVDownloaderViewController *weakSelf = self;
    [[MVPython shared] call:@"mvboot" function:@"info" args:@[]
                 completion:^(NSDictionary *result, NSString *error) {
        MVDownloaderViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (error) {
            strongSelf._statusLabel.text = @"المحرك غير جاهز: " + (error ?: @"خطأ غير معروف");
            strongSelf._statusLabel.textColor = UIColor.systemRedColor;
            strongSelf._downloadButton.enabled = YES;
            strongSelf._downloadButton.alpha = 1.0f;
            strongSelf._progressView.hidden = YES;
            return;
        }
        strongSelf._statusLabel.text = @"جاري التحليل...";
        // لاحقًا هنا سنستدعي دالة التحميل الفعلية من yt-dlp عبر Python
        strongSelf._statusLabel.text = @"تم 준비 الرابط (سيبدأ التحميل في الخطوة التالية)";
        strongSelf._statusLabel.textColor = UIColor.systemGreenColor;
        strongSelf._downloadButton.enabled = YES;
        strongSelf._downloadButton.alpha = 1.0f;
        strongSelf._progressView.hidden = YES;
    }];
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

@end

NS_ASSUME_NONNULL_END
