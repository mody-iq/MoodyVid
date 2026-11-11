#import "MVBrowserViewController.h"
#import "MVBrowserHistory.h"
#import "MVBrowserHome.h"
#import "MVBrowserTab.h"
#import "MVLang.h"
#import "MVTheme.h"
#import "MVPaths.h"
#import "MVDownloadEngine.h"
#import "MVDownloadManager.h"
#import "MVPlayerCenter.h"
#import "MVAdBlocker.h"
#import "MVMediaProbe.h"
#import "MVSnifferItem.h"
#import "MVSnifferScript.h"
#import "MVSnifferSheet.h"
#import "MVSnifferStore.h"
#import "MVTabsViewController.h"
#import "MVLog.h"
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

static NSString *const kSnifferHandler = @"moodyvidSniff";
/// Eight tabs is what the switcher grid stays readable with on a phone.
static const NSUInteger kMaxTabs = 8;

#pragma mark - Weak script message handler

/// WKUserContentController retains its message handlers, which would keep the
/// browser alive forever. This proxy forwards messages but only holds the browser
/// weakly, so the retain cycle is broken.
@interface MVWeakScriptHandler : NSObject <WKScriptMessageHandler>
@property (nonatomic, weak, nullable) id<WKScriptMessageHandler> target;
+ (instancetype)handlerWithTarget:(id<WKScriptMessageHandler>)target;
@end

@implementation MVWeakScriptHandler
+ (instancetype)handlerWithTarget:(id<WKScriptMessageHandler>)target {
    MVWeakScriptHandler *proxy = [MVWeakScriptHandler new];
    proxy.target = target;
    return proxy;
}
- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message {
    [self.target userContentController:controller didReceiveScriptMessage:message];
}
@end

#pragma mark - Parked card

/// The floating chip that stands in for a minimized browser. Tapping it brings
/// the same page back; it is the browser's answer to the player's mini bar.
@interface MVBrowserParkedCard : UIView <UIGestureRecognizerDelegate>
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, copy, nullable) void (^onTap)(void);
@property (nonatomic, copy, nullable) void (^onClose)(void);
@end

@implementation MVBrowserParkedCard

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.backgroundColor = [MVTheme glassCard];
        self.layer.cornerRadius = 16;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.borderWidth = 0.5;
        self.layer.borderColor = [[MVTheme cardBorder] colorWithAlphaComponent:0.18].CGColor;
        self.layer.shadowColor = UIColor.blackColor.CGColor;
        self.layer.shadowOpacity = 0.3;
        self.layer.shadowRadius = 12;
        self.layer.shadowOffset = CGSizeMake(0, 5);

        UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:
                                     [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial]];
        glass.frame = self.bounds;
        glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        glass.layer.cornerRadius = 16;
        glass.layer.cornerCurve = kCACornerCurveContinuous;
        glass.layer.masksToBounds = YES;
        [self insertSubview:glass atIndex:0];

        UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"globe"]];
        icon.tintColor = [MVTheme accent];
        icon.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:icon];

        _titleLabel = [UILabel new];
        _titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        _titleLabel.textColor = [MVTheme text];
        _titleLabel.numberOfLines = 1;
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_titleLabel];

        UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
        [close setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
        close.tintColor = [MVTheme secondaryText];
        close.translatesAutoresizingMaskIntoConstraints = NO;
        [close addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:close];

        [NSLayoutConstraint activateConstraints:@[
            [icon.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:14],
            [icon.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [icon.widthAnchor constraintEqualToConstant:22],
            [icon.heightAnchor constraintEqualToConstant:22],

            [_titleLabel.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:10],
            [_titleLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:close.leadingAnchor constant:-8],

            [close.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-10],
            [close.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [close.widthAnchor constraintEqualToConstant:32],
            [close.heightAnchor constraintEqualToConstant:32],

            [self.heightAnchor constraintEqualToConstant:52],
        ]];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped)];
        tap.delegate = self;
        [self addGestureRecognizer:tap];
    }
    return self;
}

- (void)tapped { if (self.onTap) self.onTap(); }
- (void)closeTapped { if (self.onClose) self.onClose(); }

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)touch {
    return ![touch.view isKindOfClass:UIControl.class];
}

@end

/// The one browser parked at a time, plus its card. File statics because a parked
/// browser outlives the view controller that was dismissed to park it.
static MVBrowserViewController *gParkedBrowser = nil;
static UINavigationController *gParkedNav = nil;
static MVBrowserParkedCard *gParkedCard = nil;
static NSLayoutConstraint *gParkedCardBottom = nil;
static id gParkedObserver = nil;

#pragma mark - Browser

@interface MVBrowserViewController () <WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler,
                                       UITextFieldDelegate, MVBrowserHomeViewDelegate>
@property (nonatomic, strong) UIView *contentView;
@property (nonatomic, strong) MVBrowserHomeView *homeView;
@property (nonatomic, strong) UITextField *addressField;
@property (nonatomic, strong) UIProgressView *loadBar;
@property (nonatomic, strong) UIButton *backButton;
@property (nonatomic, strong) UIButton *forwardButton;
@property (nonatomic, strong) UIButton *homeButton;
@property (nonatomic, strong) UIButton *tabsButton;
@property (nonatomic, strong) UIButton *menuButton;
@property (nonatomic, strong) UIButton *sniffButton;
@property (nonatomic, strong) UILabel *sniffBadge;
@property (nonatomic, strong) UIButton *clipboardBanner;
@property (nonatomic, strong) UILabel *clipboardLabel;
@property (nonatomic, strong) UIView *toolbar;
@property (nonatomic, strong) UIStackView *toolbarRow;
/// The sniff button's distance from the bottom safe area, kept so the button can
/// step aside when the floating player bar appears under it.
@property (nonatomic, strong) NSLayoutConstraint *sniffBottomConstraint;

@property (nonatomic, strong) NSMutableArray<MVBrowserTab *> *tabs;
@property (nonatomic, copy, nullable) NSString *activeTabID;

@property (nonatomic, copy, nullable) NSString *initialURL;
@property (nonatomic) BOOL isPopup;
@property (nonatomic) BOOL desktopMode;
@property (nonatomic) BOOL showingHome;
@property (nonatomic) BOOL userGestureRecently;

- (void)minimize;
+ (void)restoreParked;
+ (void)discardParked;
+ (void)showParkedCard;
+ (void)hideParkedCard;
+ (void)moveParkedCardForPlayer;
+ (nullable UIViewController *)topPresenter;
@end

@implementation MVBrowserViewController

#pragma mark - Quick access sites

+ (NSArray<NSDictionary<NSString *, NSString *> *> *)quickAccessSites {
    NSMutableArray *out = [NSMutableArray array];
    for (MVBrowserShortcut *shortcut in [MVBrowserHomeView shortcuts]) {
        [out addObject:@{@"name": shortcut.name ?: @"",
                         @"symbol": shortcut.symbol ?: @"globe",
                         @"color": shortcut.color ?: @"#0FA0B0",
                         @"url": shortcut.url ?: @""}];
    }
    return out;
}

/// A current mobile Safari identity. Presenting this as the user agent is what
/// makes the official sign-in flows treat the app as a real browser.
+ (NSString *)safariUserAgent {
    static NSString *ua;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ua = @"Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15"
              " (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";
    });
    return ua;
}

+ (NSString *)desktopUserAgent {
    static NSString *ua;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ua = @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15"
              " (KHTML, like Gecko) Version/18.0 Safari/605.1.15";
    });
    return ua;
}

#pragma mark - Presentation

+ (void)presentFrom:(UIViewController *)presenter url:(NSString *)url {
    NSString *address = url;
    if (address.length && ![address containsString:@"://"]) {
        address = [@"https://" stringByAppendingString:address];
    }

    if (gParkedBrowser) {
        [MVBrowserViewController restoreParked];
        NSString *current = gParkedBrowser.activeTab.url ?: @"";
        if (address.length && ![address isEqualToString:current]) {
            [gParkedBrowser openURLInNewTab:address];
        }
        return;
    }

    MVBrowserViewController *browser = [MVBrowserViewController new];
    browser.initialURL = address;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:browser];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    [presenter presentViewController:nav animated:YES completion:nil];
}

#pragma mark - Tabs

- (MVBrowserTab *)activeTab {
    for (MVBrowserTab *tab in self.tabs) {
        if ([tab.identifier isEqualToString:self.activeTabID]) return tab;
    }
    return self.tabs.firstObject;
}

- (MVBrowserTab *)createTabWithURL:(NSString *)url isPopup:(BOOL)isPopup {
    if (self.tabs.count >= kMaxTabs) {
        for (MVBrowserTab *old in self.tabs.copy) {
            if (![old.identifier isEqualToString:self.activeTabID]) {
                [old.webView removeFromSuperview];
                [MVSnifferStore.shared clearTab:old.identifier];
                [self.tabs removeObject:old];
                break;
            }
        }
    }
    MVBrowserTab *tab = [MVBrowserTab new];
    tab.identifier = NSUUID.UUID.UUIDString;
    tab.isPopup = isPopup;
    tab.url = url;
    tab.webView = [self buildWebViewForTab:tab];
    [self.tabs addObject:tab];
    return tab;
}

- (void)selectTab:(MVBrowserTab *)tab {
    if (!tab) return;
    MVBrowserTab *previous = self.activeTab;
    if (previous && previous != tab) {
        [previous.webView evaluateJavaScript:@"window.scrollY || 0" completionHandler:^(id result, NSError *error) {
            if ([result isKindOfClass:NSNumber.class]) previous.savedScrollY = [result doubleValue];
        }];
        [previous.webView removeFromSuperview];
    }

    self.activeTabID = tab.identifier;
    [self.contentView addSubview:tab.webView];
    [NSLayoutConstraint activateConstraints:@[
        [tab.webView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
        [tab.webView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [tab.webView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [tab.webView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
    ]];

    if (!tab.url.length) {
        [self showHome];
    } else {
        self.showingHome = NO;
        self.homeView.hidden = YES;
        [self.view bringSubviewToFront:self.sniffButton];
        [self.view bringSubviewToFront:self.loadBar];
        [self.view bringSubviewToFront:self.clipboardBanner];
    }
    if (tab.savedScrollY > 0) {
        NSString *js = [NSString stringWithFormat:@"window.scrollTo(0, %f);", tab.savedScrollY];
        [tab.webView evaluateJavaScript:js completionHandler:nil];
    }
    [self syncToolbar];
    [self refreshSniffBadge];
}

- (void)openURLInNewTab:(NSString *)url {
    MVBrowserTab *tab = [self createTabWithURL:url isPopup:NO];
    [self selectTab:tab];
    if (url.length) {
        [tab.webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:url]]];
    }
}

- (void)closeTab:(NSString *)identifier {
    MVBrowserTab *closing = nil;
    for (MVBrowserTab *tab in self.tabs) {
        if ([tab.identifier isEqualToString:identifier]) { closing = tab; break; }
    }
    if (!closing) return;
    [closing.webView evaluateJavaScript:@"document.querySelectorAll('video,audio').forEach(function(m){try{m.pause()}catch(e){}})"
                      completionHandler:nil];
    [closing.webView removeFromSuperview];
    [MVSnifferStore.shared clearTab:identifier];
    [self.tabs removeObject:closing];

    if (!self.tabs.count) [self createTabWithURL:nil isPopup:NO];
    if ([identifier isEqualToString:self.activeTabID]) {
        [self selectTab:self.tabs.lastObject];
    }
    [self syncToolbar];
}

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    self.title = [MVLang t:@"Browser"];
    self.tabs = [NSMutableArray array];

    self.contentView = [UIView new];
    self.contentView.translatesAutoresizingMaskIntoConstraints = NO;
    self.contentView.backgroundColor = UIColor.clearColor;
    self.contentView.clipsToBounds = YES;
    [self.view addSubview:self.contentView];

    [self buildChrome];
    [self buildHomeView];

    MVBrowserTab *tab = [self createTabWithURL:self.initialURL isPopup:self.isPopup];
    self.activeTabID = tab.identifier;
    [self.contentView addSubview:tab.webView];
    [NSLayoutConstraint activateConstraints:@[
        [tab.webView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
        [tab.webView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [tab.webView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [tab.webView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
    ]];
    if (self.initialURL.length) {
        self.showingHome = NO;
        [tab.webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:self.initialURL]]];
    } else {
        [self showHome];
    }

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                     target:self action:@selector(close)];
    if (self.isPopup) {
        self.navigationItem.leftBarButtonItem =
            [[UIBarButtonItem alloc] initWithTitle:[MVLang t:@"Close"]
                                            style:UIBarButtonItemStylePlain
                                           target:self action:@selector(close)];
    } else {
        UIBarButtonItem *minimize = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"chevron.down"]
                                                                     style:UIBarButtonItemStylePlain
                                                                    target:self action:@selector(minimize)];
        minimize.accessibilityLabel = [MVLang t:@"Minimize"];
        self.navigationItem.leftBarButtonItem = minimize;
    }

    [[MVAdBlocker shared] prepare];
    [self refreshText];
    [self refreshSniffBadge];

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(snifferChanged:)
                                               name:MVSnifferStoreDidChangeNotification object:nil];
    // The floating player bar sits in the bottom-right corner too, so the sniff
    // button lifts above it when the bar is up.
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(playerBarVisibilityChanged:)
                                               name:MVPlayerBarVisibilityDidChangeNotification object:nil];
    [self updateSniffButtonForPlayerBar];
}

- (void)playerBarVisibilityChanged:(NSNotification *)note {
    [self updateSniffButtonForPlayerBar];
}

/// Keeps the sniff button clear of the floating player bar (80 pt tall, 54 pt
/// from the bottom safe area).
- (void)updateSniffButtonForPlayerBar {
    CGFloat offset = MVPlayerCenter.shared.floatingBarVisible ? -160 : -16;
    if (self.sniffBottomConstraint.constant == offset) return;
    self.sniffBottomConstraint.constant = offset;
    [UIView animateWithDuration:0.2 animations:^{ [self.view layoutIfNeeded]; }];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    for (MVBrowserTab *tab in self.tabs) {
        [tab.webView.configuration.userContentController removeScriptMessageHandlerForName:kSnifferHandler];
        @try { [tab.webView removeObserver:self forKeyPath:@"estimatedProgress"]; } @catch (NSException *e) {}
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [MVTheme applyWallpaperTo:self.view];
    [self refreshText];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self checkClipboardBanner];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    for (CALayer *layer in [self.view.layer.sublayers copy]) {
        if ([layer.name isEqualToString:@"MVWallpaperLayer"]) layer.frame = self.view.bounds;
    }
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (previousTraitCollection.userInterfaceStyle != self.traitCollection.userInterfaceStyle) {
        [MVTheme refreshWallpaperIfPattern:self.view];
    }
}

#pragma mark - Web view

- (WKWebView *)buildWebViewForTab:(MVBrowserTab *)tab {
    WKWebViewConfiguration *config = [WKWebViewConfiguration new];
    config.websiteDataStore = WKWebsiteDataStore.defaultDataStore;
    config.allowsInlineMediaPlayback = YES;
    config.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;
    config.applicationNameForUserAgent = @"Version/18.0 Mobile/15E148 Safari/604.1";

    WKUserContentController *ucc = [WKUserContentController new];
    [ucc addScriptMessageHandler:[MVWeakScriptHandler handlerWithTarget:self] name:kSnifferHandler];
    // Injected at document start, in every frame, in the page world, so a
    // request made before the page finishes loading is still reported.
    WKUserScript *script = [[WKUserScript alloc] initWithSource:[MVSnifferScript sourceForHandler:kSnifferHandler]
                                                    injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                 forMainFrameOnly:NO];
    [ucc addUserScript:script];
    config.userContentController = ucc;

    // The ad blocker compiles asynchronously; installing it when ready is enough.
    [[MVAdBlocker shared] ruleListWithCompletion:^(WKContentRuleList *ruleList) {
        if (ruleList) [ucc addContentRuleList:ruleList];
    }];

    WKWebView *web = [[WKWebView alloc] initWithFrame:CGRectZero configuration:config];
    web.customUserAgent = self.desktopMode ? [MVBrowserViewController desktopUserAgent]
                                           : [MVBrowserViewController safariUserAgent];
    web.translatesAutoresizingMaskIntoConstraints = NO;
    web.navigationDelegate = self;
    web.UIDelegate = self;
    web.allowsBackForwardNavigationGestures = YES;
    [web addObserver:self forKeyPath:@"estimatedProgress" options:NSKeyValueObservingOptionNew context:nil];
    return web;
}

- (void)syncToolbar {
    MVBrowserTab *tab = self.activeTab;
    if (tab && !self.showingHome) {
        self.addressField.text = tab.url.length ? tab.url : @"";
    } else {
        self.addressField.text = @"";
    }
    self.backButton.enabled = tab.webView.canGoBack;
    self.forwardButton.enabled = tab.webView.canGoForward;
    [self.tabsButton setTitle:[NSString stringWithFormat:@"%lu", (unsigned long)self.tabs.count]
                     forState:UIControlStateNormal];
}

#pragma mark - Home

- (void)buildHomeView {
    self.homeView = [[MVBrowserHomeView alloc] initWithFrame:CGRectZero];
    self.homeView.delegate = self;
    self.homeView.hidden = YES;
    [self.view addSubview:self.homeView];
    [NSLayoutConstraint activateConstraints:@[
        [self.homeView.topAnchor constraintEqualToAnchor:self.loadBar.bottomAnchor],
        [self.homeView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.homeView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.homeView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
    ]];
}

- (void)showHome {
    self.showingHome = YES;
    [self.homeView reload];
    self.homeView.hidden = NO;
    [self.view bringSubviewToFront:self.homeView];
    [self.view bringSubviewToFront:self.sniffButton];
    [self.view bringSubviewToFront:self.loadBar];
    [self.view bringSubviewToFront:self.clipboardBanner];
    [self syncToolbar];
    [self refreshSniffBadge];
}

- (void)homeView:(MVBrowserHomeView *)homeView didSelectURL:(NSString *)url title:(NSString *)title {
    [self loadAddress:url];
}

- (void)homeViewDidRequestClearHistory:(MVBrowserHomeView *)homeView {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[MVLang t:@"Clear history"]
                                                                  message:[MVLang t:@"This cannot be undone."]
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Clear history"] style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [MVBrowserHistory.shared clearHistory];
        [homeView reload];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Chrome

- (UIButton *)toolbarButton:(NSString *)symbol action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    button.tintColor = [MVTheme accent];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (NSLayoutConstraint *)sniffBottomConstraint {
    if (!_sniffBottomConstraint) {
        _sniffBottomConstraint =
            [self.sniffButton.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-16];
    }
    return _sniffBottomConstraint;
}

- (void)buildChrome {
    self.addressField = [UITextField new];
    self.addressField.translatesAutoresizingMaskIntoConstraints = NO;
    self.addressField.borderStyle = UITextBorderStyleRoundedRect;
    self.addressField.keyboardType = UIKeyboardTypeURL;
    self.addressField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.addressField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.addressField.returnKeyType = UIReturnKeyGo;
    self.addressField.delegate = self;
    self.addressField.backgroundColor = [MVTheme card];
    self.addressField.textColor = [MVTheme text];
    self.addressField.attributedPlaceholder =
        [[NSAttributedString alloc] initWithString:[MVLang t:@"Search or enter address"]
                                        attributes:@{NSForegroundColorAttributeName: [MVTheme secondaryText]}];

    self.backButton = [self toolbarButton:@"chevron.backward" action:@selector(goBack)];
    self.forwardButton = [self toolbarButton:@"chevron.forward" action:@selector(goForward)];
    self.homeButton = [self toolbarButton:@"house" action:@selector(homeTapped)];
    self.tabsButton = [self toolbarButton:@"square.on.square" action:@selector(showTabs)];
    self.menuButton = [self toolbarButton:@"ellipsis.circle" action:@selector(showMenu)];
    [self.tabsButton setTitleColor:[MVTheme accent] forState:UIControlStateNormal];
    self.tabsButton.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];

    self.toolbar = [UIView new];
    self.toolbar.translatesAutoresizingMaskIntoConstraints = NO;
    [MVTheme applyCardStyle:self.toolbar cornerRadius:22];
    [self.view addSubview:self.toolbar];

    self.toolbarRow = [[UIStackView alloc] initWithArrangedSubviews:
        @[self.backButton, self.forwardButton, self.addressField, self.homeButton, self.tabsButton, self.menuButton]];
    self.toolbarRow.translatesAutoresizingMaskIntoConstraints = NO;
    self.toolbarRow.axis = UILayoutConstraintAxisHorizontal;
    self.toolbarRow.spacing = 8;
    self.toolbarRow.alignment = UIStackViewAlignmentCenter;
    [self.toolbar addSubview:self.toolbarRow];

    // The sniffer button is a floating action button over the page: it carries the
    // count of everything found in this tab.
    self.sniffButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.sniffButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.sniffButton setImage:[UIImage systemImageNamed:@"arrow.down.doc.fill"] forState:UIControlStateNormal];
    self.sniffButton.tintColor = UIColor.whiteColor;
    self.sniffButton.backgroundColor = [MVTheme accent];
    self.sniffButton.layer.cornerRadius = 26;
    self.sniffButton.layer.shadowColor = UIColor.blackColor.CGColor;
    self.sniffButton.layer.shadowOpacity = 0.3;
    self.sniffButton.layer.shadowRadius = 8;
    self.sniffButton.layer.shadowOffset = CGSizeMake(0, 3);
    self.sniffButton.accessibilityLabel = [MVLang t:@"Found media"];
    [self.sniffButton addTarget:self action:@selector(showSnifferSheet) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.sniffButton];

    self.sniffBadge = [UILabel new];
    self.sniffBadge.translatesAutoresizingMaskIntoConstraints = NO;
    self.sniffBadge.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
    self.sniffBadge.textColor = UIColor.whiteColor;
    self.sniffBadge.backgroundColor = [MVTheme danger];
    self.sniffBadge.textAlignment = NSTextAlignmentCenter;
    self.sniffBadge.layer.cornerRadius = 9;
    self.sniffBadge.layer.masksToBounds = YES;
    self.sniffBadge.hidden = YES;
    [self.sniffButton addSubview:self.sniffBadge];

    self.loadBar = [UIProgressView new];
    self.loadBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.loadBar.progressTintColor = [MVTheme accent];
    [self.view addSubview:self.loadBar];

    [self buildClipboardBanner];

    [NSLayoutConstraint activateConstraints:@[
        [self.toolbar.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:6],
        [self.toolbar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:10],
        [self.toolbar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-10],
        [self.toolbar.heightAnchor constraintEqualToConstant:46],

        [self.loadBar.topAnchor constraintEqualToAnchor:self.toolbar.bottomAnchor constant:4],
        [self.loadBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.loadBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.loadBar.heightAnchor constraintEqualToConstant:2],

        [self.contentView.topAnchor constraintEqualToAnchor:self.loadBar.bottomAnchor],
        [self.contentView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.contentView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.contentView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],

        [self.toolbarRow.leadingAnchor constraintEqualToAnchor:self.toolbar.leadingAnchor constant:12],
        [self.toolbarRow.trailingAnchor constraintEqualToAnchor:self.toolbar.trailingAnchor constant:-12],
        [self.toolbarRow.topAnchor constraintEqualToAnchor:self.toolbar.topAnchor],
        [self.toolbarRow.bottomAnchor constraintEqualToAnchor:self.toolbar.bottomAnchor],

        [self.addressField.heightAnchor constraintEqualToConstant:34],

        [self.backButton.widthAnchor constraintEqualToConstant:30],
        [self.forwardButton.widthAnchor constraintEqualToConstant:30],
        [self.homeButton.widthAnchor constraintEqualToConstant:30],
        [self.menuButton.widthAnchor constraintEqualToConstant:30],
        [self.tabsButton.widthAnchor constraintGreaterThanOrEqualToConstant:30],

        [self.sniffButton.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-16],
        self.sniffBottomConstraint,
        [self.sniffButton.widthAnchor constraintEqualToConstant:52],
        [self.sniffButton.heightAnchor constraintEqualToConstant:52],

        [self.sniffBadge.topAnchor constraintEqualToAnchor:self.sniffButton.topAnchor constant:-2],
        [self.sniffBadge.trailingAnchor constraintEqualToAnchor:self.sniffButton.trailingAnchor constant:2],
        [self.sniffBadge.widthAnchor constraintGreaterThanOrEqualToConstant:18],
        [self.sniffBadge.heightAnchor constraintEqualToConstant:18],
    ]];
}

- (void)buildClipboardBanner {
    self.clipboardBanner = [UIButton buttonWithType:UIButtonTypeSystem];
    self.clipboardBanner.translatesAutoresizingMaskIntoConstraints = NO;
    self.clipboardBanner.backgroundColor = [MVTheme glassCard];
    [MVTheme applyCardStyle:self.clipboardBanner cornerRadius:14];
    self.clipboardBanner.hidden = YES;
    [self.clipboardBanner addTarget:self action:@selector(clipboardBannerTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.clipboardBanner];

    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"doc.on.clipboard"]];
    icon.tintColor = [MVTheme accent];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [self.clipboardBanner addSubview:icon];

    self.clipboardLabel = [UILabel new];
    self.clipboardLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.clipboardLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    self.clipboardLabel.textColor = [MVTheme text];
    self.clipboardLabel.numberOfLines = 1;
    self.clipboardLabel.text = [MVLang t:@"A link is on the clipboard — tap to open it"];
    [self.clipboardBanner addSubview:self.clipboardLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.clipboardBanner.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:14],
        [self.clipboardBanner.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-14],
        [self.clipboardBanner.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:58],
        [self.clipboardBanner.heightAnchor constraintEqualToConstant:44],

        [icon.leadingAnchor constraintEqualToAnchor:self.clipboardBanner.leadingAnchor constant:12],
        [icon.centerYAnchor constraintEqualToAnchor:self.clipboardBanner.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:20],
        [icon.heightAnchor constraintEqualToConstant:20],

        [self.clipboardLabel.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:10],
        [self.clipboardLabel.trailingAnchor constraintEqualToAnchor:self.clipboardBanner.trailingAnchor constant:-12],
        [self.clipboardLabel.centerYAnchor constraintEqualToAnchor:self.clipboardBanner.centerYAnchor],
    ]];
}

#pragma mark - Clipboard banner

/// Checks the pasteboard without reading it. iOS 16+ prompts the user before an
/// app may read the clipboard, and prompting on every launch is hostile, so the
/// banner only *offers*: the content is read when the user taps.
- (void)checkClipboardBanner {
    if (!UIPasteboard.generalPasteboard.hasStrings) {
        self.clipboardBanner.hidden = YES;
        return;
    }
    self.clipboardBanner.hidden = NO;
    [self.view bringSubviewToFront:self.clipboardBanner];
}

- (void)clipboardBannerTapped {
    NSString *text = UIPasteboard.generalPasteboard.string;
    self.clipboardBanner.hidden = YES;
    if (!text.length) return;
    text = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([text.lowercaseString hasPrefix:@"magnet:"]) {
        [self routeMagnetLink:text];
        return;
    }
    if (![text.lowercaseString hasPrefix:@"http"]) return;
    [self loadAddress:text];
}

#pragma mark - Navigation

- (void)loadAddress:(NSString *)text {
    NSString *address = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!address.length) return;

    if ([address.lowercaseString hasPrefix:@"magnet:"]) {
        [self routeMagnetLink:address];
        return;
    }

    if (![address containsString:@"://"]) {
        if ([address containsString:@"."] && ![address containsString:@" "]) {
            address = [@"https://" stringByAppendingString:address];
        } else {
            NSString *query = [address stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
            address = [@"https://www.google.com/search?q=" stringByAppendingString:query ?: @""];
        }
    }
    NSURL *url = [NSURL URLWithString:address];
    if (!url) return;

    self.showingHome = NO;
    self.homeView.hidden = YES;
    [self.view bringSubviewToFront:self.sniffButton];
    [self.view bringSubviewToFront:self.loadBar];
    [self.view bringSubviewToFront:self.clipboardBanner];
    MVBrowserTab *tab = self.activeTab;
    tab.url = address;
    [tab.webView loadRequest:[NSURLRequest requestWithURL:url]];
    self.addressField.text = address;
    [self.addressField resignFirstResponder];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [self loadAddress:textField.text];
    return YES;
}

- (void)goBack { MVBrowserTab *tab = self.activeTab; if (tab.webView.canGoBack) [tab.webView goBack]; }
- (void)goForward { MVBrowserTab *tab = self.activeTab; if (tab.webView.canGoForward) [tab.webView goForward]; }
- (void)homeTapped { [self showHome]; }

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (![keyPath isEqualToString:@"estimatedProgress"]) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    WKWebView *web = (WKWebView *)object;
    if (web != self.activeTab.webView) return;   // only the visible tab drives the bar
    double progress = web.estimatedProgress;
    self.loadBar.hidden = progress >= 1.0;
    [self.loadBar setProgress:(float)progress animated:YES];
}

#pragma mark - WKNavigationDelegate

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation {
    MVBrowserTab *tab = [self tabForWebView:webView];
    tab.loading = YES;
    if (webView == self.activeTab.webView) [self syncToolbar];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    MVBrowserTab *tab = [self tabForWebView:webView];
    if (!tab) return;
    tab.loading = NO;
    tab.url = webView.URL.absoluteString;
    tab.title = webView.title;
    if (webView == self.activeTab.webView) {
        self.showingHome = NO;
        self.homeView.hidden = YES;
        self.addressField.text = tab.url;
        [self syncToolbar];
    }
    [MVBrowserHistory.shared record:webView.URL.absoluteString title:webView.title];

    // Probe whatever the sniffer has found in this tab so sizes appear in the
    // sheet without the user waiting on a request per row.
    NSArray<MVSnifferItem *> *items = [MVSnifferStore.shared itemsForTab:tab.identifier];
    NSMutableArray<MVSnifferItem *> *unprobed = [NSMutableArray array];
    for (MVSnifferItem *item in items) if (!item.probed) [unprobed addObject:item];
    if (unprobed.count) [[MVMediaProbe shared] probeAll:unprobed completion:nil];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    if (error.code == NSURLErrorCancelled) return;
    MVLogWarn(@"browser: load failed %@ (%@)", webView.URL.absoluteString, error.localizedDescription);
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[MVLang t:@"Failed"]
                                                                  message:error.localizedDescription
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Close"] style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

/// Keeps browsing inside the app, and intercepts the schemes the app can handle
/// itself: magnet links go to the torrent flow, everything else unknown is
/// offered to the system.
- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action
        decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = action.request.URL;
    NSString *scheme = url.scheme.lowercaseString;

    if ([scheme isEqualToString:@"magnet"]) {
        decisionHandler(WKNavigationActionPolicyCancel);
        [self routeMagnetLink:url.absoluteString];
        return;
    }

    static NSArray *allowed;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ allowed = @[@"http", @"https", @"about", @"data", @"blob", @"file", @"javascript"]; });
    if (scheme.length && ![allowed containsObject:scheme]) {
        decisionHandler(WKNavigationActionPolicyCancel);
        if ([UIApplication.sharedApplication canOpenURL:url]) {
            [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
        }
        return;
    }

    // Remember that a tap happened, so a popup opened in the same runloop is
    // treated as user-initiated and not as an ad.
    if (action.navigationType == WKNavigationTypeLinkActivated) self.userGestureRecently = YES;
    decisionHandler(WKNavigationActionPolicyAllow);
}

/// A response the web view cannot display (an attachment, or a media/file MIME)
/// is offered as a download instead of failing.
- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationResponse:(WKNavigationResponse *)navigationResponse
        decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler {
    if (!navigationResponse.canShowMIMEType) {
        NSURL *url = navigationResponse.response.URL;
        NSString *mime = navigationResponse.response.MIMEType;
        decisionHandler(WKNavigationResponsePolicyCancel);
        [self offerDownloadForURL:url.absoluteString mime:mime];
        return;
    }
    decisionHandler(WKNavigationResponsePolicyAllow);
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    MVLogWarn(@"browser: web content process terminated, reloading");
    [webView reload];
}

#pragma mark - WKUIDelegate

/// Popups. A window opened by a real tap becomes a new tab; a popup with no URL
/// or one opened without any recent gesture is an ad and is dropped.
- (WKWebView *)webView:(WKWebView *)webView
    createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
               forNavigationAction:(WKNavigationAction *)action
                    windowFeatures:(WKWindowFeatures *)features {
    BOOL hasURL = action.request.URL.absoluteString.length > 0;
    BOOL fromGesture = self.userGestureRecently || action.navigationType == WKNavigationTypeLinkActivated;
    self.userGestureRecently = NO;

    if (!hasURL || !fromGesture) {
        MVLogInfo(@"browser: blocked popup (%@)", action.request.URL.absoluteString ?: @"no url");
        return nil;
    }

    NSString *address = action.request.URL.absoluteString;
    MVBrowserTab *tab = [self createTabWithURL:address isPopup:YES];
    [self selectTab:tab];
    [tab.webView loadRequest:action.request];
    return tab.webView;
}

- (void)webViewDidClose:(WKWebView *)webView {
    MVBrowserTab *tab = [self tabForWebView:webView];
    if (tab.isPopup) [self closeTab:tab.identifier];
}

- (MVBrowserTab *)tabForWebView:(WKWebView *)webView {
    for (MVBrowserTab *tab in self.tabs) if (tab.webView == webView) return tab;
    return nil;
}

#pragma mark - Sniffer

- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.name isEqualToString:kSnifferHandler]) return;
    NSDictionary *body = [message.body isKindOfClass:NSDictionary.class] ? message.body : nil;
    if (!body) return;

    NSString *type = body[@"type"];
    MVBrowserTab *tab = [self tabForWebView:message.webView];
    if (!tab) tab = self.activeTab;
    NSString *tabID = tab.identifier;
    NSString *pageURL = [body[@"page"] isKindOfClass:NSString.class] ? body[@"page"] : tab.url;
    NSString *title = [body[@"title"] isKindOfClass:NSString.class] ? body[@"title"] : tab.title;

    // A single-page app changes the address without a page load, so the script
    // reports it. Keeping tab.url current is what makes the yt-dlp action target
    // the video the user is watching instead of the page they arrived from.
    if ([type isEqualToString:@"location"]) {
        if (pageURL.length) {
            tab.url = pageURL;
            if (title.length) tab.title = title;
            if (tab == self.activeTab) {
                // Never clobber the field while the user is typing in it.
                if (![self.addressField isFirstResponder]) [self syncToolbar];
                [self refreshSniffBadge];
            }
        }
        return;
    }

    if ([type isEqualToString:@"blob"]) {
        // The page plays a blob: stream the app cannot fetch. The sheet's
        // "download this page with yt-dlp" action covers this case.
        MVLogInfo(@"sniffer: blob player on %@", pageURL);
        return;
    }

    NSString *src = [body[@"src"] isKindOfClass:NSString.class] ? body[@"src"] : @"";
    if (!src.length) return;

    MVSnifferItem *item = [MVSnifferItem itemWithURL:src pageURL:pageURL pageTitle:title mime:nil];
    item.referer = pageURL;
    if (item.kind == MVSniffKindUnknown) return;   // not a media/file link

    if ([MVSnifferStore.shared addItem:item toTab:tabID]) {
        // Only probe genuinely new links, once.
        [[MVMediaProbe shared] probe:item completion:nil];
    }
}

- (void)snifferChanged:(NSNotification *)note {
    NSString *tabID = [note.object isKindOfClass:NSString.class] ? note.object : nil;
    if (tabID && ![tabID isEqualToString:self.activeTab.identifier]) return;
    [self refreshSniffBadge];
}

- (void)refreshSniffBadge {
    MVBrowserTab *tab = self.activeTab;
    NSUInteger count = [MVSnifferStore.shared countForTab:tab.identifier];
    // A video page is offered as a row even when nothing was sniffed, so count it.
    NSString *live = tab.webView.URL.absoluteString;
    if (!live.length) live = tab.url;
    if ([MVSnifferItem isVideoPageURL:live]) count += 1;
    self.sniffBadge.hidden = (count == 0);
    self.sniffBadge.text = count > 99 ? @"99+" : [NSString stringWithFormat:@"%lu", (unsigned long)count];
    self.sniffButton.accessibilityValue = [NSString stringWithFormat:@"%lu", (unsigned long)count];
}

- (void)showSnifferSheet {
    MVBrowserTab *tab = self.activeTab;
    // Prefer the web view's live URL: on a single-page app tab.url can lag by a
    // navigation, and this URL is what a page download is handed.
    NSString *live = tab.webView.URL.absoluteString.length ? tab.webView.URL.absoluteString : tab.url;
    if (live.length) tab.url = live;
    MVSnifferSheetViewController *sheet =
        [[MVSnifferSheetViewController alloc] initWithTabIdentifier:tab.identifier
                                                          pageURL:live
                                                        pageTitle:tab.title];
    sheet.modalPresentationStyle = UIModalPresentationPageSheet;
    UISheetPresentationController *presentation = sheet.sheetPresentationController;
    if (presentation) {
        presentation.detents = @[[UISheetPresentationControllerDetent mediumDetent],
                                 [UISheetPresentationControllerDetent largeDetent]];
        presentation.prefersGrabberVisible = YES;
    }
    __weak typeof(self) weakSelf = self;
    sheet.onDownload = ^(NSArray<MVSnifferItem *> *items) {
        [weakSelf downloadItems:items];
    };
    sheet.onDownloadPageWithYTDlp = ^(NSString *pageURL, NSString *pageTitle) {
        [weakSelf downloadPageWithYTDlp:pageURL title:pageTitle];
    };
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)downloadItems:(NSArray<MVSnifferItem *> *)items {
    if (!items.count) return;
    BOOL anyAdded = NO;
    BOOL anyDuplicate = NO;
    for (MVSnifferItem *item in items) {
        // A page row is not a file the direct engine can fetch; it goes through
        // yt-dlp, exactly like the "download page" button.
        if (item.isPage) {
            [[MVDownloadEngine shared] downloadURL:item.url quality:@"best" completion:nil];
            anyAdded = YES;
        } else {
            BOOL added = NO;
            [[MVDownloadManager shared] enqueueItem:item added:&added];
            if (added) anyAdded = YES; else anyDuplicate = YES;
        }
    }
    // Every row was already in the list: say so instead of a silent no-op.
    if (!anyAdded && anyDuplicate) {
        [self toast:[MVLang t:@"Already in downloads"]];
        return;
    }
    [self notifyQueued];
}

/// Hands the page URL to the Python engine, which knows how to extract a video
/// the sniffer cannot reach (a blob player, a token-protected stream). The user
/// picks the quality, because a high one is fetched as two streams and muxed.
- (void)downloadPageWithYTDlp:(NSString *)pageURL title:(NSString *)title {
    // Re-read the web view's URL here: the sheet's copy was taken when it opened,
    // and a single-page app may have moved on since.
    MVBrowserTab *tab = self.activeTab;
    NSString *live = tab.webView.URL.absoluteString.length ? tab.webView.URL.absoluteString : pageURL;
    if (!live.length) live = tab.url;
    if (!live.length) return;
    [self presentQualitySheetForURL:live title:title];
}

/// The same quality choices the Home screen offers. A quality of 1080 or higher
/// is downloaded as a separate video + audio stream and muxed on device.
- (void)presentQualitySheetForURL:(NSString *)url title:(NSString *)title {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title.length ? title : [MVLang t:@"Choose quality"]
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray<NSArray<NSString *> *> *options = @[
        @[@"Best available", @"best"],
        @[@"1080p HD", @"1080"],
        @[@"Up to 720p", @"720p"],
        @[@"Up to 480p", @"480p"],
        @[@"Audio only (M4A)", @"audio"],
        @[@"MP3 (audio)", @"mp3"],
    ];
    __weak typeof(self) weakSelf = self;
    for (NSArray<NSString *> *option in options) {
        [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:option[0]]
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) {
            [weakSelf enqueuePageDownload:url quality:option[1]];
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];
    alert.popoverPresentationController.sourceView = self.sniffButton;
    alert.popoverPresentationController.sourceRect = self.sniffButton.bounds;
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)enqueuePageDownload:(NSString *)url quality:(NSString *)quality {
    [[MVDownloadEngine shared] downloadURL:url quality:quality completion:nil];
    [self notifyQueued];
}

- (void)notifyQueued {
    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];
    [NSNotificationCenter.defaultCenter postNotificationName:@"MVShowDownloadsTabNotification" object:nil];
}

/// A link the web view refused to show (an attachment or a media MIME) is
/// offered as a download.
- (void)offerDownloadForURL:(NSString *)url mime:(NSString *)mime {
    if (!url.length) return;
    MVSnifferItem *item = [MVSnifferItem itemWithURL:url
                                             pageURL:self.activeTab.url
                                           pageTitle:self.activeTab.title
                                                mime:mime];
    item.referer = self.activeTab.url;
    if (item.kind == MVSniffKindUnknown) return;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:item.displayName
                                                                  message:[MVLang t:@"Download this file?"]
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Download"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        BOOL added = NO;
        [[MVDownloadManager shared] enqueueItem:item added:&added];
        if (added) {
            [self notifyQueued];
        } else {
            [self toast:[MVLang t:@"Already in downloads"]];
        }
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)routeMagnetLink:(NSString *)magnet {
    MVSnifferItem *item = [MVSnifferItem itemWithURL:magnet pageURL:self.activeTab.url
                                           pageTitle:self.activeTab.title mime:nil];
    // The magnet is queued like any other torrent. It fails asynchronously with a
    // localised reason (the BEP 9 metadata exchange is not built yet), so the
    // downloads row carries the explanation; no alert is needed here.
    BOOL added = NO;
    [[MVDownloadManager shared] enqueueItem:item added:&added];
    if (added) {
        [self notifyQueued];
    } else {
        [self toast:[MVLang t:@"Already in downloads"]];
    }
}

#pragma mark - Menu

- (void)showTabs {
    MVTabsViewController *tabs = [[MVTabsViewController alloc] initWithTabs:self.tabs
                                                          activeIdentifier:self.activeTabID];
    tabs.modalPresentationStyle = UIModalPresentationPageSheet;
    UISheetPresentationController *presentation = tabs.sheetPresentationController;
    if (presentation) presentation.detents = @[[UISheetPresentationControllerDetent mediumDetent],
                                               [UISheetPresentationControllerDetent largeDetent]];
    __weak typeof(self) weakSelf = self;
    tabs.onSelect = ^(NSString *identifier) {
        for (MVBrowserTab *tab in weakSelf.tabs) {
            if ([tab.identifier isEqualToString:identifier]) { [weakSelf selectTab:tab]; break; }
        }
    };
    tabs.onClose = ^(NSString *identifier) { [weakSelf closeTab:identifier]; };
    tabs.onNewTab = ^{ [weakSelf openURLInNewTab:nil]; };
    [self presentViewController:tabs animated:YES completion:nil];
}

- (void)showMenu {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:nil message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];

    MVBrowserTab *tab = self.activeTab;
    BOOL favorite = [MVBrowserHistory.shared isFavorite:tab.url];
    [sheet addAction:[UIAlertAction actionWithTitle:(favorite ? [MVLang t:@"Remove bookmark"] : [MVLang t:@"Add bookmark"])
                                              style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [MVBrowserHistory.shared setFavorite:tab.url title:tab.title favorite:!favorite];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:(self.desktopMode ? [MVLang t:@"Mobile site"] : [MVLang t:@"Desktop site"])
                                              style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self toggleDesktopMode];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Find on page"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self promptFindInPage];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Share"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self shareCurrentPage];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:[MVLang t:@"New tab"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self openURLInNewTab:nil];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Reload"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self.activeTab.webView reload];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.menuButton;
    sheet.popoverPresentationController.sourceRect = self.menuButton.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)toggleDesktopMode {
    self.desktopMode = !self.desktopMode;
    NSString *agent = self.desktopMode ? [MVBrowserViewController desktopUserAgent]
                                       : [MVBrowserViewController safariUserAgent];
    // A user-agent change only takes effect on the next load, so reload now.
    for (MVBrowserTab *tab in self.tabs) tab.webView.customUserAgent = agent;
    [self.activeTab.webView reload];
    [self toast:(self.desktopMode ? [MVLang t:@"Desktop site"] : [MVLang t:@"Mobile site"])];
}

- (void)promptFindInPage {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[MVLang t:@"Find on page"]
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = [MVLang t:@"Find on page"];
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Find on page"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *text = alert.textFields.firstObject.text;
        if (text.length) [self findTextOnPage:text];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)findTextOnPage:(NSString *)text {
    WKFindConfiguration *configuration = [WKFindConfiguration new];
    configuration.backwards = NO;
    configuration.wraps = YES;
    configuration.caseSensitive = NO;
    __weak typeof(self) weakSelf = self;
    [self.activeTab.webView findString:text withConfiguration:configuration completionHandler:^(WKFindResult *result) {
        if (!result.matchFound) [weakSelf toast:[MVLang t:@"Not found"]];
    }];
}

- (void)shareCurrentPage {
    NSString *url = self.activeTab.url;
    if (!url.length) return;
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL URLWithString:url]]
                                                                       applicationActivities:nil];
    share.popoverPresentationController.sourceView = self.menuButton;
    share.popoverPresentationController.sourceRect = self.menuButton.bounds;
    [self presentViewController:share animated:YES completion:nil];
}

- (void)toast:(NSString *)text {
    UILabel *toast = [UILabel new];
    toast.translatesAutoresizingMaskIntoConstraints = NO;
    toast.text = text;
    toast.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    toast.textColor = UIColor.whiteColor;
    toast.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.8];
    toast.textAlignment = NSTextAlignmentCenter;
    toast.layer.cornerRadius = 16;
    toast.layer.masksToBounds = YES;
    toast.alpha = 0;
    [self.view addSubview:toast];
    [NSLayoutConstraint activateConstraints:@[
        [toast.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [toast.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-14],
        [toast.heightAnchor constraintEqualToConstant:34],
        [toast.widthAnchor constraintGreaterThanOrEqualToConstant:140],
    ]];
    [UIView animateWithDuration:0.2 animations:^{ toast.alpha = 1; } completion:^(BOOL done) {
        [UIView animateWithDuration:0.3 delay:1.2 options:0 animations:^{ toast.alpha = 0; }
                         completion:^(BOOL finished) { [toast removeFromSuperview]; }];
    }];
}

#pragma mark - Minimize / restore

- (void)minimize {
    MVBrowserTab *tab = self.activeTab;
    [tab.webView evaluateJavaScript:@"window.scrollY || 0" completionHandler:^(id result, NSError *error) {
        if ([result isKindOfClass:NSNumber.class]) tab.savedScrollY = [result doubleValue];
    }];
    gParkedBrowser = self;
    gParkedNav = self.navigationController;
    [self dismissViewControllerAnimated:YES completion:^{
        [MVBrowserViewController showParkedCard];
    }];
}

+ (void)restoreParked {
    MVBrowserViewController *browser = gParkedBrowser;
    if (!browser) return;
    UINavigationController *nav = gParkedNav ?: [[UINavigationController alloc] initWithRootViewController:browser];
    [MVBrowserViewController hideParkedCard];
    UIViewController *presenter = [MVBrowserViewController topPresenter];
    if (!presenter) return;
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    [presenter presentViewController:nav animated:YES completion:nil];
}

+ (void)discardParked {
    MVBrowserViewController *browser = gParkedBrowser;
    if (browser) {
        for (MVBrowserTab *tab in browser.tabs) {
            [tab.webView evaluateJavaScript:@"document.querySelectorAll('video,audio').forEach(function(m){try{m.pause()}catch(e){}})"
                          completionHandler:nil];
        }
    }
    [MVBrowserViewController hideParkedCard];
    gParkedBrowser = nil;
    gParkedNav = nil;
}

+ (UIViewController *)topPresenter {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (windowScene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *candidate in windowScene.windows) { if (candidate.isKeyWindow) { window = candidate; break; } }
    }
    if (!window) window = UIApplication.sharedApplication.windows.firstObject;
    UIViewController *top = window.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    return top;
}

+ (void)showParkedCard {
    if (!gParkedBrowser) return;
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (windowScene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *candidate in windowScene.windows) { if (candidate.isKeyWindow) { window = candidate; break; } }
    }
    if (!window) window = UIApplication.sharedApplication.windows.firstObject;
    if (!window) return;

    if (!gParkedCard) {
        gParkedCard = [[MVBrowserParkedCard alloc] initWithFrame:CGRectZero];
        gParkedCard.onTap = ^{ [MVBrowserViewController restoreParked]; };
        gParkedCard.onClose = ^{ [MVBrowserViewController discardParked]; };
    }
    MVBrowserTab *tab = gParkedBrowser.activeTab;
    NSString *title = tab.title;
    if (!title.length) title = [NSURL URLWithString:tab.url].host ?: [MVLang t:@"Browser"];
    gParkedCard.titleLabel.text = title;
    gParkedCard.accessibilityLabel = title;
    gParkedCard.accessibilityHint = [MVLang t:@"Tap to return to the page"];

    if (gParkedCard.superview != window) {
        [gParkedCard removeFromSuperview];
        [window addSubview:gParkedCard];
        gParkedCardBottom = [gParkedCard.bottomAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.bottomAnchor constant:-54];
        [NSLayoutConstraint activateConstraints:@[
            [gParkedCard.leadingAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.leadingAnchor constant:10],
            [gParkedCard.trailingAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.trailingAnchor constant:-10],
            gParkedCardBottom,
        ]];
    }
    [MVBrowserViewController moveParkedCardForPlayer];
    gParkedCard.hidden = NO;
    gParkedCard.alpha = 0;
    [UIView animateWithDuration:0.2 animations:^{ gParkedCard.alpha = 1; }];

    if (!gParkedObserver) {
        gParkedObserver = [NSNotificationCenter.defaultCenter addObserverForName:MVPlayerBarVisibilityDidChangeNotification
                                                                        object:nil queue:NSOperationQueue.mainQueue
                                                                    usingBlock:^(NSNotification *note) {
            [MVBrowserViewController moveParkedCardForPlayer];
        }];
    }
}

+ (void)moveParkedCardForPlayer {
    if (!gParkedCardBottom) return;
    BOOL playerUp = MVPlayerCenter.shared.floatingBarVisible;
    gParkedCardBottom.constant = playerUp ? -146 : -54;
    [gParkedCard.superview layoutIfNeeded];
}

+ (void)hideParkedCard {
    if (!gParkedCard) return;
    MVBrowserParkedCard *card = gParkedCard;
    [UIView animateWithDuration:0.2 animations:^{
        card.alpha = 0;
    } completion:^(BOOL done) {
        [card removeFromSuperview];
    }];
}

#pragma mark - Close / text

- (void)close {
    if (gParkedBrowser == self) [MVBrowserViewController discardParked];
    for (MVBrowserTab *tab in self.tabs) {
        [tab.webView evaluateJavaScript:@"document.querySelectorAll('video,audio').forEach(function(m){try{m.pause()}catch(e){}})"
                      completionHandler:nil];
    }
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)refreshText {
    self.title = [MVLang t:@"Browser"];
    self.addressField.attributedPlaceholder =
        [[NSAttributedString alloc] initWithString:[MVLang t:@"Search or enter address"]
                                        attributes:@{NSForegroundColorAttributeName: [MVTheme secondaryText]}];
    self.clipboardLabel.text = [MVLang t:@"A link is on the clipboard — tap to open it"];
    self.sniffButton.accessibilityLabel = [MVLang t:@"Found media"];
    self.view.semanticContentAttribute = MVLang.shared.isRTL
        ? UISemanticContentAttributeForceRightToLeft : UISemanticContentAttributeForceLeftToRight;
}

@end
