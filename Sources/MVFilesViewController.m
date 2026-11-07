#import "MVFilesViewController.h"
#import <AVKit/AVKit.h>
#import <AVFoundation/AVFoundation.h>
#import "MVPlayerCenter.h"
#import "MVPaths.h"
#import "MVLang.h"
#import "MVTheme.h"
#import "MVDownloadStore.h"
#import "MVDownloadEngine.h"

typedef NS_ENUM(NSInteger, MVSortMode) {
    MVSortModeName = 0,
    MVSortModeDate = 1,
    MVSortModeSize = 2,
};

@interface MVFilesViewController () <UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) UILabel *storageLabel;
@property (nonatomic, strong) UIView *headerView;
@property (nonatomic, strong) UISearchController *search;
@property (nonatomic, copy) NSString *filter;
@property (nonatomic) MVSortMode sortMode;

// Inline player: videos play here, inside the tab page, instead of a black
// full-screen modal. It carries the same transport as the floating mini bar
// (previous / 15s back / play-pause / 15s forward / next) plus a scrubber.
@property (nonatomic, strong) UIView *playerCard;
@property (nonatomic, strong) UIView *videoSurface;
@property (nonatomic, strong) AVPlayerLayer *videoLayer;
@property (nonatomic, strong) UILabel *nowTitleLabel;
@property (nonatomic, strong) UIButton *prevButton;
@property (nonatomic, strong) UIButton *backButton;
@property (nonatomic, strong) UIButton *playPauseButton;
@property (nonatomic, strong) UIButton *forwardButton;
@property (nonatomic, strong) UIButton *nextButton;
@property (nonatomic, strong) UIButton *cardCloseButton;
@property (nonatomic, strong) UISlider *cardSlider;
@property (nonatomic, strong) UILabel *cardTimeLabel;
@property (nonatomic, assign) BOOL cardOpen;
@property (nonatomic, strong) NSLayoutConstraint *cardHeight;
@property (nonatomic, strong) id cardObserver;
@property (nonatomic, strong) NSTimer *cardTicker;
@end

@implementation MVFilesViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    self.title = [MVLang t:@"Files"];

    UIBarButtonItem *newFolder = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"folder.badge.plus"]
                                                                style:UIBarButtonItemStylePlain
                                                               target:self action:@selector(createFolder)];
    UIBarButtonItem *sort = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.up.arrow.down"]
                                                            style:UIBarButtonItemStylePlain
                                                           target:self action:@selector(showSortMenu)];
    self.navigationItem.rightBarButtonItems = @[newFolder, sort];

    self.storageLabel = [UILabel new];
    self.storageLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    self.storageLabel.textColor = [MVTheme secondaryText];
    self.storageLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.storageLabel];

    // A plain list, full-bleed under the translucent chrome, so it scrolls and
    // feels like the rest of the system rather than a floating inset panel.
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.backgroundColor = UIColor.clearColor;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = 60;
    self.tableView.estimatedRowHeight = 60;
    self.tableView.separatorInset = UIEdgeInsetsMake(0, 74, 0, 0);
    self.tableView.separatorColor = [[MVTheme separator] colorWithAlphaComponent:0.28];
    self.tableView.tableFooterView = [UIView new];
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"MVFileCell"];
    [self.view addSubview:self.tableView];

    // Must be added after the table exists, or the gesture is attached to nil.
    UILongPressGestureRecognizer *longPress =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPressRow:)];
    [self.tableView addGestureRecognizer:longPress];

    self.emptyLabel = [UILabel new];
    self.emptyLabel.textColor = [MVTheme secondaryText];
    self.emptyLabel.font = [UIFont systemFontOfSize:15];
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.emptyLabel];

    self.search = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.search.searchResultsUpdater = self;
    self.search.obscuresBackgroundDuringPresentation = NO;
    self.navigationItem.searchController = self.search;
    self.navigationItem.hidesSearchBarWhenScrolling = YES;
    self.definesPresentationContext = YES;

    [self buildPlayerCard];

    // The player and the storage line live in the table's header, so the video
    // is part of the page and scrolls with it, rather than floating over it.
    self.cardHeight = [self.playerCard.heightAnchor constraintEqualToConstant:0];
    self.headerView = [UIView new];
    [self.headerView addSubview:self.storageLabel];
    [self.headerView addSubview:self.playerCard];
    self.tableView.tableHeaderView = self.headerView;

    [NSLayoutConstraint activateConstraints:@[
        [self.storageLabel.topAnchor constraintEqualToAnchor:self.headerView.topAnchor constant:4],
        [self.storageLabel.leadingAnchor constraintEqualToAnchor:self.headerView.leadingAnchor constant:20],
        [self.storageLabel.trailingAnchor constraintEqualToAnchor:self.headerView.trailingAnchor constant:-20],

        [self.playerCard.topAnchor constraintEqualToAnchor:self.storageLabel.bottomAnchor constant:10],
        [self.playerCard.leadingAnchor constraintEqualToAnchor:self.headerView.leadingAnchor constant:16],
        [self.playerCard.trailingAnchor constraintEqualToAnchor:self.headerView.trailingAnchor constant:-16],
        [self.playerCard.bottomAnchor constraintEqualToAnchor:self.headerView.bottomAnchor constant:-8],
        self.cardHeight,

        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
    ]];
    self.cardHeight.constant = 0;
    self.playerCard.hidden = YES;
    [self sizeHeaderToFit];

    for (NSString *name in @[MVDownloadStoreDidChangeNotification, MVLangDidChangeNotification, MVThemeDidChangeNotification]) {
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:name object:nil];
    }
    [self refresh];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refresh];
    if (self.cardOpen) {
        [self cardStateChanged];
        // The card is back on screen and is the control again.
        [[MVPlayerCenter shared] hideFloatingBar];
    }
}

- (NSString *)currentDirectory { return self.rootOverride ?: [MVPaths downloads]; }

- (NSArray<NSString *> *)entries {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:[self currentDirectory] error:nil] ?: @[];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *name in names) {
        if ([name hasPrefix:@"."]) continue;
        if ([name isEqualToString:@"downloads.json"]) continue;
        if (self.filter.length && ![name localizedCaseInsensitiveContainsString:self.filter]) continue;
        [out addObject:name];
    }

    NSString *dir = [self currentDirectory];
    return [out sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSString *pa = [dir stringByAppendingPathComponent:a];
        NSString *pb = [dir stringByAppendingPathComponent:b];
        NSDictionary *da = [fm attributesOfItemAtPath:pa error:nil] ?: @{};
        NSDictionary *db = [fm attributesOfItemAtPath:pb error:nil] ?: @{};
        BOOL dirA = [da[NSFileType] isEqual:NSFileTypeDirectory];
        BOOL dirB = [db[NSFileType] isEqual:NSFileTypeDirectory];
        // Folders always lead, whichever sort is chosen.
        if (dirA != dirB) return dirA ? NSOrderedAscending : NSOrderedDescending;
        switch (self.sortMode) {
            case MVSortModeDate: {
                NSDate *ta = da[NSFileModificationDate] ?: NSDate.distantPast;
                NSDate *tb = db[NSFileModificationDate] ?: NSDate.distantPast;
                return [tb compare:ta];
            }
            case MVSortModeSize:
                return [db[NSFileSize] longLongValue] > [da[NSFileSize] longLongValue] ? NSOrderedAscending : NSOrderedDescending;
            case MVSortModeName:
            default:
                return [a localizedStandardCompare:b];
        }
    }];
}

- (void)refresh {
    self.title = [MVLang t:@"Files"];
    self.emptyLabel.text = [MVLang t:@"No files"];
    self.search.searchBar.placeholder = [MVLang t:@"Search files"];
    self.storageLabel.text = [NSString stringWithFormat:@"%@ %@",
                              [MVPaths formatBytes:[MVPaths freeSpace]], [MVLang t:@"available"]];
    [MVTheme applyWallpaperTo:self.view];
    [self.tableView reloadData];
}

#pragma mark - Inline player card

- (void)buildPlayerCard {
    self.playerCard = [UIView new];
    self.playerCard.translatesAutoresizingMaskIntoConstraints = NO;
    self.playerCard.clipsToBounds = YES;
    [MVTheme applyCardStyle:self.playerCard cornerRadius:20];

    self.videoSurface = [UIView new];
    self.videoSurface.translatesAutoresizingMaskIntoConstraints = NO;
    self.videoSurface.backgroundColor = [[MVTheme background] colorWithAlphaComponent:0.25];
    self.videoSurface.layer.masksToBounds = YES;
    self.videoSurface.layer.cornerRadius = 14;
    self.videoSurface.layer.borderWidth = 0.5;
    self.videoSurface.layer.borderColor = [[MVTheme cardBorder] colorWithAlphaComponent:0.3].CGColor;
    [self.playerCard addSubview:self.videoSurface];

    self.nowTitleLabel = [UILabel new];
    self.nowTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.nowTitleLabel.numberOfLines = 2;
    self.nowTitleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    self.nowTitleLabel.textColor = [MVTheme text];
    self.nowTitleLabel.text = [MVLang t:@"Now playing"];
    [self.playerCard addSubview:self.nowTitleLabel];

    self.cardSlider = [UISlider new];
    self.cardSlider.translatesAutoresizingMaskIntoConstraints = NO;
    self.cardSlider.minimumTrackTintColor = [MVTheme accent];
    self.cardSlider.maximumTrackTintColor = [[MVTheme secondaryText] colorWithAlphaComponent:0.3];
    [self.cardSlider setThumbTintColor:[MVTheme accent]];
    [self.cardSlider addTarget:self action:@selector(cardScrub) forControlEvents:UIControlEventValueChanged];
    [self.cardSlider addTarget:self action:@selector(cardScrubEnd) forControlEvents:UIControlEventTouchUpInside];
    [self.cardSlider addTarget:self action:@selector(cardScrubEnd) forControlEvents:UIControlEventTouchUpOutside];
    [self.playerCard addSubview:self.cardSlider];

    self.cardTimeLabel = [UILabel new];
    self.cardTimeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.cardTimeLabel.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.cardTimeLabel.textColor = [MVTheme secondaryText];
    self.cardTimeLabel.text = @"0:00 / 0:00";
    [self.playerCard addSubview:self.cardTimeLabel];

    // Transport: prev / back 15 / play-pause / forward 15 / next, centered.
    // Anchored from the centre so it stays balanced on any width.
    self.prevButton = [self cardButton:@"backward.end.fill" action:@selector(inlinePrev)];
    self.backButton = [self cardButton:@"gobackward.15" action:@selector(inlineBack)];
    self.playPauseButton = [self cardButton:@"pause.fill" action:@selector(toggleInlinePlay)];
    self.forwardButton = [self cardButton:@"goforward.15" action:@selector(inlineForward)];
    self.nextButton = [self cardButton:@"forward.end.fill" action:@selector(inlineNext)];

    self.cardCloseButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.cardCloseButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.cardCloseButton setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
    self.cardCloseButton.tintColor = [[MVTheme text] colorWithAlphaComponent:0.7];
    self.cardCloseButton.backgroundColor = [[MVTheme background] colorWithAlphaComponent:0.35];
    self.cardCloseButton.layer.cornerRadius = 15;
    self.cardCloseButton.clipsToBounds = YES;
    [self.cardCloseButton addTarget:self action:@selector(closeInlinePlayer) forControlEvents:UIControlEventTouchUpInside];
    [self.playerCard addSubview:self.cardCloseButton];

    UILayoutPriority inner = UILayoutPriorityDefaultHigh;
    NSLayoutConstraint *surfaceTop = [self.videoSurface.topAnchor constraintEqualToAnchor:self.playerCard.topAnchor constant:12];
    surfaceTop.priority = inner;
    NSLayoutConstraint *collapseBottom = [self.nextButton.bottomAnchor constraintEqualToAnchor:self.playerCard.bottomAnchor constant:-10];
    collapseBottom.priority = inner;

    NSLayoutConstraint *videoAspect = [self.videoSurface.heightAnchor
        constraintEqualToAnchor:self.videoSurface.widthAnchor multiplier:9.0/16.0];
    videoAspect.priority = UILayoutPriorityRequired;

    // Transport spacing: five 36pt buttons (play 44) with 10pt gaps, centred.
    [NSLayoutConstraint activateConstraints:@[
        [self.videoSurface.leadingAnchor constraintEqualToAnchor:self.playerCard.leadingAnchor constant:12],
        [self.videoSurface.trailingAnchor constraintEqualToAnchor:self.playerCard.trailingAnchor constant:-12],
        videoAspect,
        surfaceTop,

        [self.cardCloseButton.centerXAnchor constraintEqualToAnchor:self.videoSurface.trailingAnchor constant:-16],
        [self.cardCloseButton.centerYAnchor constraintEqualToAnchor:self.videoSurface.topAnchor constant:16],
        [self.cardCloseButton.widthAnchor constraintEqualToConstant:30],
        [self.cardCloseButton.heightAnchor constraintEqualToConstant:30],

        [self.nowTitleLabel.topAnchor constraintEqualToAnchor:self.videoSurface.bottomAnchor constant:10],
        [self.nowTitleLabel.leadingAnchor constraintEqualToAnchor:self.playerCard.leadingAnchor constant:16],
        [self.nowTitleLabel.trailingAnchor constraintEqualToAnchor:self.playerCard.trailingAnchor constant:-16],

        [self.cardSlider.topAnchor constraintEqualToAnchor:self.nowTitleLabel.bottomAnchor constant:6],
        [self.cardSlider.leadingAnchor constraintEqualToAnchor:self.playerCard.leadingAnchor constant:16],
        [self.cardSlider.trailingAnchor constraintEqualToAnchor:self.playerCard.trailingAnchor constant:-16],

        [self.cardTimeLabel.topAnchor constraintEqualToAnchor:self.cardSlider.bottomAnchor constant:2],
        [self.cardTimeLabel.centerXAnchor constraintEqualToAnchor:self.playerCard.centerXAnchor],

        // Transport chain, right-to-left, anchored at the centre.
        [self.nextButton.centerYAnchor constraintEqualToAnchor:self.cardTimeLabel.bottomAnchor constant:14],
        [self.nextButton.trailingAnchor constraintEqualToAnchor:self.playerCard.centerXAnchor constant:106],
        [self.nextButton.widthAnchor constraintEqualToConstant:36],
        [self.nextButton.heightAnchor constraintEqualToConstant:36],

        [self.forwardButton.centerYAnchor constraintEqualToAnchor:self.nextButton.centerYAnchor],
        [self.forwardButton.trailingAnchor constraintEqualToAnchor:self.nextButton.leadingAnchor constant:-10],
        [self.forwardButton.widthAnchor constraintEqualToConstant:36],
        [self.forwardButton.heightAnchor constraintEqualToConstant:36],

        [self.playPauseButton.centerYAnchor constraintEqualToAnchor:self.nextButton.centerYAnchor],
        [self.playPauseButton.trailingAnchor constraintEqualToAnchor:self.forwardButton.leadingAnchor constant:-10],
        [self.playPauseButton.widthAnchor constraintEqualToConstant:44],
        [self.playPauseButton.heightAnchor constraintEqualToConstant:44],

        [self.backButton.centerYAnchor constraintEqualToAnchor:self.nextButton.centerYAnchor],
        [self.backButton.trailingAnchor constraintEqualToAnchor:self.playPauseButton.leadingAnchor constant:-10],
        [self.backButton.widthAnchor constraintEqualToConstant:36],
        [self.backButton.heightAnchor constraintEqualToConstant:36],

        [self.prevButton.centerYAnchor constraintEqualToAnchor:self.nextButton.centerYAnchor],
        [self.prevButton.trailingAnchor constraintEqualToAnchor:self.backButton.leadingAnchor constant:-10],
        [self.prevButton.widthAnchor constraintEqualToConstant:36],
        [self.prevButton.heightAnchor constraintEqualToConstant:36],
        [self.prevButton.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.playerCard.leadingAnchor constant:16],
        collapseBottom,
    ]];
}

/// Builds a transport button sharing the player's look.
- (UIButton *)cardButton:(NSString *)symbol action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    b.tintColor = [MVTheme text];
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self.playerCard addSubview:b];
    return b;
}

/// Picks the biggest play/pause image of all the transport buttons.
- (UIImage *)playPauseImageForState:(BOOL)playing {
    NSString *name = playing ? @"pause.fill" : @"play.fill";
    return [UIImage systemImageNamed:name withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightSemibold]];
}

/// Refreshes the inline card when the shared player's state changes.
- (void)cardStateChanged {
    if (!self.cardOpen) return;
    MVPlayerCenter *center = MVPlayerCenter.shared;
    self.nowTitleLabel.text = center.currentTitle.length ? center.currentTitle : [MVLang t:@"Now playing"];
    UIImage *img = center.isPlaying ? [self playPauseImageForState:YES] : [self playPauseImageForState:NO];
    [self.playPauseButton setImage:img forState:UIControlStateNormal];

    // Update the scrubber + time, but not while the user is dragging it.
    if (center.duration > 0) {
        self.cardSlider.maximumValue = (float)center.duration;
        if (!self.cardSlider.tracking) self.cardSlider.value = (float)center.currentTime;
    }
    self.cardTimeLabel.text = [NSString stringWithFormat:@"%@ / %@",
                               [self cardClock:center.currentTime],
                               [self cardClock:center.duration]];

    // Dim previous/next when the queue has only one item.
    BOOL hasQueue = center.hasQueue;
    self.prevButton.enabled = hasQueue;
    self.nextButton.enabled = hasQueue;
    self.prevButton.alpha = hasQueue ? 1.0 : 0.4;
    self.nextButton.alpha = hasQueue ? 1.0 : 0.4;
}

- (NSString *)cardClock:(double)s {
    if (s <= 0) return @"0:00";
    NSInteger total = (NSInteger)s;
    return [NSString stringWithFormat:@"%ld:%02ld", (long)(total / 60), (long)(total % 60)];
}

- (void)openInlinePlayer {
    MVPlayerCenter *center = MVPlayerCenter.shared;
    self.cardOpen = YES;
    self.playerCard.hidden = NO;

    if (!self.videoLayer) {
        self.videoLayer = [AVPlayerLayer playerLayerWithPlayer:center.player];
        self.videoLayer.videoGravity = AVLayerVideoGravityResizeAspect;
        self.videoLayer.frame = self.videoSurface.bounds;
        self.videoLayer.masksToBounds = YES;
        [self.videoSurface.layer addSublayer:self.videoLayer];
    }

    // Height derived from the card's real width so there is no empty band
    // under the transport on very wide phones.
    CGFloat contentW = self.headerView.bounds.size.width - 32.0;
    if (contentW <= 0) contentW = 320.0;
    self.cardHeight.constant = contentW * 9.0 / 16.0 + 148.0;
    [self.headerView layoutIfNeeded];
    [self sizeHeaderToFit];
    [self cardStateChanged];
    [center hideFloatingBar];

    if (!self.cardObserver) {
        __weak typeof(self) weakSelf = self;
        self.cardObserver = [NSNotificationCenter.defaultCenter addObserverForName:MVDownloadStoreDidChangeNotification
                                                                          object:nil queue:NSOperationQueue.mainQueue
                                                                        usingBlock:^(NSNotification *note) {
            [weakSelf cardStateChanged];
        }];
    }
    [self.cardTicker invalidate];
    __weak typeof(self) weakSelf = self;
    self.cardTicker = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) {
        [weakSelf cardStateChanged];
    }];
}

- (void)dealloc {
    [self.cardTicker invalidate];
    if (self.cardObserver) [NSNotificationCenter.defaultCenter removeObserver:self.cardObserver];
}

- (void)toggleInlinePlay {
    [[MVPlayerCenter shared] toggle];
    [self cardStateChanged];
}

- (void)inlinePrev { [[MVPlayerCenter shared] playPrevious]; [self cardStateChanged]; }
- (void)inlineNext { [[MVPlayerCenter shared] playNext]; [self cardStateChanged]; }
- (void)inlineBack { [[MVPlayerCenter shared] seekBack]; [self cardStateChanged]; }
- (void)inlineForward { [[MVPlayerCenter shared] seekForward]; [self cardStateChanged]; }

- (void)cardScrub {
    [[MVPlayerCenter shared] seekToSeconds:self.cardSlider.value];
}

- (void)cardScrubEnd {
    [self cardStateChanged];
}

- (void)closeInlinePlayer {
    self.cardOpen = NO;
    self.cardHeight.constant = 0;
    [self.cardTicker invalidate];
    [self.videoLayer removeFromSuperlayer];
    self.videoLayer = nil;
    [self.headerView layoutIfNeeded];
    [self sizeHeaderToFit];
    self.playerCard.hidden = YES;
    // Hand control back to the floating mini bar (playback itself continues).
    [[MVPlayerCenter shared] showFloatingBar];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    // Moving to another tab or folder: playback continues via the mini bar so
    // it is still controllable, even though the card is no longer visible.
    if (self.cardOpen && self.view.window) {
        [[MVPlayerCenter shared] showFloatingBar];
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    for (CALayer *layer in [self.view.layer.sublayers copy]) {
        if ([layer.name isEqualToString:@"MVWallpaperLayer"]) layer.frame = self.view.bounds;
    }
    if (self.videoLayer) self.videoLayer.frame = self.videoSurface.bounds;
}

/// The header is sized by its bottom constraint, so the table needs an explicit
/// height or it never shows the card/scroll offset correctly.
- (void)sizeHeaderToFit {
    UIView *header = self.tableView.tableHeaderView;
    if (!header) return;
    [header setNeedsLayout];
    [header layoutIfNeeded];
    CGRect frame = header.frame;
    frame.size.height = [header systemLayoutSizeFittingSize:UILayoutFittingCompressedSize].height;
    if (frame.size.height < 1) frame.size.height = 1;
    header.frame = frame;
    self.tableView.tableHeaderView = header;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (previousTraitCollection.userInterfaceStyle != self.traitCollection.userInterfaceStyle) {
        [MVTheme refreshWallpaperIfPattern:self.view];
    }
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    self.filter = searchController.searchBar.text ?: @"";
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSArray *entries = [self entries];
    self.emptyLabel.hidden = entries.count > 0;
    return entries.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"MVFileCell" forIndexPath:indexPath];
    NSString *name = [self entries][indexPath.row];
    NSString *path = [[self currentDirectory] stringByAppendingPathComponent:name];
    BOOL isDir = NO;
    [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDir];

    UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
    content.text = name;
    content.textProperties.color = [MVTheme text];
    content.textProperties.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    content.secondaryTextProperties.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    content.imageProperties.reservedLayoutSize = CGSizeMake(50, 36);
    content.imageProperties.maximumSize = CGSizeMake(50, 36);

    if (isDir) {
        content.image = [UIImage systemImageNamed:@"folder.fill"];
        content.secondaryText = [MVLang t:@"Empty folder"];
    } else {
        NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
        long long size = [attrs[NSFileSize] longLongValue];
        NSDate *date = attrs[NSFileModificationDate];
        NSString *ext = path.pathExtension.lowercaseString;
        NSString *thumbPath = [self thumbnailForPath:path];
        if (thumbPath) {
            content.image = [UIImage imageWithContentsOfFile:thumbPath];
            content.imageProperties.maximumSize = CGSizeMake(88, 50);
            content.imageProperties.cornerRadius = 8;
        } else {
            content.image = [UIImage systemImageNamed:[self symbolForExtension:ext]];
        }
        content.secondaryText = [NSString stringWithFormat:@"%@  ·  %@",
                                 [MVPaths formatBytes:size],
                                 [NSDateFormatter localizedStringFromDate:date dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterShortStyle]];
    }
    content.secondaryTextProperties.color = [MVTheme secondaryText];
    content.imageProperties.tintColor = [MVTheme accent];
    cell.contentConfiguration = content;
    cell.backgroundColor = UIColor.clearColor;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}

- (NSString *)symbolForExtension:(NSString *)ext {
    if ([ext isEqualToString:@"mp4"] || [ext isEqualToString:@"mov"] || [ext isEqualToString:@"m4v"] || [ext isEqualToString:@"mkv"] || [ext isEqualToString:@"webm"]) return @"play.rectangle.fill";
    if ([ext isEqualToString:@"m4a"] || [ext isEqualToString:@"mp3"] || [ext isEqualToString:@"aac"] || [ext isEqualToString:@"opus"]) return @"waveform";
    if ([ext isEqualToString:@"pdf"]) return @"doc.richtext";
    if ([ext isEqualToString:@"zip"] || [ext isEqualToString:@"rar"]) return @"doc.zipper";
    return @"doc";
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *name = [self entries][indexPath.row];
    NSString *path = [[self currentDirectory] stringByAppendingPathComponent:name];
    BOOL isDir = NO;
    [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDir];

    if (isDir) {
        MVFilesViewController *sub = [MVFilesViewController new];
        sub.rootOverride = path;
        [self.navigationController pushViewController:sub animated:YES];
        return;
    }

    NSString *ext = path.pathExtension.lowercaseString;
    if ([@[@"mp4", @"mov", @"m4v", @"mp3", @"m4a", @"aac", @"wav", @"webm", @"mkv"] containsObject:ext]) {
        [self playPathInQueue:path];
    } else {
        UIActivityViewController *share = [[UIActivityViewController alloc]
            initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
        [self presentViewController:share animated:YES completion:nil];
    }
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *name = [self entries][indexPath.row];
    NSString *path = [[self currentDirectory] stringByAppendingPathComponent:name];
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                     title:[MVLang t:@"Delete"]
                                                                   handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:[MVLang t:@"Delete this file?"]
                                                                      message:[MVLang t:@"This cannot be undone."]
                                                               preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Delete"] style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a2) {
            [NSFileManager.defaultManager removeItemAtPath:path error:nil];
            [self forgetRecordAtPath:path];
            [self refresh];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
        done(YES);
    }];
    del.backgroundColor = [MVTheme danger];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
}

/// Keeps the Downloads list honest when a file is deleted from the Files tab.
- (void)forgetRecordAtPath:(NSString *)path {
    for (MVDownloadRecord *r in MVDownloadStore.shared.records) {
        if ([r.path isEqualToString:path]) [MVDownloadStore.shared remove:r];
    }
}

- (void)createFolder {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[MVLang t:@"New folder"]
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.placeholder = [MVLang t:@"Folder name"];
        f.semanticContentAttribute = MVLang.shared.isRTL ? UISemanticContentAttributeForceRightToLeft : UISemanticContentAttributeForceLeftToRight;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Create"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *name = alert.textFields.firstObject.text;
        if (!name.length) return;
        NSString *path = [[self currentDirectory] stringByAppendingPathComponent:name];
        [NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
        [self refresh];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)longPressRow:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    CGPoint point = [gesture locationInView:self.tableView];
    NSIndexPath *indexPath = [self.tableView indexPathForRowAtPoint:point];
    if (!indexPath) return;
    NSString *name = [self entries][indexPath.row];
    NSString *path = [[self currentDirectory] stringByAppendingPathComponent:name];
    [self showFileMenuForPath:path];
}

- (void)showFileMenuForPath:(NSString *)path {
    NSString *name = path.lastPathComponent;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:name
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    BOOL isDir = NO;
    [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDir];
    NSString *ext = path.pathExtension.lowercaseString;
    BOOL playable = [@[@"mp4", @"mov", @"m4v", @"mp3", @"m4a", @"aac", @"wav", @"webm", @"mkv"] containsObject:ext];

    if (!isDir && playable) {
        [sheet addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Play"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [self playPathInQueue:path];
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Save to Photos"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [[MVDownloadEngine shared] saveToPhotos:path completion:^(NSString *fp, NSString *err) {
                if (fp && !err) {
                    [self alert:@"MoodyVid" message:[MVLang t:@"Saved to Photos"]];
                } else if (err) {
                    [self alert:[MVLang t:@"Failed"] message:err];
                }
            }];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Share"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        UIActivityViewController *share = [[UIActivityViewController alloc]
            initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
        [self presentViewController:share animated:YES completion:nil];
    }]];
    if (!isDir) {
        [sheet addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Rename"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [self promptRenamePath:path];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Delete"] style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [self confirmDeletePath:path];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)confirmDeletePath:(NSString *)path {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[MVLang t:@"Delete this file?"]
                                                                  message:[MVLang t:@"This cannot be undone."]
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Delete"] style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        [self forgetRecordAtPath:path];
        [self refresh];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)promptRenamePath:(NSString *)path {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[MVLang t:@"Rename"]
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.text = path.lastPathComponent.stringByDeletingPathExtension;
        f.semanticContentAttribute = MVLang.shared.isRTL ? UISemanticContentAttributeForceRightToLeft : UISemanticContentAttributeForceLeftToRight;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Rename"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *name = alert.textFields.firstObject.text;
        if (!name.length) return;
        NSString *target = [[path stringByDeletingLastPathComponent]
                            stringByAppendingPathComponent:[name stringByAppendingPathExtension:path.pathExtension]];
        NSError *err = nil;
        if ([NSFileManager.defaultManager moveItemAtPath:path toPath:target error:&err]) {
            for (MVDownloadRecord *r in MVDownloadStore.shared.records) {
                if ([r.path isEqualToString:path]) {
                    r.path = target;
                    [MVDownloadStore.shared update:r];
                }
            }
            [self refresh];
        } else {
            [self alert:[MVLang t:@"Failed"] message:err.localizedDescription ?: [MVLang t:@"Unknown error"]];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSString *)thumbnailForPath:(NSString *)path {
    for (MVDownloadRecord *r in MVDownloadStore.shared.records) {
        if (r.thumbnail.length && [r.path isEqualToString:path] &&
            [NSFileManager.defaultManager fileExistsAtPath:r.thumbnail]) {
            return r.thumbnail;
        }
    }
    return nil;
}

- (void)alert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showSortMenu {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:[MVLang t:@"Sort by"]
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray<NSArray *> *options = @[@[@"Name", @(MVSortModeName)], @[@"Date", @(MVSortModeDate)], @[@"Size", @(MVSortModeSize)]];
    for (NSArray *option in options) {
        MVSortMode mode = (MVSortMode)[option[1] integerValue];
        [sheet addAction:[UIAlertAction actionWithTitle:[MVLang t:option[0]] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            self.sortMode = mode;
            [self refresh];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.lastObject;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)playPathInQueue:(NSString *)path {
    // The previous/next buttons in the player step through the visible rows of
    // this folder, ignoring subfolders and non-video files.
    NSArray<NSString *> *names = [self entries];
    NSString *dir = [self currentDirectory];
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    NSInteger index = 0;
    for (NSUInteger i = 0; i < names.count; i++) {
        NSString *p = [dir stringByAppendingPathComponent:names[i]];
        NSString *ext = p.pathExtension.lowercaseString;
        if (![@[@"mp4", @"mov", @"m4v", @"mp3", @"m4a", @"aac", @"wav", @"webm", @"mkv"] containsObject:ext]) continue;
        [urls addObject:[NSURL fileURLWithPath:p]];
        [titles addObject:p.lastPathComponent.stringByDeletingPathExtension];
        if ([p isEqualToString:path]) index = (NSInteger)urls.count - 1;
    }
    if (!urls.count) return;
    [[MVPlayerCenter shared] playQueue:urls titles:titles fromIndex:index];
    // Play inside the tab in the card instead of taking over the whole screen.
    [self openInlinePlayer];
}

@end
