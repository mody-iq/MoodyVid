#import <UIKit/UIKit.h>

@interface MVRootViewController : UIViewController
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

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[title, info]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:24],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-24]
    ]];
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
