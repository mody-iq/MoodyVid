#import "MVBrowserViewController.h"
#import "MVBrowserHistory.h"
#import "MVLang.h"
#import "MVTheme.h"
#import "MVPaths.h"
#import "MVDownloadEngine.h"
#import <WebKit/WebKit.h>

/// Injected into every page. It finds the most promising playing video and adds
/// a small Download button over it, then tells the app about it.
///
/// Everything is wrapped so a hostile or broken page can never break the app:
/// the script only posts messages through the single `moodyvid` handler.
static NSString *const kInjectedScript = @""
"(function(){\n"
"  if (window.__moodyvidInstalled) return; window.__moodyvidInstalled = true;\n"
"  function post(o){ try { window.webkit.messageHandlers.moodyvid.postMessage(o); } catch(e){} }\n"
"  function score(v){\n"
"    var r=v.getBoundingClientRect();\n"
"    return (v.duration||0) * Math.sqrt(Math.max(1, r.width*r.height)) + (v.currentTime>0?1e6:0);\n"
"  }\n"
"  function best(){\n"
"    var b=null, bs=0;\n"
"    document.querySelectorAll('video').forEach(function(v){\n"
"      if ((v.videoWidth||0) < 100) return;\n"
"      var s=score(v); if (s>bs){ bs=s; b=v; }\n"
"    });\n"
"    return b;\n"
"  }\n"
"  function place(){\n"
"    var v=best(); if(!v) return;\n"
"    if (v.__moodyvidBtn && v.__moodyvidBtn.parentNode) return;\n"
"    var b=document.createElement('div');\n"
"    b.textContent='⬇ __MV_DOWNLOAD__';\n"
"    b.style.cssText='z-index:2147483647;padding:8px 14px;'\n"
"      +'border-radius:999px;background:#0FA0B0;color:#fff;font:600 14px -apple-system,sans-serif;'\n"
"      +'box-shadow:0 4px 14px rgba(0,0,0,.45);cursor:pointer';\n"
"    b.addEventListener('click',function(ev){\n"
"      ev.preventDefault(); ev.stopPropagation();\n"
"      post({type:'tap', src:v.currentSrc||v.src||'', page:location.href, title:document.title||''});\n"
"    });\n"
"    b.style.position='fixed';\n"
"    b.style.top='84px'; b.style.right='12px';\n"
"    document.body.appendChild(b);\n"
"    v.__moodyvidBtn=b;\n"
"  }\n"
"  function scan(){\n"
"    var v=best();\n"
"    if (v) post({type:'found', src:v.currentSrc||v.src||'', page:location.href, title:document.title||''});\n"
"  }\n"
"  document.addEventListener('DOMContentLoaded', place);\n"
"  setInterval(function(){ place(); scan(); }, 1500);\n"
"  post({type:'ready'});\n"
"})();\n";

static NSString *const kMessageHandler = @"moodyvid";

@interface MVBrowserViewController () <WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, UITextFieldDelegate>
@property (nonatomic, strong) WKWebView *web;
@property (nonatomic, strong) UITextField *addressField;
@property (nonatomic, strong) UIProgressView *loadBar;
@property (nonatomic, strong) UIButton *backButton;
@property (nonatomic, strong) UIButton *forwardButton;
@property (nonatomic, strong) UIButton *favoriteButton;
@property (nonatomic, strong) UIButton *downloadButton;
@property (nonatomic, strong) UIStackView *foundBar;
@property (nonatomic, strong) UILabel *foundLabel;
@property (nonatomic, copy, nullable) NSString *foundURL;
@property (nonatomic, copy, nullable) NSString *foundTitle;
@property (nonatomic, strong) NSLayoutConstraint *foundHeight;
@end

@interface MVBrowserViewController ()
/// The address to open once the view exists. Set by the presentation
/// helpers before the view is loaded, so it cannot live in the header.
@property (nonatomic, copy, nullable) NSString *initialURL;
/// YES when this instance is a popup opened by a page, which gets a Close button.
@property (nonatomic) BOOL isPopup;
@end

@implementation MVBrowserViewController

#pragma mark - Quick access sites

+ (NSArray<NSDictionary<NSString *, NSString *> *> *)quickAccessSites {
    return @[
        @{@"name": @"YouTube",    @"symbol": @"play.rectangle.fill",   @"color": @"#FF3B30", @"url": @"https://m.youtube.com"},
        @{@"name": @"TikTok",     @"symbol": @"music.note",            @"color": @"#25F4EE", @"url": @"https://www.tiktok.com"},
        @{@"name": @"Instagram",  @"symbol": @"camera.fill",           @"color": @"#E1306C", @"url": @"https://www.instagram.com"},
        @{@"name": @"Facebook",   @"symbol": @"f.circle.fill",         @"color": @"#1877F2", @"url": @"https://m.facebook.com"},
        @{@"name": @"X",          @"symbol": @"xmark",                 @"color": @"#8E8E93", @"url": @"https://x.com"},
        @{@"name": @"Twitch",     @"symbol": @"gamecontroller.fill",   @"color": @"#9146FF", @"url": @"https://m.twitch.tv"},
        @{@"name": @"Reddit",     @"symbol": @"bubble.left.fill",      @"color": @"#FF4500", @"url": @"https://www.reddit.com"},
        @{@"name": @"Vimeo",      @"symbol": @"v.circle.fill",         @"color": @"#1AB7EA", @"url": @"https://vimeo.com"},
        @{@"name": @"Dailymotion",@"symbol": @"d.circle.fill",         @"color": @"#00AAFF", @"url": @"https://www.dailymotion.com"},
        @{@"name": @"SoundCloud", @"symbol": @"waveform",              @"color": @"#FF5500", @"url": @"https://m.soundcloud.com"},
        @{@"name": @"Pinterest",  @"symbol": @"p.circle.fill",         @"color": @"#E60023", @"url": @"https://www.pinterest.com"},
    ];
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

#pragma mark - Presentation

+ (void)presentFrom:(UIViewController *)presenter url:(NSString *)url {
    MVBrowserViewController *browser = [MVBrowserViewController new];
    NSString *address = url;
    if (![address containsString:@"://"] && address.length) {
        address = [@"https://" stringByAppendingString:address];
    }
    browser.initialURL = address;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:browser];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    [presenter presentViewController:nav animated:YES completion:nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    self.title = [MVLang t:@"Browser"];

    [self buildWebView];
    [self buildToolbar];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                     target:self action:@selector(close)];
    if (self.isPopup) {
        self.navigationItem.leftBarButtonItem =
            [[UIBarButtonItem alloc] initWithTitle:[MVLang t:@"Close"]
                                            style:UIBarButtonItemStylePlain
                                           target:self action:@selector(close)];
    }

    if (self.initialURL.length) [self loadAddress:self.initialURL];
    [self refreshText];
}

- (void)close {
    // Stop the page's own playback so it does not keep running behind the app.
    [self.web evaluateJavaScript:@"document.querySelectorAll('video,audio').forEach(function(m){try{m.pause()}catch(e){}})"
               completionHandler:nil];
    [self dismissViewControllerAnimated:YES completion:nil];
}

/// The store every browser instance shares, so a sign-in made in one place is
/// still there in the next. `defaultDataStore` is persistent and is the only
/// choice on iOS 15; `dataStoreForIdentifier:` (iOS 17+) would give us a named
/// one, but calling it on an older system raises, so it is guarded.
+ (WKWebsiteDataStore *)sharedDataStore {
    static WKWebsiteDataStore *store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        store = WKWebsiteDataStore.defaultDataStore;
    });
    return store;
}

- (void)buildWebView {
    WKWebViewConfiguration *config = [WKWebViewConfiguration new];
    config.websiteDataStore = [MVBrowserViewController sharedDataStore];
    config.allowsInlineMediaPlayback = YES;
    config.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;

    // Google and others refuse to sign a user in when the browser looks embedded.
    // Reporting plain "Safari" with a current version is what lets the official
    // sign-in pages load instead of a "this browser is not secure" wall.
    config.applicationNameForUserAgent = @"Version/18.0 Mobile/15E148 Safari/604.1";
    config.preferences.javaScriptCanOpenWindowsAutomatically = YES;

    WKUserContentController *ucc = [WKUserContentController new];
    [ucc addScriptMessageHandler:self name:kMessageHandler];
    // The page's Download button has to speak the app's language, so the label is
    // substituted here rather than baked into the script.
    NSString *script = [kInjectedScript stringByReplacingOccurrencesOfString:@"__MV_DOWNLOAD__"
                                                                 withString:[MVLang t:@"Download"]];
    [ucc addUserScript:[[WKUserScript alloc] initWithSource:script
                                               injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
                                            forMainFrameOnly:NO]];
    config.userContentController = ucc;

    self.web = [[WKWebView alloc] initWithFrame:CGRectZero configuration:config];
    self.web.customUserAgent = [MVBrowserViewController safariUserAgent];
    self.web.translatesAutoresizingMaskIntoConstraints = NO;
    self.web.navigationDelegate = self;
    self.web.UIDelegate = self;
    self.web.allowsBackForwardNavigationGestures = YES;
    [self.web addObserver:self forKeyPath:@"estimatedProgress" options:NSKeyValueObservingOptionNew context:nil];
    [self.view addSubview:self.web];

    self.loadBar = [UIProgressView new];
    self.loadBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.loadBar.progressTintColor = [MVTheme accent];
    [self.view addSubview:self.loadBar];

    // A web view has no intrinsic size, so its height must come from constraints.
    // This is the chain that gives it one: web -> progress bar -> address row.
    [NSLayoutConstraint activateConstraints:@[
        [self.web.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.web.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.web.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.web.bottomAnchor constraintEqualToAnchor:self.loadBar.topAnchor],
        [self.loadBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.loadBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        // The progress bar has no intrinsic height either, so give it one.
        [self.loadBar.heightAnchor constraintEqualToConstant:2],
    ]];
}

- (void)buildToolbar {
    // Address row.
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
    self.favoriteButton = [self toolbarButton:@"star" action:@selector(toggleFavorite)];

    // Always-available download for the page currently open. The button injected
    // into the page can be covered by the site's own overlay, so the user needs a
    // control the page cannot take away.
    self.downloadButton = [self toolbarButton:@"arrow.down.circle" action:@selector(downloadCurrentPage)];

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[self.backButton, self.forwardButton, self.addressField, self.downloadButton, self.favoriteButton]];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.spacing = 8;
    row.alignment = UIStackViewAlignmentCenter;
    [self.view addSubview:row];

    // "Media found" bar, hidden until the sniffer has something to offer.
    self.foundBar = [UIStackView new];
    self.foundBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.foundBar.axis = UILayoutConstraintAxisHorizontal;
    self.foundBar.spacing = 10;
    self.foundBar.alignment = UIStackViewAlignmentCenter;
    self.foundBar.backgroundColor = [MVTheme card];
    self.foundBar.layer.cornerRadius = 12;
    self.foundBar.layer.cornerCurve = kCACornerCurveContinuous;
    self.foundBar.layoutMarginsRelativeArrangement = YES;
    self.foundBar.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(8, 12, 8, 12);
    self.foundBar.hidden = YES;
    // It sits in the layout chain, so an empty bar must take no space at all.
    self.foundHeight = [self.foundBar.heightAnchor constraintEqualToConstant:0];
    self.foundHeight.active = YES;

    self.foundLabel = [UILabel new];
    self.foundLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    self.foundLabel.textColor = [MVTheme text];
    self.foundLabel.numberOfLines = 2;
    self.foundLabel.text = [MVLang t:@"Media found"];
    UIButton *grab = [UIButton buttonWithType:UIButtonTypeSystem];
    [grab setTitle:[MVLang t:@"Download"] forState:UIControlStateNormal];
    [grab addTarget:self action:@selector(downloadFound) forControlEvents:UIControlEventTouchUpInside];
    [MVTheme applyPrimaryButtonStyle:grab];
    [grab.heightAnchor constraintEqualToConstant:34].active = YES;
    [grab.widthAnchor constraintGreaterThanOrEqualToConstant:100].active = YES;
    [self.foundBar addArrangedSubview:self.foundLabel];
    [self.foundBar addArrangedSubview:grab];
    [self.view addSubview:self.foundBar];

    [NSLayoutConstraint activateConstraints:@[
        [row.topAnchor constraintEqualToAnchor:self.loadBar.bottomAnchor constant:8],
        [row.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [row.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [self.foundBar.topAnchor constraintEqualToAnchor:row.bottomAnchor constant:8],
        [self.foundBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.foundBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        // Anchors the whole chain: web view, bar, address row and found bar all
        // derive their height from this one relationship to the safe area.
        [self.foundBar.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-8],
        [self.addressField.heightAnchor constraintEqualToConstant:36],
        [self.backButton.widthAnchor constraintEqualToConstant:32],
        [self.forwardButton.widthAnchor constraintEqualToConstant:32],
        [self.favoriteButton.widthAnchor constraintEqualToConstant:32],
        [self.downloadButton.widthAnchor constraintEqualToConstant:32],
    ]];

}

- (UIButton *)toolbarButton:(NSString *)symbol action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    b.tintColor = [MVTheme accent];
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

#pragma mark - Navigation

- (void)loadAddress:(NSString *)text {
    NSString *address = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!address.length) return;
    if (![address containsString:@"://"]) {
        // A bare word is a search, anything with a dot is a host.
        if ([address containsString:@"."] && ![address containsString:@" "]) {
            address = [@"https://" stringByAppendingString:address];
        } else {
            NSString *q = [address stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
            address = [@"https://m.duckduckgo.com/?q=" stringByAppendingString:q ?: @""];
        }
    }
    NSURL *url = [NSURL URLWithString:address];
    if (!url) return;
    [self.web loadRequest:[NSURLRequest requestWithURL:url]];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [self loadAddress:textField.text];
    [textField resignFirstResponder];
    return YES;
}

- (void)goBack { if (self.web.canGoBack) [self.web goBack]; }
- (void)goForward { if (self.web.canGoForward) [self.web goForward]; }

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if ([keyPath isEqualToString:@"estimatedProgress"]) {
        double p = self.web.estimatedProgress;
        self.loadBar.hidden = p >= 1.0;
        [self.loadBar setProgress:(float)p animated:YES];
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    self.addressField.text = webView.URL.absoluteString;
    self.backButton.enabled = webView.canGoBack;
    self.forwardButton.enabled = webView.canGoForward;
    [self updateFavoriteButton];
    [MVBrowserHistory.shared record:webView.URL.absoluteString title:webView.title];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    if (error.code == NSURLErrorCancelled) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[MVLang t:@"Failed"]
                                                                  message:error.localizedDescription
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Close"] style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

/// Keep the browsing inside the app instead of jumping to Safari.
- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action
        decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSString *scheme = action.request.URL.scheme.lowercaseString;
    if (scheme && ![@[@"http", @"https", @"about", @"data", @"blob", @"file"] containsObject:scheme]) {
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }
    decisionHandler(WKNavigationActionPolicyAllow);
}

/// Popups (sign-in windows, target="_blank" links) open as a real child web view
/// sharing the session, so the flow continues instead of silently doing nothing.
- (WKWebView *)webView:(WKWebView *)webView
    createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
               forNavigationAction:(WKNavigationAction *)action
                    windowFeatures:(WKWindowFeatures *)features {
    if (!action.request.URL) return nil;

    // Keep the popup on our own store, otherwise the login would land in a
    // different cookie jar and the sign-in would not stick.
    configuration.websiteDataStore = [MVBrowserViewController sharedDataStore];

    MVBrowserViewController *popup = [MVBrowserViewController new];
    popup.initialURL = action.request.URL.absoluteString;
    popup.isPopup = YES;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:popup];
    [self presentViewController:nav animated:YES completion:nil];
    return nil;
}

#pragma mark - Sniffer

- (void)userContentController:(WKUserContentController *)ucc didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.name isEqualToString:kMessageHandler]) return;
    NSDictionary *body = [message.body isKindOfClass:NSDictionary.class] ? message.body : nil;
    if (!body) return;
    NSString *type = body[@"type"];
    NSString *src = [body[@"src"] isKindOfClass:NSString.class] ? body[@"src"] : @"";

    if ([type isEqualToString:@"tap"]) {
        // The button on the video: the user has decided, so download it now. A
        // blob: source (what YouTube's player uses) cannot be fetched, and on some
        // players currentSrc is empty; both fall through to the page address,
        // which the engine knows how to extract. The old guard returned early on
        // an empty src, so the tap was dropped and the button looked dead.
        NSString *target = [self looksLikeMedia:src] ? src : self.web.URL.absoluteString;
        if (!target.length) return;
        [self startDownloadOf:target title:body[@"title"]];
    } else if ([type isEqualToString:@"found"]) {
        if (!src.length || [src hasPrefix:@"blob:"]) return;  // blob URLs cannot be fetched
        self.foundURL = src;
        self.foundTitle = body[@"title"];
        [self showFoundBar];
    }
}

- (void)showFoundBar {
    if (self.foundBar.hidden) {
        self.foundBar.hidden = NO;
        self.foundHeight.constant = 46;
        [UIView animateWithDuration:0.2 animations:^{ self.foundBar.alpha = 1; }];
    }
    NSString *name = self.foundTitle.length ? self.foundTitle : [MVLang t:@"Media found"];
    self.foundLabel.text = name;
}

/// The toolbar's Download button. Prefers a media URL the sniffer found; falls
/// back to the page address, which the engine knows how to extract.
- (void)downloadCurrentPage {
    NSString *target = self.foundURL.length ? self.foundURL : self.web.URL.absoluteString;
    if (!target.length) return;
    [self startDownloadOf:target title:self.foundTitle ?: self.web.title];
}

- (void)downloadFound {
    if (self.foundURL.length) [self startDownloadOf:self.foundURL title:self.foundTitle];
}

/// Downloads `url` as media when it is a direct stream, otherwise hands the page
/// address to the engine, which knows how to extract a page's video.
- (void)startDownloadOf:(NSString *)url title:(NSString *)title {
    NSString *target = [self looksLikeMedia:url] ? url : self.web.URL.absoluteString;
    if (!target.length) return;
    [self showDownloadSheetFor:target title:title];
}

/// The quality sheet. Shown immediately, with no network round trip first: a
/// sheet that waits on yt-dlp leaves the user staring at a spinner when the
/// probe stalls.
- (void)showDownloadSheetFor:(NSString *)url title:(NSString *)title {
    UIAlertController *sheet =
        [UIAlertController alertControllerWithTitle:(title.length ? title : [MVLang t:@"Download"])
                                            message:nil
                                     preferredStyle:UIAlertControllerStyleActionSheet];

    [sheet addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Best available"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self queueDownload:url quality:@"best"];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"1080p" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self queueDownload:url quality:@"1080"];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"720p" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self queueDownload:url quality:@"720p"];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"480p" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self queueDownload:url quality:@"480p"];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Audio only (M4A)"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self queueDownload:url quality:@"audio"];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];

    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}



- (BOOL)looksLikeMedia:(NSString *)url {
    static NSArray *needles;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        needles = @[@".mp4", @".m4v", @".mov", @".webm", @".mkv", @".m3u8", @".mp3", @".m4a", @"/videoplayback"];
    });
    NSString *lower = url.lowercaseString;
    for (NSString *n in needles) if ([lower containsString:n]) return YES;
    return NO;
}

- (void)queueDownload:(NSString *)url quality:(NSString *)quality {
    [[MVDownloadEngine shared] downloadURL:url quality:quality completion:^(NSString *filePath, NSString *error) {
        if (error && !filePath.length) {
            NSLog(@"MoodyVid: browser download failed: %@", error);
        }
    }];
}

#pragma mark - Favorites

- (void)toggleFavorite {
    NSString *address = self.web.URL.absoluteString;
    if (!address.length) return;
    BOOL wasFavorite = [MVBrowserHistory.shared isFavorite:address];
    [MVBrowserHistory.shared setFavorite:address title:self.web.title favorite:!wasFavorite];
    [self updateFavoriteButton];
}

- (void)updateFavoriteButton {
    BOOL fav = [MVBrowserHistory.shared isFavorite:self.web.URL.absoluteString];
    [self.favoriteButton setImage:[UIImage systemImageNamed:fav ? @"star.fill" : @"star"] forState:UIControlStateNormal];
}

#pragma mark - Language

- (void)refreshText {
    self.title = [MVLang t:@"Browser"];
    self.addressField.attributedPlaceholder =
        [[NSAttributedString alloc] initWithString:[MVLang t:@"Search or enter address"]
                                        attributes:@{NSForegroundColorAttributeName: [MVTheme secondaryText]}];
    self.view.semanticContentAttribute = MVLang.shared.isRTL
        ? UISemanticContentAttributeForceRightToLeft : UISemanticContentAttributeForceLeftToRight;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [MVTheme applyWallpaperTo:self.view];
    [self refreshText];
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

- (void)dealloc {
    [self.web removeObserver:self forKeyPath:@"estimatedProgress"];
    [self.web.configuration.userContentController removeScriptMessageHandlerForName:kMessageHandler];
}

@end
