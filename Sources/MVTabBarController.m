#import "MVTabBarController.h"
#import "MVLang.h"
#import "MVTheme.h"
#import "MVDownloaderViewController.h"
#import "MVDownloadsViewController.h"
#import "MVFilesViewController.h"
#import "MVSettingsViewController.h"

@implementation MVTabBarController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.viewControllers = @[
        [self wrap:[[MVDownloaderViewController alloc] init] symbol:@"house.fill"],
        [self wrap:[[MVDownloadsViewController alloc] init] symbol:@"arrow.down.circle.fill"],
        [self wrap:[[MVFilesViewController alloc] init] symbol:@"folder.fill"],
        [self wrap:[[MVSettingsViewController alloc] init] symbol:@"gearshape.fill"],
    ];

    [self applyTheme];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applyTheme)
                                               name:MVLangDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applyTheme)
                                               name:MVThemeDidChangeNotification object:nil];
}

- (UIViewController *)wrap:(UIViewController *)root symbol:(NSString *)symbol {
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:root];
    nav.navigationBar.prefersLargeTitles = YES;
    // SF Symbols are in the system, so the tabs need no image assets.
    nav.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"" image:[UIImage systemImageNamed:symbol] tag:0];
    return nav;
}

- (void)applyTheme {
    BOOL dark = MVTheme.shared.isDark;
    self.overrideUserInterfaceStyle = dark ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight;

    UITabBarAppearance *bar = [UITabBarAppearance new];
    [bar configureWithOpaqueBackground];
    bar.backgroundColor = [MVTheme background];
    bar.shadowColor = [[MVTheme separator] colorWithAlphaComponent:dark ? 0.12 : 0.10];
    bar.stackedLayoutAppearance.normal.iconColor = [MVTheme secondaryText];
    bar.stackedLayoutAppearance.normal.titleTextAttributes = @{NSForegroundColorAttributeName: [MVTheme secondaryText]};
    bar.stackedLayoutAppearance.selected.iconColor = [MVTheme accent];
    bar.stackedLayoutAppearance.selected.titleTextAttributes = @{NSForegroundColorAttributeName: [MVTheme accent]};
    self.tabBar.standardAppearance = bar;
    self.tabBar.scrollEdgeAppearance = bar;

    UINavigationBarAppearance *navBar = [UINavigationBarAppearance new];
    [navBar configureWithOpaqueBackground];
    navBar.backgroundColor = [MVTheme background];
    navBar.shadowColor = [UIColor clearColor];
    navBar.titleTextAttributes = @{NSForegroundColorAttributeName: [MVTheme text]};
    navBar.largeTitleTextAttributes = @{NSForegroundColorAttributeName: [MVTheme text]};
    for (UINavigationController *nav in self.viewControllers) {
        nav.navigationBar.standardAppearance = navBar;
        nav.navigationBar.scrollEdgeAppearance = navBar;
        nav.navigationBar.tintColor = [MVTheme accent];
    }

    NSArray<NSString *> *titles = @[@"Home", @"Downloads", @"Files", @"Settings"];
    [self.viewControllers enumerateObjectsUsingBlock:^(UIViewController *vc, NSUInteger i, BOOL *stop) {
        vc.tabBarItem.title = [MVLang t:titles[i]];
    }];

    // Arabic reads right-to-left: mirror the whole shell so the first tab sits on
    // the right, which is what an Arabic speaker expects.
    self.view.semanticContentAttribute = MVLang.shared.isRTL
        ? UISemanticContentAttributeForceRightToLeft
        : UISemanticContentAttributeForceLeftToRight;
}

@end
