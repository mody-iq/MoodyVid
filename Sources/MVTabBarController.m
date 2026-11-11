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
    // The browser queues a download and then asks the shell to show the list, so
    // the tap has a visible result even when the browser was opened from Home.
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(showDownloadsTab)
                                               name:@"MVShowDownloadsTabNotification" object:nil];
    // A finished download asks to be pointed at in the Files tab.
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(revealFile:)
                                               name:@"MVRevealFileNotification" object:nil];
}

- (void)showDownloadsTab {
    if (self.selectedIndex != 1) self.selectedIndex = 1;
}

/// Switches to Files and asks it to highlight the file. The pop-to-root first
/// makes sure the file is revealed in the library root, not inside whatever
/// folder the user last browsed into.
- (void)revealFile:(NSNotification *)note {
    NSString *path = note.userInfo[@"path"];
    if (!path.length || self.viewControllers.count < 3) return;
    self.selectedIndex = 2;
    UINavigationController *filesNav = self.viewControllers[2];
    [filesNav popToRootViewControllerAnimated:NO];
    if ([filesNav.topViewController isKindOfClass:MVFilesViewController.class]) {
        [(MVFilesViewController *)filesNav.topViewController revealPath:path];
    }
}

- (UIViewController *)wrap:(UIViewController *)root symbol:(NSString *)symbol {
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:root];
    nav.navigationBar.prefersLargeTitles = NO;
    // SF Symbols are in the system, so the tabs need no image assets.
    nav.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"" image:[UIImage systemImageNamed:symbol] tag:0];
    return nav;
}

- (void)applyTheme {
    BOOL dark = MVTheme.shared.isDark;
    self.overrideUserInterfaceStyle = dark ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight;

    // A flat surface behind the whole shell: one colour, no wallpaper layer and
    // no frosted bars to re-composite. Each tab paints its own background.
    self.view.backgroundColor = [MVTheme background];

    // Flat chrome: an opaque bar colour, no blur. The chrome is part of the
    // same surface as the content, so there is nothing to frost and nothing to
    // re-composite while scrolling.
    UIColor *chrome = dark ? [UIColor colorWithWhite:0.07 alpha:1.0]
                           : [UIColor colorWithWhite:0.98 alpha:1.0];
    UIColor *hairline = dark ? [UIColor colorWithWhite:1.0 alpha:0.12]
                             : [UIColor colorWithWhite:0.0 alpha:0.12];

    UITabBarAppearance *bar = [UITabBarAppearance new];
    [bar configureWithOpaqueBackground];
    bar.backgroundColor = chrome;
    bar.shadowColor = hairline;
    bar.stackedLayoutAppearance.normal.iconColor = [MVTheme secondaryText];
    bar.stackedLayoutAppearance.normal.titleTextAttributes = @{NSForegroundColorAttributeName: [MVTheme secondaryText]};
    bar.stackedLayoutAppearance.selected.iconColor = [MVTheme accent];
    bar.stackedLayoutAppearance.selected.titleTextAttributes = @{NSForegroundColorAttributeName: [MVTheme accent]};
    self.tabBar.standardAppearance = bar;
    self.tabBar.scrollEdgeAppearance = bar;

    UINavigationBarAppearance *navBar = [UINavigationBarAppearance new];
    [navBar configureWithOpaqueBackground];
    navBar.backgroundColor = chrome;
    navBar.shadowColor = hairline;
    // Inline titles, one comfortable size on every screen: semibold 17 rather
    // than the oversized large-title treatment.
    navBar.titleTextAttributes = @{NSForegroundColorAttributeName: [MVTheme text],
                                   NSFontAttributeName: [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold]};
    // Titles stay at the inline size on every screen, so this attribute set is
    // unused; it is kept in sync anyway in case a large title ever returns.
    navBar.largeTitleTextAttributes = @{NSForegroundColorAttributeName: [MVTheme text],
                                        NSFontAttributeName: [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold]};
    for (UINavigationController *nav in self.viewControllers) {
        nav.navigationBar.prefersLargeTitles = NO;
        nav.navigationBar.standardAppearance = navBar;
        nav.navigationBar.scrollEdgeAppearance = navBar;
        nav.navigationBar.compactAppearance = navBar;
        nav.navigationBar.tintColor = [MVTheme accent];
        nav.view.backgroundColor = chrome;
    }

    NSArray<NSString *> *titles = @[@"Home", @"Downloads", @"Files", @"More"];
    [self.viewControllers enumerateObjectsUsingBlock:^(UIViewController *vc, NSUInteger i, BOOL *stop) {
        vc.tabBarItem.title = [MVLang t:titles[i]];
    }];

    // Arabic reads right-to-left: mirror the whole shell so the first tab sits on
    // the right, which is what an Arabic speaker expects.
    self.view.semanticContentAttribute = MVLang.shared.isRTL
        ? UISemanticContentAttributeForceRightToLeft
        : UISemanticContentAttributeForceLeftToRight;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (previousTraitCollection.userInterfaceStyle != self.traitCollection.userInterfaceStyle) {
        [self applyTheme];
    }
}

@end
