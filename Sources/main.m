#import <UIKit/UIKit.h>
#import "MVPython.h"

@interface MVRootViewController : UIViewController
@property (strong, nonatomic) UITextView *statusView;
@property (strong, nonatomic) UILabel *badge;
@end

@implementation MVRootViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    UILabel *title = [[UILabel alloc] init];
    title.text = @"MoodyVid";
    title.font = [UIFont systemFontOfSize:34 weight:UIFontWeightBold];
    title.textColor = UIColor.labelColor;
    title.textAlignment = NSTextAlignmentCenter;

    NSDictionary *bundleInfo = NSBundle.mainBundle.infoDictionary;
    NSString *version = bundleInfo[@"CFBundleShortVersionString"] ?: @"?";
    NSString *build = bundleInfo[@"CFBundleVersion"] ?: @"?";

    UILabel *info = [[UILabel alloc] init];
    info.text = [NSString stringWithFormat:@"v%@ (%@)\niOS %@ · %@",
                 version, build,
                 UIDevice.currentDevice.systemVersion,
                 UIDevice.currentDevice.model];
    info.font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightRegular];
    info.textColor = UIColor.secondaryLabelColor;
    info.textAlignment = NSTextAlignmentCenter;
    info.numberOfLines = 0;

    self.badge = [[UILabel alloc] init];
    self.badge.text = @"Engine: starting…";
    self.badge.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    self.badge.textColor = UIColor.secondaryLabelColor;
    self.badge.textAlignment = NSTextAlignmentCenter;

    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[title, info, self.badge]];
    header.axis = UILayoutConstraintAxisVertical;
    header.alignment = UIStackViewAlignmentCenter;
    header.spacing = 8;
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:header];

    self.statusView = [[UITextView alloc] init];
    self.statusView.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusView.editable = NO;
    self.statusView.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.statusView.layer.cornerRadius = 12;
    self.statusView.textContainerInset = UIEdgeInsetsMake(12, 10, 12, 10);
    self.statusView.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    self.statusView.textColor = UIColor.labelColor;
    self.statusView.text = @"Starting the Python engine…";
    [self.view addSubview:self.statusView];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:safe.topAnchor constant:32],
        [header.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [header.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:24],
        [header.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-24],
        [self.statusView.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:24],
        [self.statusView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.statusView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.statusView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-16]
    ]];

    [self runEngineTest];
}

- (void)runEngineTest {
    __weak MVRootViewController *weakSelf = self;
    [[MVPython shared] call:@"mvboot" function:@"info" args:@[]
                 completion:^(NSDictionary *result, NSString *error) {
        MVRootViewController *strongSelf = weakSelf;
        if (!strongSelf) return;

        if (error) {
            strongSelf.badge.text = @"Engine: ERROR";
            strongSelf.badge.textColor = UIColor.systemRedColor;
            strongSelf.statusView.text = error;
            return;
        }

        BOOL hasProblem = NO;
        NSMutableString *text = [NSMutableString string];
        for (NSString *key in [result.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            if ([key hasSuffix:@"_error"]) hasProblem = YES;
            [text appendFormat:@"%@: %@\n", key, result[key]];
        }
        if (!result[@"yt_dlp"]) hasProblem = YES;

        strongSelf.badge.text = hasProblem ? @"Engine: PARTIAL" : @"Engine: OK";
        strongSelf.badge.textColor = hasProblem ? UIColor.systemOrangeColor : UIColor.systemGreenColor;
        strongSelf.statusView.text = text;
    }];
}

@end

@interface MVAppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation MVAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[MVRootViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([MVAppDelegate class]));
    }
}
