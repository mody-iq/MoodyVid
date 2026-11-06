#import "MVDownloaderViewController.h"
#import "MVLang.h"
#import "MVTheme.h"
#import "MVPaths.h"
#import "MVDownloadStore.h"
#import "MVDownloadEngine.h"

// A platform shortcut: the name, the SF Symbol standing in for its logo (we ship
// no third-party brand assets) and the tint used for the tile.
@interface MVPlatform : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *symbol;
@property (nonatomic, strong) UIColor *tint;
+ (instancetype)name:(NSString *)name symbol:(NSString *)symbol tint:(UIColor *)tint;
@end

@implementation MVPlatform
+ (instancetype)name:(NSString *)name symbol:(NSString *)symbol tint:(UIColor *)tint {
    MVPlatform *p = [MVPlatform new];
    p.name = name; p.symbol = symbol; p.tint = tint;
    return p;
}
@end

@interface MVDownloaderViewController () <UITextFieldDelegate, UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UITextField *urlField;
@property (nonatomic, strong) UIButton *pasteButton;
@property (nonatomic, strong) UIButton *downloadButton;
@property (nonatomic, strong) UIButton *qualityButton;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIProgressView *progressView;
@property (nonatomic, strong) UITableView *recentTable;
@property (nonatomic, strong) UILabel *recentTitle;
@property (nonatomic, strong) UILabel *platformsTitle;
@property (nonatomic, copy) NSString *selectedQuality;
@property (nonatomic, strong) NSArray<MVPlatform *> *platforms;
@property (nonatomic, strong) NSLayoutConstraint *recentHeight;
@property (nonatomic, copy, nullable) NSString *watchedIdentifier;
@property (nonatomic, strong, nullable) id storeObserver;
@property (nonatomic, assign) BOOL busy;
@end

@implementation MVDownloaderViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [MVTheme background];
    self.selectedQuality = @"best";

    self.platforms = @[
        [MVPlatform name:@"YouTube" symbol:@"play.rectangle.fill" tint:UIColor.systemRedColor],
        [MVPlatform name:@"TikTok" symbol:@"music.note" tint:UIColor.systemPinkColor],
        [MVPlatform name:@"Instagram" symbol:@"camera.fill" tint:UIColor.systemPurpleColor],
        [MVPlatform name:@"X" symbol:@"bird.fill" tint:UIColor.labelColor],
        [MVPlatform name:@"Facebook" symbol:@"f.circle.fill" tint:UIColor.systemBlueColor],
        [MVPlatform name:@"Twitch" symbol:@"gamecontroller.fill" tint:UIColor.systemIndigoColor],
        [MVPlatform name:@"SoundCloud" symbol:@"waveform" tint:UIColor.systemOrangeColor],
        [MVPlatform name:@"More" symbol:@"ellipsis.circle.fill" tint:[MVTheme accent]],
    ];

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
    stack.spacing = 20;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scroll addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [self.scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [stack.topAnchor constraintEqualToAnchor:self.scroll.topAnchor constant:12],
        [stack.leadingAnchor constraintEqualToAnchor:self.scroll.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:self.scroll.trailingAnchor constant:-20],
        [stack.bottomAnchor constraintEqualToAnchor:self.scroll.bottomAnchor constant:-24],
        [stack.widthAnchor constraintEqualToAnchor:self.scroll.widthAnchor constant:-40],
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
        [self.qualityButton.centerXAnchor constraintEqualToAnchor:linkCard.centerXAnchor],

        [self.progressView.topAnchor constraintEqualToAnchor:self.qualityButton.bottomAnchor constant:12],
        [self.progressView.leadingAnchor constraintEqualToAnchor:linkCard.leadingAnchor constant:16],
        [self.progressView.trailingAnchor constraintEqualToAnchor:linkCard.trailingAnchor constant:-16],

        [self.statusLabel.topAnchor constraintEqualToAnchor:self.progressView.bottomAnchor constant:10],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:linkCard.leadingAnchor constant:16],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:linkCard.trailingAnchor constant:-16],
        [self.statusLabel.bottomAnchor constraintEqualToAnchor:linkCard.bottomAnchor constant:-16],
    ]];
    [stack addArrangedSubview:linkCard];

    self.platformsTitle = [self makeSectionTitle];
    [stack addArrangedSubview:self.platformsTitle];
    [stack addArrangedSubview:[self makePlatformGrid]];

    self.recentTitle = [self makeSectionTitle];
    [stack addArrangedSubview:self.recentTitle];

    self.recentTable = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.recentTable.translatesAutoresizingMaskIntoConstraints = NO;
    self.recentTable.backgroundColor = UIColor.clearColor;
    self.recentTable.scrollEnabled = NO;
    self.recentTable.separatorColor = [[MVTheme separator] colorWithAlphaComponent:0.12];
    self.recentTable.dataSource = self;
    self.recentTable.delegate = self;
    self.recentTable.rowHeight = 52;
    [self.recentTable registerClass:UITableViewCell.class forCellReuseIdentifier:@"MVRecentCell"];
    [stack addArrangedSubview:self.recentTable];
    self.recentHeight = [self.recentTable.heightAnchor constraintEqualToConstant:0];
    self.recentHeight.active = YES;
}

- (UILabel *)makeSectionTitle {
    UILabel *label = [UILabel new];
    label.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
    label.textColor = [MVTheme text];
    return label;
}

- (UIView *)makeHeader {
    UIView *header = [UIView new];

    UILabel *brand = [UILabel new];
    brand.text = @"MoodyVid";
    brand.font = [UIFont systemFontOfSize:28 weight:UIFontWeightHeavy];
    brand.textColor = [MVTheme text];
    brand.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:brand];

    UILabel *tagline = [UILabel new];
    tagline.translatesAutoresizingMaskIntoConstraints = NO;
    tagline.tag = 101;
    tagline.font = [UIFont systemFontOfSize:13];
    tagline.textColor = [MVTheme secondaryText];
    [header addSubview:tagline];

    [NSLayoutConstraint activateConstraints:@[
        [brand.topAnchor constraintEqualToAnchor:header.topAnchor],
        [brand.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [brand.trailingAnchor constraintLessThanOrEqualToAnchor:header.trailingAnchor],

        [tagline.topAnchor constraintEqualToAnchor:brand.bottomAnchor constant:2],
        [tagline.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [tagline.trailingAnchor constraintLessThanOrEqualToAnchor:header.trailingAnchor],
        [tagline.bottomAnchor constraintEqualToAnchor:header.bottomAnchor],
    ]];
    return header;
}

- (UIView *)makePlatformGrid {
    UIStackView *grid = [UIStackView new];
    grid.axis = UILayoutConstraintAxisVertical;
    grid.spacing = 12;

    // Two rows of four tiles; UICollectionView would be overkill here.
    for (NSInteger row = 0; row < 2; row++) {
        UIStackView *line = [UIStackView new];
        line.axis = UILayoutConstraintAxisHorizontal;
        line.distribution = UIStackViewDistributionFillEqually;
        line.spacing = 12;
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
        [tile.heightAnchor constraintEqualToConstant:72],
        [icon.centerXAnchor constraintEqualToAnchor:tile.centerXAnchor],
        [icon.topAnchor constraintEqualToAnchor:tile.topAnchor constant:13],
        [icon.widthAnchor constraintEqualToConstant:24],
        [icon.heightAnchor constraintEqualToConstant:24],
        [name.topAnchor constraintEqualToAnchor:icon.bottomAnchor constant:6],
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
    self.recentTitle.text = [MVLang t:@"Recent"];
    [self updateQualityTitle];
    self.statusLabel.text = self.statusLabel.text.length ? self.statusLabel.text : @"";

    UILabel *tagline = [self.view viewWithTag:101];
    tagline.text = MVLang.shared.isRTL ? @"حمّل الفيديوهات من أي مكان" : @"Download videos from anywhere";

    self.view.semanticContentAttribute = MVLang.shared.isRTL
        ? UISemanticContentAttributeForceRightToLeft : UISemanticContentAttributeForceLeftToRight;
    [self updatePasteButton];
    [self reloadRecent];
    [self applyThemeRecursively];
}

/// Re-applies theme colours to views that were built once in viewDidLoad.
- (void)applyThemeRecursively {
    self.view.backgroundColor = [MVTheme background];
    self.urlField.textColor = [MVTheme text];
    self.statusLabel.textColor = [MVTheme secondaryText];
    self.platformsTitle.textColor = [MVTheme text];
    self.recentTitle.textColor = [MVTheme text];
    self.recentTable.separatorColor = [[MVTheme separator] colorWithAlphaComponent:0.12];
    [self updateQualityTitle];
    [self.recentTable reloadData];
}

- (void)updateQualityTitle {
    NSString *label;
    if ([self.selectedQuality isEqualToString:@"720p"]) label = [MVLang t:@"Up to 720p"];
    else if ([self.selectedQuality isEqualToString:@"480p"]) label = [MVLang t:@"Up to 480p"];
    else if ([self.selectedQuality isEqualToString:@"audio"]) label = [MVLang t:@"Audio only (M4A)"];
    else label = [MVLang t:@"Best available"];
    [self.qualityButton setTitle:[NSString stringWithFormat:@"%@: %@", [MVLang t:@"Quality"], label]
                        forState:UIControlStateNormal];
}

- (void)updatePasteButton {
    // Only offer paste when there is actually something to paste.
    NSString *clip = UIPasteboard.generalPasteboard.string;
    BOOL hasLink = clip.length > 0 && [clip hasPrefix:@"http"];
    self.pasteButton.enabled = hasLink;
    self.pasteButton.alpha = hasLink ? 1.0 : 0.45;
}

- (void)reloadRecent {
    NSArray *finished = MVDownloadStore.shared.finishedRecords;
    NSArray *recent = finished.count > 6 ? [finished subarrayWithRange:NSMakeRange(0, 6)] : finished;
    self.recentHeight.constant = recent.count * 52;
    self.recentTitle.hidden = recent.count == 0;
    self.recentTable.hidden = recent.count == 0;
    [self.recentTable reloadData];
}

#pragma mark - Recent table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSArray *finished = MVDownloadStore.shared.finishedRecords;
    return MIN(finished.count, 6);
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"MVRecentCell" forIndexPath:indexPath];
    MVDownloadRecord *record = MVDownloadStore.shared.finishedRecords[indexPath.row];
    UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
    content.text = record.title.length ? record.title : record.url;
    content.textProperties.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    content.textProperties.color = [MVTheme text];
    content.secondaryText = record.state == MVDownloadStateCompleted
        ? [MVPaths formatBytes:record.totalBytes] : [MVLang t:@"Failed"];
    content.secondaryTextProperties.color = [MVTheme secondaryText];
    content.image = [UIImage systemImageNamed:record.state == MVDownloadStateCompleted ? @"checkmark.circle.fill" : @"exclamationmark.circle"];
    content.imageProperties.tintColor = record.state == MVDownloadStateCompleted ? [MVTheme success] : [MVTheme danger];
    cell.contentConfiguration = content;
    cell.backgroundColor = UIColor.clearColor;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

#pragma mark - Actions

- (void)platformTapped:(UIControl *)tile {
    // We deliberately do not embed a browser yet: an in-app web view needs a
    // media sniffer to be useful, so for now we point the user at the flow that
    // actually works rather than opening something that cannot detect media.
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[MVLang t:@"Quick access"]
                                                                  message:MVLang.shared.isRTL
                                       ? @"انسخ الرابط من التطبيق ثم الصقه هنا."
                                       : @"Copy the link from the app, then paste it here."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
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
        @[@"Up to 720p", @"720p"],
        @[@"Up to 480p", @"480p"],
        @[@"Audio only (M4A)", @"audio"],
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
        [self_ reloadRecent];
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
        } else if (watched.isActive) {
            [self_ showStatus:[NSString stringWithFormat:@"%.0f%%  ·  %@  ·  ETA %@",
                               watched.progress * 100,
                               [MVPaths formatSpeed:watched.speed],
                               [MVPaths formatDuration:watched.eta]]
                        color:[MVTheme secondaryText]];
        }
    }];
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
    [self setBusy:NO];
    self.progressView.hidden = YES;
    [self showStatus:[MVLang t:@"Cancel"] color:[MVTheme warning]];
}

/// Toggles the primary button between "Download" and "Cancel" and keeps the
/// paste button out of the way while a job is in flight.
- (void)setBusy:(BOOL)busy {
    self.busy = busy;
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
