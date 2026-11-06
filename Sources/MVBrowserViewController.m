#import "MVBrowserViewController.h"
#import "MVBrowserHistory.h"
#import "MVLang.h"
#import "MVTheme.h"
#import "MVPaths.h"
#import "MVDownloadEngine.h"
#import "MVPython.h"
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
"    b.textContent='⬇ Download';\n"
"    b.style.cssText='position:absolute;z-index:2147483647;top:12px;right:12px;padding:8px 14px;'\n"
"      +'border-radius:999px;background:#0FA0B0;color:#fff;font:600 14px -apple-system,sans-serif;'\n"
"      +'box-shadow:0 4px 14px rgba(0,0,0,.45);cursor:pointer';\n"
"    b.addEventListener('click',function(ev){\n"
"      ev.preventDefault(); ev.stopPropagation();\n"
"      post({type:'tap', src:v.currentSrc||v.src||'', page:location.href, title:document.title||''});\n"
"    });\n"
"    var host=v.parentNode;\n"
"    if (host && getComputedStyle(host).position==='static') host.style.position='relative';\n"
"    (host||document.body).appendChild(b);\n"
"    v.__moodyvidBtn=b;\n"
"    function sync(){ try{\n"
"      var r=v.getBoundingClientRect();\n"
"      b.style.top=(v.offsetTop+12)+'px'; b.style.left=(v.offsetLeft+Math.max(8,r.width-140))+'px';\n"
"    }catch(e){} }\n"
"    sync(); v.addEventListener('timeupdate', sync);\n"
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
@property (nonatomic, strong) UIStackView *foundBar;
@property (nonatomic, strong) UILabel *foundLabel;
@property (nonatomic, copy, nullable) NSString *foundURL;
@property (nonatomic, copy, nullable) NSString *foundTitle;
@end

@interface MVBrowserViewController ()
/// The address to open once the view exists. Set by the presentation
/// helpers before the view is loaded, so it cannot live in the header.
@property (nonatomic, copy, nullable) NSString *initialURL;
@end

@implementation MVBrowserViewController

#pragma mark - Quick access sites

+ (NSArray<NSDictionary<NSString *, NSString *> *> *)quickAccessSites {
    return @[
        @{@"name": @"YouTube",    @"symbol": @"play.rectangle.fill",   @"color": @"#FF3B30", @"url": @"https://m.youtube.com"},
        @{@"name": @"TikTok",     @"symbol": @"music.note",            @"color": @"#25F4EE", @"url": @"https://www.tiktok.com"},
        @{@"name": @"Instagram",  @"symbol": @"camera.fill",           @"color": @"#E1306C", @"url": @"https://www.instagram.com"},
        @{@"name": @"Facebook",   @"symbol": @"f.circle.fill",         @"color": @"#1877F2", @"url": @"https://m.facebook.com"},
        @{@"name": @"X",          @"symbol": @"xmark",                 @"color": @"#8E8E93", @"url": @"https://mobile.twitter.com"},
        @{@"name": @"Twitter",    @"symbol": @"bird.fill",             @"color": @"#1DA1F2", @"url": @"https://mobile.twitter.com"},
        @{@"name": @"Twitch",     @"symbol": @"gamecontroller.fill",   @"color": @"#9146FF", @"url": @"https://m.twitch.tv"},
        @{@"name": @"Reddit",     @"symbol": @"bubble.left.fill",      @"color": @"#FF4500", @"url": @"https://www.reddit.com"},
        @{@"name": @"Vimeo",      @"symbol": @"v.circle.fill",         @"color": @"#1AB7EA", @"url": @"https://vimeo.com"},
        @{@"name": @"Dailymotion",@"symbol": @"d.circle.fill",         @"color": @"#00AAFF", @"url": @"https://www.dailymotion.com"},
        @{@"name": @"SoundCloud", @"symbol": @"waveform",              @"color": @"#FF5500", @"url": @"https://m.soundcloud.com"},
        @{@"name": @"Pinterest",  @"symbol": @"p.circle.fill",         @"color": @"#E60023", @"url": @"https://www.pinterest.com"},
    ];
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
    self.view.backgroundColor = [MVTheme background];
    self.title = [MVLang t:@"Browser"];

    [self buildWebView];
    [self buildToolbar];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                     target:self action:@selector(close)];

    if (self.initialURL.length) [self loadAddress:self.initialURL];
    [self refreshText];
}

- (void)close {
    // Stop the page's own playback so it does not keep running behind the app.
    [self.web evaluateJavaScript:@"document.querySelectorAll('video,audio').forEach(function(m){try{m.pause()}catch(e){}})"
               completionHandler:nil];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)buildWebView {
    WKWebViewConfiguration *config = [WKWebViewConfiguration new];
    config.allowsInlineMediaPlayback = YES;
    config.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;

    // The site sees a normal mobile Safari, so it serves its mobile pages.
    config.applicationNameForUserAgent = @"Version/17.0 Mobile/15E148 Safari/604.1";

    WKUserContentController *ucc = [WKUserContentController new];
    [ucc addScriptMessageHandler:self name:kMessageHandler];
    [ucc addUserScript:[[WKUserScript alloc] initWithSource:kInjectedScript
                                               injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
                                            forMainFrameOnly:NO]];
    config.userContentController = ucc;

    self.web = [[WKWebView alloc] initWithFrame:CGRectZero configuration:config];
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

    [NSLayoutConstraint activateConstraints:@[
        [self.web.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.web.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.web.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.loadBar.topAnchor constraintEqualToAnchor:self.web.bottomAnchor],
        [self.loadBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.loadBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
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

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[self.backButton, self.forwardButton, self.addressField, self.favoriteButton]];
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
        [self.foundBar.bottomAnchor constraintLessThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-8],
        [self.addressField.heightAnchor constraintEqualToConstant:36],
        [self.backButton.widthAnchor constraintEqualToConstant:32],
        [self.forwardButton.widthAnchor constraintEqualToConstant:32],
        [self.favoriteButton.widthAnchor constraintEqualToConstant:32],
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

/// target="_blank" links open in the same web view rather than doing nothing.
- (WKWebView *)webView:(WKWebView *)webView
    createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
               forNavigationAction:(WKNavigationAction *)action
                    windowFeatures:(WKWindowFeatures *)features {
    if (action.targetFrame == nil && action.request.URL) {
        [webView loadRequest:action.request];
    }
    return nil;
}

#pragma mark - Sniffer

- (void)userContentController:(WKUserContentController *)ucc didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.name isEqualToString:kMessageHandler]) return;
    NSDictionary *body = [message.body isKindOfClass:NSDictionary.class] ? message.body : nil;
    if (!body) return;
    NSString *type = body[@"type"];
    NSString *src = body[@"src"];
    if (![src isKindOfClass:NSString.class] || !src.length) return;

    if ([type isEqualToString:@"tap"]) {
        // The button on the video: the user has decided, so download it now.
        [self startDownloadOf:src title:body[@"title"]];
    } else if ([type isEqualToString:@"found"]) {
        if ([src hasPrefix:@"blob:"]) return;   // blob URLs cannot be fetched directly
        self.foundURL = src;
        self.foundTitle = body[@"title"];
        [self showFoundBar];
    }
}

- (void)showFoundBar {
    if (self.foundBar.hidden) {
        self.foundBar.hidden = NO;
        [UIView animateWithDuration:0.2 animations:^{ self.foundBar.alpha = 1; }];
    }
    NSString *name = self.foundTitle.length ? self.foundTitle : [MVLang t:@"Media found"];
    self.foundLabel.text = name;
}

- (void)downloadFound {
    if (self.foundURL.length) [self startDownloadOf:self.foundURL title:self.foundTitle];
}

/// Downloads `url` as media when it is a direct stream, otherwise hands the page
/// address to the engine, which knows how to extract a page's video.
- (void)startDownloadOf:(NSString *)url title:(NSString *)title {
    NSString *target = url;
    BOOL looksLikeMedia = [self looksLikeMedia:url];
    if (!looksLikeMedia) {
        NSString *page = self.web.URL.absoluteString;
        if (!page.length) return;
        target = page;
    }

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title.length ? title : [MVLang t:@"Download"]
                                                                  message:target
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *qualities = @[@[@"Best", @"best"], @[@"1080p", @"1080p"], @[@"720p", @"720p"], @[@"480p", @"480p"], @[@"MP3", @"audio"]];
    for (NSArray *q in qualities) {
        [sheet addAction:[UIAlertAction actionWithTitle:q[0] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [self queueDownload:target quality:q[1]];
        }]];
    }
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
    [self refreshText];
}

- (void)dealloc {
    [self.web removeObserver:self forKeyPath:@"estimatedProgress"];
    [self.web.configuration.userContentController removeScriptMessageHandlerForName:kMessageHandler];
}

@end
