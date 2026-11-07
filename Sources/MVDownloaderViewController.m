#import "MVDownloaderViewController.h"
#import "MVBrowserViewController.h"
#import "MVBrowserHistory.h"
#import "MVLang.h"
#import "MVTheme.h"
#import "MVDownloadStore.h"
#import "MVPaths.h"
#import "MVDownloadEngine.h"

// A platform shortcut: the name, the SF Symbol standing in for its logo (we ship
// no third-party brand assets) and the tint used for the tile.
@interface MVPlatform : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *symbol;
@property (nonatomic, strong) UIColor *tint;
/// The site the tile opens in the in-app browser; nil for the trailing "More"
/// tile, which opens the history instead.
@property (nonatomic, copy, nullable) NSString *url;
+ (instancetype)name:(NSString *)name symbol:(NSString *)symbol tint:(UIColor *)tint url:(nullable NSString *)url;
@end

@implementation MVPlatform
+ (instancetype)name:(NSString *)name symbol:(NSString *)symbol tint:(UIColor *)tint url:(NSString *)url {
    MVPlatform *p = [MVPlatform new];
    p.name = name; p.symbol = symbol; p.tint = tint; p.url = url;
    return p;
}
@end

/// A view that renders its text filled with a diagonal accent gradient, used
/// for the brand name on the home screen.
@interface MVGradientLabel : UIView
@property (nonatomic, copy) NSString *text;
@property (nonatomic, strong) UIFont *font;
@property (nonatomic, strong) UIColor *startColor;
@property (nonatomic, strong) UIColor *endColor;
@end

@implementation MVGradientLabel

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.opaque = NO;
        self.backgroundColor = UIColor.clearColor;
        self.userInteractionEnabled = NO;
    }
    return self;
}

- (void)setText:(NSString *)text {
    _text = [text copy];
    [self setNeedsDisplay];
}
- (void)setFont:(UIFont *)font {
    _font = font;
    [self setNeedsDisplay];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    if (!self.text.length) return;
    CGContextRef context = UIGraphicsGetCurrentContext();
    if (!context) return;

    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    UIColor *start = self.startColor ?: [MVTheme accent];
    UIColor *end = self.endColor ?: [MVTheme accent];
    CGGradientRef gradient = CGGradientCreateWithColors(space, (__bridge CFArrayRef)@[
        (id)start.CGColor,
        (id)end.CGColor,
    ], NULL);
    NSDictionary *attrs = self.font ? @{NSFontAttributeName: self.font} : @{};
    CGSize size = [self.text sizeWithAttributes:attrs];

    CGContextSaveGState(context);
    CGContextSetTextDrawingMode(context, kCGTextClip);
    [self.text drawAtPoint:CGPointMake(0, (CGRectGetHeight(rect) - size.height) / 2.0)
            withAttributes:attrs];
    CGContextDrawLinearGradient(context, gradient,
                                CGPointMake(0, 0),
                                CGPointMake(CGRectGetWidth(rect), CGRectGetHeight(rect)), 0);
    CGContextRestoreGState(context);

    CGGradientRelease(gradient);
    CGColorSpaceRelease(space);
}

- (CGSize)intrinsicContentSize {
    if (!self.font || !self.text.length) return CGSizeZero;
    return [self.text sizeWithAttributes:@{NSFontAttributeName: self.font}];
}

@end

@interface MVDownloaderViewController () <UITextFieldDelegate>
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UITextField *urlField;
@property (nonatomic, strong) UIButton *pasteButton;
@property (nonatomic, strong) UIButton *downloadButton;
@property (nonatomic, strong) UIButton *qualityButton;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIProgressView *progressView;
@property (nonatomic, strong) UIActivityIndicatorView *busyView;
@property (nonatomic, strong) UILabel *platformsTitle;
@property (nonatomic, copy) NSString *selectedQuality;
@property (nonatomic, strong) NSArray<MVPlatform *> *platforms;
@property (nonatomic, copy, nullable) NSString *watchedIdentifier;
@property (nonatomic, strong, nullable) id storeObserver;
@property (nonatomic, assign) BOOL busy;
@end

@implementation MVDownloaderViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    self.selectedQuality = @"best";

    // Tiles come from the browser's own site list so the two cannot drift apart.
    NSMutableArray<MVPlatform *> *tiles = [NSMutableArray array];
    for (NSDictionary *site in [MVBrowserViewController quickAccessSites]) {
        if (tiles.count >= 7) break;
        [tiles addObject:[MVPlatform name:site[@"name"]
                                   symbol:site[@"symbol"]
                                     tint:[self colorFromHex:site[@"color"]]
                                      url:site[@"url"]]];
    }
    [tiles addObject:[MVPlatform name:@"More" symbol:@"ellipsis.circle.fill" tint:[MVTheme accent] url:nil]];
    self.platforms = tiles;

    [self buildLayout];
    [self refreshText];

    for (NSString *name in @[MVLangDidChangeNotification, MVThemeDidChangeNotification, MVDownloadStoreDidChangeNotification]) {
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refreshText) name:name object:nil];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshText];
    [self updatePasteButton];
}

#pragma mark - Layout

- (void)buildLayout {
    self.scroll = [UIScrollView new];
    self.scroll.translatesAutoresizingMaskIntoConstraints = NO;
    self.scroll.alwaysBounceVertical = YES;
    self.scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:self.scroll];

    UIStackView *stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 16;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scroll addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        // Full-bleed: the wallpaper and the scroll extend under the translucent
        // nav bar so the whole page (chrome included) shows the wallpaper.
        [self.scroll.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [stack.topAnchor constraintEqualToAnchor:self.scroll.topAnchor constant:8],
        [stack.leadingAnchor constraintEqualToAnchor:self.scroll.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:self.scroll.trailingAnchor constant:-16],
        [stack.bottomAnchor constraintEqualToAnchor:self.scroll.bottomAnchor constant:-20],
        [stack.widthAnchor constraintEqualToAnchor:self.scroll.widthAnchor constant:-32],
    ]];

    [stack addArrangedSubview:[self makeHeader]];

    // Link card: field + paste, then the download button and quality picker.
    UIView *linkCard = [UIView new];
    [MVTheme applyCardStyle:linkCard];
    linkCard.translatesAutoresizingMaskIntoConstraints = NO;

    self.urlField = [UITextField new];
    self.urlField.translatesAutoresizingMaskIntoConstraints = NO;
    self.urlField.borderStyle = UITextBorderStyleNone;
    self.urlField.keyboardType = UIKeyboardTypeURL;
    self.urlField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.urlField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.urlField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.urlField.returnKeyType = UIReturnKeyDone;
    self.urlField.delegate = self;
    self.urlField.font = [UIFont systemFontOfSize:15];
    self.urlField.textColor = [MVTheme text];
    [linkCard addSubview:self.urlField];

    self.pasteButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.pasteButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.pasteButton addTarget:self action:@selector(pasteFromClipboard) forControlEvents:UIControlEventTouchUpInside];
    self.pasteButton.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    [self.pasteButton setTitleColor:[MVTheme accent] forState:UIControlStateNormal];
    [linkCard addSubview:self.pasteButton];

    UIView *divider = [UIView new];
    divider.translatesAutoresizingMaskIntoConstraints = NO;
    divider.backgroundColor = [[MVTheme separator] colorWithAlphaComponent:0.15];
    [linkCard addSubview:divider];

    self.downloadButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.downloadButton.translatesAutoresizingMaskIntoConstraints = NO;
    [MVTheme applyPrimaryButtonStyle:self.downloadButton];
    [self.downloadButton addTarget:self action:@selector(primaryTapped) forControlEvents:UIControlEventTouchUpInside];
    [linkCard addSubview:self.downloadButton];

    self.qualityButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.qualityButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.qualityButton.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    [self.qualityButton setTitleColor:[MVTheme secondaryText] forState:UIControlStateNormal];
    [self.qualityButton addTarget:self action:@selector(showQualityMenu) forControlEvents:UIControlEventTouchUpInside];
    [linkCard addSubview:self.qualityButton];

    self.progressView = [UIProgressView new];
    self.progressView.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressView.hidden = YES;
    self.progressView.progressTintColor = [MVTheme accent];
    self.progressView.trackTintColor = [[MVTheme secondaryText] colorWithAlphaComponent:0.2];
    [linkCard addSubview:self.progressView];

    self.statusLabel = [UILabel new];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.numberOfLines = 3;
    self.statusLabel.font = [UIFont systemFontOfSize:13];
    self.statusLabel.textColor = [MVTheme secondaryText];
    [linkCard addSubview:self.statusLabel];

    self.busyView = [UIActivityIndicatorView new];
    self.busyView.translatesAutoresizingMaskIntoConstraints = NO;
    self.busyView.hidesWhenStopped = YES;
    self.busyView.color = [MVTheme accent];
    [linkCard addSubview:self.busyView];

    [NSLayoutConstraint activateConstraints:@[
        [self.urlField.topAnchor constraintEqualToAnchor:linkCard.topAnchor constant:14],
        [self.urlField.leadingAnchor constraintEqualToAnchor:linkCard.leadingAnchor constant:16],
        [self.urlField.heightAnchor constraintEqualToConstant:26],

        [self.pasteButton.leadingAnchor constraintEqualToAnchor:self.urlField.trailingAnchor constant:8],
        [self.pasteButton.trailingAnchor constraintEqualToAnchor:linkCard.trailingAnchor constant:-16],
        [self.pasteButton.centerYAnchor constraintEqualToAnchor:self.urlField.centerYAnchor],
        [self.pasteButton.widthAnchor constraintGreaterThanOrEqualToConstant:54],

        [divider.topAnchor constraintEqualToAnchor:self.urlField.bottomAnchor constant:12],
        [divider.leadingAnchor constraintEqualToAnchor:linkCard.leadingAnchor constant:16],
        [divider.trailingAnchor constraintEqualToAnchor:linkCard.trailingAnchor constant:-16],
        [divider.heightAnchor constraintEqualToConstant:1],

        [self.downloadButton.topAnchor constraintEqualToAnchor:divider.bottomAnchor constant:14],
        [self.downloadButton.leadingAnchor constraintEqualToAnchor:linkCard.leadingAnchor constant:16],
        [self.downloadButton.trailingAnchor constraintEqualToAnchor:linkCard.trailingAnchor constant:-16],
        [self.downloadButton.heightAnchor constraintEqualToConstant:46],

        [self.qualityButton.topAnchor constraintEqualToAnchor:self.downloadButton.bottomAnchor constant:10],
        [self.qualityButton.leadingAnchor constraintEqualToAnchor:linkCard.leadingAnchor constant:16],

        [self.progressView.topAnchor constraintEqualToAnchor:self.qualityButton.bottomAnchor constant:12],
        [self.progressView.leadingAnchor constraintEqualToAnchor:linkCard.leadingAnchor constant:16],
        [self.progressView.trailingAnchor constraintEqualToAnchor:linkCard.trailingAnchor constant:-16],

        [self.statusLabel.topAnchor constraintEqualToAnchor:self.progressView.bottomAnchor constant:10],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:linkCard.leadingAnchor constant:16],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:linkCard.trailingAnchor constant:-16],
        [self.statusLabel.bottomAnchor constraintEqualToAnchor:linkCard.bottomAnchor constant:-16],

        [self.busyView.leadingAnchor constraintEqualToAnchor:self.statusLabel.trailingAnchor constant:8],
        [self.busyView.centerYAnchor constraintEqualToAnchor:self.statusLabel.centerYAnchor],
        [self.busyView.widthAnchor constraintEqualToConstant:18],
        [self.busyView.heightAnchor constraintEqualToConstant:18],
    ]];
    [stack addArrangedSubview:linkCard];

    self.platformsTitle = [self makeSectionTitle];
    [stack addArrangedSubview:self.platformsTitle];
    [stack addArrangedSubview:[self makePlatformGrid]];

    // The screen ends here on purpose: recent downloads belong to the Downloads
    // tab, and a topics strip is noise on a screen whose one job is a link.
}

- (UILabel *)makeSectionTitle {
    UILabel *label = [UILabel new];
    label.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    label.textColor = [MVTheme text];
    return label;
}

- (UIView *)makeHeader {
    UIView *header = [UIView new];

    // Glassy icon badge on the left, brand gradient text beside it.
    UIView *badge = [UIView new];
    badge.translatesAutoresizingMaskIntoConstraints = NO;
    badge.layer.cornerRadius = 16;
    badge.layer.cornerCurve = kCACornerCurveContinuous;
    [MVTheme applyCardStyle:badge cornerRadius:16];
    UIImageView *icon = [UIImageView new];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.image = [UIImage systemImageNamed:@"play.rectangle.fill"];
    icon.tintColor = [MVTheme accent];
    [badge addSubview:icon];
    [badge.widthAnchor constraintEqualToConstant:50].active = YES;
    [badge.heightAnchor constraintEqualToConstant:50].active = YES;
    [icon.centerXAnchor constraintEqualToAnchor:badge.centerXAnchor].active = YES;
    [icon.centerYAnchor constraintEqualToAnchor:badge.centerYAnchor].active = YES;

    UILabel *tagline = [UILabel new];
    tagline.translatesAutoresizingMaskIntoConstraints = NO;
    tagline.tag = 101;
    tagline.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    tagline.textColor = [MVTheme secondaryText];
    tagline.numberOfLines = 1;

    MVGradientLabel *brand = [MVGradientLabel new];
    brand.translatesAutoresizingMaskIntoConstraints = NO;
    brand.startColor = [MVTheme accent];
    brand.endColor = [UIColor colorWithRed:0.45 green:0.30 blue:0.85 alpha:1.0];
    UIFont *brandFont = [UIFont systemFontOfSize:26 weight:UIFontWeightHeavy];
    brand.font = brandFont;
    brand.text = @"MoodyVid";

    UIStackView *texts = [UIStackView new];
    texts.axis = UILayoutConstraintAxisVertical;
    texts.spacing = 2;
    texts.translatesAutoresizingMaskIntoConstraints = NO;
    [texts addArrangedSubview:brand];
    [texts addArrangedSubview:tagline];

    UIStackView *row = [UIStackView new];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 14;
    row.alignment = UIStackViewAlignmentCenter;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [row addArrangedSubview:badge];
    [row addArrangedSubview:texts];

    [header addSubview:row];
    [NSLayoutConstraint activateConstraints:@[
        [row.topAnchor constraintEqualToAnchor:header.topAnchor],
        [row.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [row.trailingAnchor constraintLessThanOrEqualToAnchor:header.trailingAnchor],
        [row.bottomAnchor constraintEqualToAnchor:header.bottomAnchor],
    ]];

    // Keep the tagline single-line but allow it to shrink gracefully.
    [tagline setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    return header;
}

- (UIView *)makePlatformGrid {
    UIStackView *grid = [UIStackView new];
    grid.axis = UILayoutConstraintAxisVertical;
    grid.spacing = 10;

    // Two rows of four tiles; UICollectionView would be overkill here.
    for (NSInteger row = 0; row < 2; row++) {
        UIStackView *line = [UIStackView new];
        line.axis = UILayoutConstraintAxisHorizontal;
        line.distribution = UIStackViewDistributionFillEqually;
        line.spacing = 10;
        for (NSInteger col = 0; col < 4; col++) {
            MVPlatform *p = self.platforms[row * 4 + col];
            [line addArrangedSubview:[self makePlatformTile:p]];
        }
        [grid addArrangedSubview:line];
    }
    return grid;
}

- (UIView *)makePlatformTile:(MVPlatform *)platform {
    UIControl *tile = [UIControl new];
    [MVTheme applyCardStyle:tile cornerRadius:16];
    tile.translatesAutoresizingMaskIntoConstraints = NO;
    // platformTapped: reads the tile back out of self.platforms by tag.
    tile.tag = [self.platforms indexOfObject:platform];

    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:platform.symbol]];
    icon.tintColor = platform.tint;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.userInteractionEnabled = NO;
    [tile addSubview:icon];

    UILabel *name = [UILabel new];
    name.text = platform.name;
    name.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightMedium];
    name.textColor = [MVTheme secondaryText];
    name.textAlignment = NSTextAlignmentCenter;
    name.adjustsFontSizeToFitWidth = YES;
    name.minimumScaleFactor = 0.7;
    name.translatesAutoresizingMaskIntoConstraints = NO;
    name.userInteractionEnabled = NO;
    [tile addSubview:name];

    [tile addTarget:self action:@selector(platformTapped:) forControlEvents:UIControlEventTouchUpInside];

    [NSLayoutConstraint activateConstraints:@[
        [tile.heightAnchor constraintEqualToConstant:66],
        [icon.centerXAnchor constraintEqualToAnchor:tile.centerXAnchor],
        [icon.topAnchor constraintEqualToAnchor:tile.topAnchor constant:12],
        [icon.widthAnchor constraintEqualToConstant:22],
        [icon.heightAnchor constraintEqualToConstant:22],
        [name.topAnchor constraintEqualToAnchor:icon.bottomAnchor constant:5],
        [name.leadingAnchor constraintEqualToAnchor:tile.leadingAnchor constant:4],
        [name.trailingAnchor constraintEqualToAnchor:tile.trailingAnchor constant:-4],
    ]];
    return tile;
}

#pragma mark - Text and state

- (void)refreshText {
    self.title = [MVLang t:@"Home"];
    self.urlField.placeholder = [MVLang t:@"Paste video link here..."];
    [self.pasteButton setTitle:[MVLang t:@"Paste"] forState:UIControlStateNormal];
    [self updateDownloadButton];
    self.platformsTitle.text = [MVLang t:@"Quick access"];
    [self updateQualityTitle];
    self.statusLabel.text = self.statusLabel.text.length ? self.statusLabel.text : @"";

    UILabel *tagline = [self.view viewWithTag:101];
    tagline.text = MVLang.shared.isRTL ? @"حمّل الفيديوهات من أي مكان" : @"Download videos from anywhere";

    self.view.semanticContentAttribute = MVLang.shared.isRTL
        ? UISemanticContentAttributeForceRightToLeft : UISemanticContentAttributeForceLeftToRight;
    [self updatePasteButton];
    [self applyThemeRecursively];
}

/// Re-applies theme colours to views that were built once in viewDidLoad.
- (void)applyThemeRecursively {
    [MVTheme applyWallpaperTo:self.view];
    self.urlField.textColor = [MVTheme text];
    self.statusLabel.textColor = [MVTheme secondaryText];
    self.platformsTitle.textColor = [MVTheme text];
    [self updateQualityTitle];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // A wallpaper gradient is a fixed sublayer; keep its frame matching the
    // view so rotation and safe-area changes do not crop it.
    for (CALayer *layer in [self.view.layer.sublayers copy]) {
        if ([layer.name isEqualToString:@"MVWallpaperLayer"]) {
            layer.frame = self.view.bounds;
        }
    }
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (previousTraitCollection.userInterfaceStyle != self.traitCollection.userInterfaceStyle) {
        [MVTheme refreshWallpaperIfPattern:self.view];
        [self applyThemeRecursively];
    }
}

- (void)updateQualityTitle {
    NSString *label;
    if ([self.selectedQuality isEqualToString:@"1080"] || [self.selectedQuality isEqualToString:@"1440"] || [self.selectedQuality isEqualToString:@"2160"]) {
        label = [MVLang t:@"1080p HD"];
    }
    else if ([self.selectedQuality isEqualToString:@"720p"]) label = [MVLang t:@"Up to 720p"];
    else if ([self.selectedQuality isEqualToString:@"480p"]) label = [MVLang t:@"Up to 480p"];
    else if ([self.selectedQuality isEqualToString:@"audio"]) label = [MVLang t:@"Audio only (M4A)"];
    else if ([self.selectedQuality isEqualToString:@"mp3"]) label = [MVLang t:@"MP3 (audio)"];
    else label = [MVLang t:@"Best available"];
    [self.qualityButton setTitle:[NSString stringWithFormat:@"%@: %@", [MVLang t:@"Quality"], label]
                        forState:UIControlStateNormal];
}

- (void)updatePasteButton {
    // Tint rather than hide: a disabled button that vanishes teaches the user
    // nothing about what the screen can do.
    NSString *clip = UIPasteboard.generalPasteboard.string;
    BOOL hasLink = clip.length > 0 && [clip hasPrefix:@"http"];
    [self.pasteButton setTitleColor:hasLink ? [MVTheme accent] : [MVTheme secondaryText]
                           forState:UIControlStateNormal];
}

#pragma mark - Actions

- (void)platformTapped:(UIControl *)tile {
    MVPlatform *platform = self.platforms[tile.tag];
    if (!platform) return;
    if (!platform.url.length) {
        [self showHistory];
        return;
    }
    // Opens the site in the in-app browser, which injects the download button.
    [MVBrowserViewController presentFrom:self url:platform.url];
}

- (UIColor *)colorFromHex:(NSString *)hex {
    NSString *clean = [hex stringByReplacingOccurrencesOfString:@"#" withString:@""];
    if (clean.length != 6) return [MVTheme accent];
    unsigned int value = 0;
    [[NSScanner scannerWithString:clean] scanHexInt:&value];
    return [UIColor colorWithRed:((value >> 16) & 0xFF) / 255.0
                           green:((value >> 8) & 0xFF) / 255.0
                            blue:(value & 0xFF) / 255.0
                           alpha:1.0];
}

/// The trailing "More" tile: the browsing history, so a visited site is one tap
/// away without retyping its address.
- (void)showHistory {
    NSArray<MVBrowserEntry *> *entries = MVBrowserHistory.shared.history;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:[MVLang t:@"History"]
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    NSUInteger shown = 0;
    for (MVBrowserEntry *e in entries) {
        if (shown >= 12) break;
        shown++;
        NSString *label = e.title.length ? e.title : e.url;
        [sheet addAction:[UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [MVBrowserViewController presentFrom:self url:e.url];
        }]];
    }
    if (!shown) {
        [sheet setValue:[[NSAttributedString alloc] initWithString:[MVLang t:@"No history yet"]] forKey:@"attributedMessage"];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, 240, 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)pasteFromClipboard {
    NSString *clip = UIPasteboard.generalPasteboard.string;
    if (!clip.length) return;
    self.urlField.text = [clip stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

- (void)showQualityMenu {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[MVLang t:@"Choose quality"]
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray<NSArray *> *options = @[
        @[@"Best available", @"best"],
        @[@"1080p HD", @"1080"],
        @[@"Up to 720p", @"720p"],
        @[@"Up to 480p", @"480p"],
        @[@"Audio only (M4A)", @"audio"],
        @[@"MP3 (audio)", @"mp3"],
    ];
    for (NSArray *option in options) {
        NSString *quality = option[1];
        [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:option[0]] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            self.selectedQuality = quality;
            [self updateQualityTitle];
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];
    alert.popoverPresentationController.sourceView = self.qualityButton;
    alert.popoverPresentationController.sourceRect = self.qualityButton.bounds;
    [self presentViewController:alert animated:YES completion:nil];
}

/// The primary button starts a download, or stops the running one.
- (void)primaryTapped {
    if (self.busy) {
        [self cancelDownload];
    } else {
        [self startDownload];
    }
}

- (void)startDownload {
    NSString *url = [self.urlField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!url.length) {
        [self showStatus:[MVLang t:@"Please paste a link first"] color:[MVTheme warning]];
        return;
    }

    // Read the clipboard the same way the paste button does, so a copied link
    // works even if the field was not filled in.
    NSString *quality = self.selectedQuality;
    self.progressView.hidden = NO;
    self.progressView.progress = 0.0;
    [self setBusy:YES];
    [self showStatus:[MVLang t:@"Queued"] color:[MVTheme secondaryText]];

    __weak typeof(self) weakSelf = self;
    [[MVDownloadEngine shared] downloadURL:url quality:quality completion:^(NSString *filePath, NSString *error) {
        typeof(self) self_ = weakSelf;
        if (!self_) return;
        [self_ stopWatching];
        [self_ setBusy:NO];
        self_.progressView.hidden = YES;
        if (filePath.length) {
            // A path means the download worked; an error is then only a warning
            // about the photo library.
            [self_ showStatus:error ?: [MVLang t:@"Downloaded successfully"]
                        color:error ? [MVTheme warning] : [MVTheme success]];
            self_.urlField.text = @"";
        } else {
            [self_ showStatus:[NSString stringWithFormat:@"%@: %@", [MVLang t:@"Failed"],
                               error ?: [MVLang t:@"Unknown error"]]
                        color:[MVTheme danger]];
        }
        [self_ updatePasteButton];
    }];

    // The engine prepends its new record, so the first one is the job we just
    // started. Watching the store (instead of the engine) keeps the bar correct
    // even when the queue delays the actual start.
    self.watchedIdentifier = MVDownloadStore.shared.records.firstObject.identifier;
    [self beginWatching];
}

/// Follows the shared store so the bar shows real progress, speed and ETA.
- (void)beginWatching {
    if (!self.watchedIdentifier) return;
    // One observer per job: a second download would otherwise leave the first
    // block running against a stale identifier.
    [self stopWatching];
    __weak typeof(self) weakSelf = self;
    self.storeObserver = [NSNotificationCenter.defaultCenter addObserverForName:MVDownloadStoreDidChangeNotification
                                                                       object:nil queue:NSOperationQueue.mainQueue
                                                                   usingBlock:^(NSNotification *note) {
        typeof(self) self_ = weakSelf;
        if (!self_ || !self_.watchedIdentifier) return;
        MVDownloadRecord *watched = [self_ recordFor:self_.watchedIdentifier];
        if (!watched) return;

        self_.progressView.progress = (float)watched.progress;
        if (watched.state == MVDownloadStateWaiting) {
            [self_ showStatus:[MVLang t:@"Queued"] color:[MVTheme secondaryText]];
            [self_.busyView startAnimating];
        } else if (watched.isActive) {
            if (watched.progress > 0) {
                [self_ showStatus:[NSString stringWithFormat:@"%.0f%%  ·  %@  ·  ETA %@",
                                   watched.progress * 100,
                                   [MVPaths formatSpeed:watched.speed],
                                   [MVPaths formatDuration:watched.eta]]
                            color:[MVTheme secondaryText]];
                [self_.busyView stopAnimating];
            } else {
                // Pre-download phase (DNS, metadata); make the wait feel alive.
                [self_ showStatus:[MVLang t:@"Connecting…"] color:[MVTheme secondaryText]];
                [self_.busyView startAnimating];
            }
        } else {
            [self_.busyView stopAnimating];
        }
    }];
    [self.busyView stopAnimating];
}

- (void)stopWatching {
    if (self.storeObserver) {
        [NSNotificationCenter.defaultCenter removeObserver:self.storeObserver];
        self.storeObserver = nil;
    }
}

- (MVDownloadRecord *)recordFor:(NSString *)identifier {
    if (!identifier) return nil;
    for (MVDownloadRecord *r in MVDownloadStore.shared.records) {
        if ([r.identifier isEqualToString:identifier]) return r;
    }
    return nil;
}

- (void)cancelDownload {
    if (!self.watchedIdentifier) return;
    [[MVDownloadEngine shared] cancelDownload:self.watchedIdentifier];
    [self stopWatching];
    [self setBusy:NO];
    self.progressView.hidden = YES;
    [self showStatus:[MVLang t:@"Cancel"] color:[MVTheme warning]];
}

/// Toggles the primary button between "Download" and "Cancel" and keeps the
/// paste button out of the way while a job is in flight.
- (void)setBusy:(BOOL)busy {
    _busy = busy;
    [self updateDownloadButton];
}

- (void)updateDownloadButton {
    NSString *title = self.busy ? [MVLang t:@"Cancel download"] : [MVLang t:@"Download"];
    [self.downloadButton setTitle:title forState:UIControlStateNormal];
    self.downloadButton.backgroundColor = self.busy ? [MVTheme danger] : [MVTheme accent];
    self.downloadButton.enabled = YES;
    self.downloadButton.alpha = 1.0;
}

- (void)showStatus:(NSString *)text color:(UIColor *)color {
    self.statusLabel.text = text;
    self.statusLabel.textColor = color;
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

@end
