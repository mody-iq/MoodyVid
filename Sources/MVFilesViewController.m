#import "MVFilesViewController.h"
#import <AVKit/AVKit.h>
#import <AVFoundation/AVFoundation.h>
#import "MVPlayerCenter.h"
#import "MVPaths.h"
#import "MVLang.h"
#import "MVTheme.h"
#import "MVDownloadStore.h"
#import "MVDownloadEngine.h"
#import "MVMediaConverter.h"
#import "MVFileCardCell.h"
#import "MVEmptyStateView.h"

typedef NS_ENUM(NSInteger, MVSortMode) {
    MVSortModeName = 0,
    MVSortModeDate = 1,
    MVSortModeSize = 2,
};

/// The kind buttons at the top of the Files tab. All browses folders; the other
/// three narrow the list to files of that kind, by extension.
typedef NS_ENUM(NSInteger, MVFileKind) {
    MVFileKindAll = 0,
    MVFileKindVideo = 1,
    MVFileKindAudio = 2,
    MVFileKindOther = 3,
};

static BOOL MVExtensionIsVideo(NSString *ext) {
    static NSSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSSet setWithArray:@[@"mp4", @"m4v", @"mov", @"mkv", @"webm", @"avi", @"flv",
                                    @"3gp", @"ts", @"m2ts", @"mpg", @"mpeg", @"wmv", @"ogv"]];
    });
    return [set containsObject:ext];
}

static BOOL MVExtensionIsAudio(NSString *ext) {
    static NSSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSSet setWithArray:@[@"mp3", @"m4a", @"aac", @"ogg", @"opus", @"flac", @"wav",
                                    @"aiff", @"wma", @"mka", @"amr"]];
    });
    return [set containsObject:ext];
}

/// The player surface's backing layer IS the AVPlayerLayer, so Auto Layout keeps
/// the picture exactly the size of the view through every rotation. Framing a
/// manual sublayer instead left it stale: the frame was set from bounds that had
/// not been resized yet, so after a turn the video sat small in a corner, and
/// turning back left it zoomed.
@interface MVVideoSurfaceView : UIView
/// The view's backing layer, typed so callers can set videoGravity/player.
@property (nonatomic, readonly) AVPlayerLayer *playerLayer;
@end

@implementation MVVideoSurfaceView
+ (Class)layerClass { return AVPlayerLayer.class; }
- (AVPlayerLayer *)playerLayer { return (AVPlayerLayer *)self.layer; }
@end

@interface MVFilesViewController () <UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) MVEmptyStateView *emptyState;
@property (nonatomic, strong) UIView *storageCard;
@property (nonatomic, strong) UILabel *storageLabel;
@property (nonatomic, strong) UILabel *storageDetailLabel;
@property (nonatomic, strong) UIProgressView *storageBar;
@property (nonatomic, strong) UIView *headerView;
@property (nonatomic, strong) UISearchController *search;
@property (nonatomic, copy) NSString *filter;
@property (nonatomic) MVSortMode sortMode;

/// Which kind of file the list is narrowed to. Video/Audio/Other filter by
/// extension wherever the file lives, so a video is found even if it sits in a
/// folder the user made; All shows folders too, for browsing.
@property (nonatomic) MVFileKind filterKind;
@property (nonatomic, strong) UISegmentedControl *kindControl;
/// A path to highlight once the view is on screen, set by -revealPath: when the
/// file lives in a folder that has to be pushed first.
@property (nonatomic, copy) NSString *revealTarget;
/// The rows for the current kind/filter, rebuilt only when that pair changes.
/// Without it a kind filter would walk the whole tree once per visible row.
@property (nonatomic, copy) NSArray<NSString *> *rowCache;
@property (nonatomic, copy) NSString *rowCacheKey;

// Inline player: videos play here, inside the tab page, instead of a black
// full-screen modal. It carries the same transport as the floating mini bar
// (previous / 15s back / play-pause / 15s forward / next) plus a scrubber.
@property (nonatomic, strong) UIView *playerCard;
@property (nonatomic, strong) MVVideoSurfaceView *videoSurface;
@property (nonatomic, strong) UILabel *nowTitleLabel;
@property (nonatomic, strong) UIButton *prevButton;
@property (nonatomic, strong) UIButton *backButton;
@property (nonatomic, strong) UIButton *playPauseButton;
@property (nonatomic, strong) UIButton *forwardButton;
@property (nonatomic, strong) UIButton *nextButton;
@property (nonatomic, strong) UIButton *cardCloseButton;
@property (nonatomic, strong) UIButton *expandButton;
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

    [self buildStorageCard];

    // A plain list, full-bleed under the translucent chrome, so it scrolls and
    // feels like the rest of the system rather than a floating inset panel.
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.backgroundColor = UIColor.clearColor;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 78;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.tableFooterView = [UIView new];
    [self.tableView registerClass:MVFileCardCell.class forCellReuseIdentifier:@"MVFileCardCell"];
    [self.view addSubview:self.tableView];

    // Must be added after the table exists, or the gesture is attached to nil.
    UILongPressGestureRecognizer *longPress =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPressRow:)];
    [self.tableView addGestureRecognizer:longPress];

    self.emptyState = [[MVEmptyStateView alloc] initWithFrame:CGRectZero];
    self.emptyState.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyState.hidden = YES;
    self.emptyState.symbolName = @"folder";
    self.emptyState.title = [MVLang t:@"No files"];
    self.emptyState.message = [MVLang t:@"Downloads land here, and you can add your own folders."];
    [self.view addSubview:self.emptyState];

    self.search = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.search.searchResultsUpdater = self;
    self.search.obscuresBackgroundDuringPresentation = NO;
    self.navigationItem.searchController = self.search;
    self.navigationItem.hidesSearchBarWhenScrolling = YES;
    self.definesPresentationContext = YES;

    [self buildPlayerCard];

    // The player and the storage card live in the table's header, so the video
    // is part of the page and scrolls with it, rather than floating over it.
    self.cardHeight = [self.playerCard.heightAnchor constraintEqualToConstant:0];
    self.headerView = [UIView new];
    [self buildKindBar];
    [self.headerView addSubview:self.kindControl];
    [self.headerView addSubview:self.storageCard];
    [self.headerView addSubview:self.playerCard];
    self.tableView.tableHeaderView = self.headerView;

    [NSLayoutConstraint activateConstraints:@[
        [self.kindControl.topAnchor constraintEqualToAnchor:self.headerView.topAnchor constant:6],
        [self.kindControl.leadingAnchor constraintEqualToAnchor:self.headerView.leadingAnchor constant:[MVTheme screenPadding]],
        [self.kindControl.trailingAnchor constraintEqualToAnchor:self.headerView.trailingAnchor constant:-[MVTheme screenPadding]],

        [self.storageCard.topAnchor constraintEqualToAnchor:self.kindControl.bottomAnchor constant:12],
        [self.storageCard.leadingAnchor constraintEqualToAnchor:self.headerView.leadingAnchor constant:[MVTheme screenPadding]],
        [self.storageCard.trailingAnchor constraintEqualToAnchor:self.headerView.trailingAnchor constant:-[MVTheme screenPadding]],

        [self.playerCard.topAnchor constraintEqualToAnchor:self.storageCard.bottomAnchor constant:10],
        [self.playerCard.leadingAnchor constraintEqualToAnchor:self.headerView.leadingAnchor constant:16],
        [self.playerCard.trailingAnchor constraintEqualToAnchor:self.headerView.trailingAnchor constant:-16],
        [self.playerCard.bottomAnchor constraintEqualToAnchor:self.headerView.bottomAnchor constant:-8],
        self.cardHeight,

        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [self.emptyState.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.emptyState.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-30],
        [self.emptyState.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [self.emptyState.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],
    ]];
    self.cardHeight.constant = 0;
    self.playerCard.hidden = YES;
    [self sizeHeaderToFit];

    for (NSString *name in @[MVDownloadStoreDidChangeNotification, MVLangDidChangeNotification, MVThemeDidChangeNotification]) {
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:name object:nil];
    }
    // Closing the mini bar stops playback; the inline card must not stay open
    // showing a stopped video, or it would come back on the next visit.
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(playerDidStop)
                                               name:MVPlayerDidStopNotification object:nil];
    [self refresh];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refresh];
    if (self.revealTarget.length) {
        // Consume it once: coming back to this screen later must not re-scroll.
        NSString *target = self.revealTarget;
        self.revealTarget = nil;
        dispatch_async(dispatch_get_main_queue(), ^{ [self revealPath:target]; });
    }
    if (self.cardOpen) {
        [self cardStateChanged];
        // The card is back on screen and is the control again.
        [MVPlayerCenter shared].inlinePlayerActive = YES;
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

/// A small card under the chrome that reports free space, so the Files screen
/// answers "how much room is left" without a trip to Settings.
- (void)buildStorageCard {
    self.storageCard = [UIView new];
    self.storageCard.translatesAutoresizingMaskIntoConstraints = NO;
    [MVTheme applyCardStyle:self.storageCard cornerRadius:[MVTheme cardCornerRadius]];

    self.storageLabel = [UILabel new];
    self.storageLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.storageLabel.font = [MVTheme cardTitleFont];
    self.storageLabel.textColor = [MVTheme text];
    self.storageLabel.adjustsFontForContentSizeCategory = YES;
    [self.storageCard addSubview:self.storageLabel];

    self.storageDetailLabel = [UILabel new];
    self.storageDetailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.storageDetailLabel.font = [MVTheme cardDetailFont];
    self.storageDetailLabel.textColor = [MVTheme secondaryText];
    self.storageDetailLabel.adjustsFontForContentSizeCategory = YES;
    [self.storageCard addSubview:self.storageDetailLabel];

    self.storageBar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.storageBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.storageBar.progressTintColor = [MVTheme accent];
    self.storageBar.trackTintColor = [[MVTheme secondaryText] colorWithAlphaComponent:0.22];
    [self.storageCard addSubview:self.storageBar];

    CGFloat pad = 14.0;
    [NSLayoutConstraint activateConstraints:@[
        [self.storageLabel.topAnchor constraintEqualToAnchor:self.storageCard.topAnchor constant:pad],
        [self.storageLabel.leadingAnchor constraintEqualToAnchor:self.storageCard.leadingAnchor constant:pad],
        [self.storageLabel.trailingAnchor constraintEqualToAnchor:self.storageCard.trailingAnchor constant:-pad],

        [self.storageDetailLabel.topAnchor constraintEqualToAnchor:self.storageLabel.bottomAnchor constant:2],
        [self.storageDetailLabel.leadingAnchor constraintEqualToAnchor:self.storageCard.leadingAnchor constant:pad],
        [self.storageDetailLabel.trailingAnchor constraintEqualToAnchor:self.storageCard.trailingAnchor constant:-pad],

        [self.storageBar.topAnchor constraintEqualToAnchor:self.storageDetailLabel.bottomAnchor constant:8],
        [self.storageBar.leadingAnchor constraintEqualToAnchor:self.storageCard.leadingAnchor constant:pad],
        [self.storageBar.trailingAnchor constraintEqualToAnchor:self.storageCard.trailingAnchor constant:-pad],
        [self.storageBar.bottomAnchor constraintEqualToAnchor:self.storageCard.bottomAnchor constant:-pad],
    ]];
}

/// The four kind buttons. A segmented control, so it looks and behaves like the
/// system's own and needs no styling code of its own.
- (void)buildKindBar {
    UISegmentedControl *control = [[UISegmentedControl alloc] initWithItems:@[
        [MVLang t:@"All"], [MVLang t:@"Video"], [MVLang t:@"Audio"], [MVLang t:@"Other"]
    ]];
    control.selectedSegmentIndex = self.filterKind;
    control.translatesAutoresizingMaskIntoConstraints = NO;
    control.apportionsSegmentWidthsByContent = YES;
    [control addTarget:self action:@selector(kindChanged:) forControlEvents:UIControlEventValueChanged];
    self.kindControl = control;
}

- (void)kindChanged:(UISegmentedControl *)control {
    self.filterKind = (MVFileKind)control.selectedSegmentIndex;
    // A kind filter lists files from across the tree, so the folder the user was
    // browsing no longer applies; drop back to the root for a predictable list.
    // The root is a different instance, so it has to be told the choice.
    if (self.filterKind != MVFileKindAll && self.rootOverride) {
        MVFilesViewController *root = self.navigationController.viewControllers.firstObject;
        if ([root isKindOfClass:MVFilesViewController.class]) root.filterKind = self.filterKind;
        [self.navigationController popToRootViewControllerAnimated:YES];
        return;
    }
    [self refresh];
}

- (void)refresh {
    self.title = [MVLang t:@"Files"];
    // Files land on disk behind the app's back, so a refresh always drops the
    // memoised row list rather than trusting the kind/filter key alone.
    self.rowCache = nil;
    self.rowCacheKey = nil;
    self.search.searchBar.placeholder = [MVLang t:@"Search files"];
    self.emptyState.title = [MVLang t:@"No files"];
    self.emptyState.message = [MVLang t:@"Downloads land here, and you can add your own folders."];
    self.kindControl.selectedSegmentIndex = self.filterKind;
    // Sorting and folder creation only apply to the browsable list; in a kind
    // filter they would be dead buttons, so they step aside.
    BOOL browsing = self.filterKind == MVFileKindAll;
    for (UIBarButtonItem *item in self.navigationItem.rightBarButtonItems) {
        item.enabled = browsing;
    }
    [self updateStorageCard];
    self.emptyState.hidden = [self visibleEntries].count > 0;
    [MVTheme applyWallpaperTo:self.view];
    [self.tableView reloadData];
    [self sizeHeaderToFit];
}

- (void)updateStorageCard {
    long long free = [MVPaths freeSpace];
    long long total = [MVPaths totalSpace];
    long long used = MAX(0, total - free);
    self.storageLabel.text = [NSString stringWithFormat:@"%@ %@",
                              [MVPaths formatBytes:free], [MVLang t:@"available"]];
    self.storageDetailLabel.text = [NSString stringWithFormat:@"%@ %@ · %@ %@",
                                    [MVPaths formatBytes:used], [MVLang t:@"used"],
                                    [MVPaths formatBytes:total], [MVLang t:@"total"]];
    self.storageBar.progress = total > 0 ? (float)((double)used / (double)total) : 0.0f;
    [self.emptyState refresh];
}

#pragma mark - Inline player card

- (void)buildPlayerCard {
    self.playerCard = [UIView new];
    self.playerCard.translatesAutoresizingMaskIntoConstraints = NO;
    self.playerCard.clipsToBounds = YES;
    [MVTheme applyCardStyle:self.playerCard cornerRadius:20];

    self.videoSurface = [MVVideoSurfaceView new];
    self.videoSurface.translatesAutoresizingMaskIntoConstraints = NO;
    self.videoSurface.backgroundColor = [[MVTheme background] colorWithAlphaComponent:0.25];
    self.videoSurface.layer.masksToBounds = YES;
    self.videoSurface.layer.cornerRadius = 14;
    self.videoSurface.layer.borderWidth = 0.5;
    self.videoSurface.layer.borderColor = [[MVTheme cardBorder] colorWithAlphaComponent:0.3].CGColor;
    self.videoSurface.playerLayer.videoGravity = AVLayerVideoGravityResizeAspect;
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

    // Opens the same playback full screen, where the controls can hide and the
    // picture is much bigger than this inline card allows.
    self.expandButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.expandButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.expandButton setImage:[UIImage systemImageNamed:@"arrow.up.left.and.arrow.down.right"] forState:UIControlStateNormal];
    self.expandButton.tintColor = [MVTheme text];
    self.expandButton.backgroundColor = [[MVTheme background] colorWithAlphaComponent:0.35];
    self.expandButton.layer.cornerRadius = 15;
    self.expandButton.clipsToBounds = YES;
    [self.expandButton addTarget:self action:@selector(expandInlinePlayer) forControlEvents:UIControlEventTouchUpInside];
    [self.playerCard addSubview:self.expandButton];

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

        [self.expandButton.centerYAnchor constraintEqualToAnchor:self.cardCloseButton.centerYAnchor],
        [self.expandButton.trailingAnchor constraintEqualToAnchor:self.cardCloseButton.leadingAnchor constant:-8],
        [self.expandButton.widthAnchor constraintEqualToConstant:30],
        [self.expandButton.heightAnchor constraintEqualToConstant:30],

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

    // The surface's own layer is the AVPlayerLayer, so Auto Layout sizes the
    // picture — no manual frame to go stale on rotation.
    self.videoSurface.playerLayer.player = center.player;
    [self.videoSurface setNeedsLayout];

    // Height derived from the card's real width so there is no empty band
    // under the transport on very wide phones.
    [self updateCardHeight];
    [self.headerView layoutIfNeeded];
    [self sizeHeaderToFit];
    [self.videoSurface layoutIfNeeded];
    [self cardStateChanged];
    center.inlinePlayerActive = YES;

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

- (void)playerDidStop {
    if (!self.cardOpen) return;
    [self closeInlinePlayer];
}

- (void)closeInlinePlayer {
    self.cardOpen = NO;
    self.cardHeight.constant = 0;
    [self.cardTicker invalidate];
    self.videoSurface.playerLayer.player = nil;
    [self.headerView layoutIfNeeded];
    [self sizeHeaderToFit];
    self.playerCard.hidden = YES;
    // Hand control back to the floating mini bar (playback itself continues).
    [MVPlayerCenter shared].inlinePlayerActive = NO;
}

/// Moves the inline playback to the full-screen player, where the picture is
/// larger and the controls can be hidden. The card stays open underneath, so
/// dismissing the full player returns to the same inline view.
- (void)expandInlinePlayer {
    [[MVPlayerCenter shared] presentCurrentPlayer];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    // Presenting the full-screen player also runs this, but the card stays behind
    // it and is still the control, so keep the flag set in that case. Otherwise
    // (another tab or folder) hand back to the mini bar, which the player center
    // suppresses while the full-screen player is up.
    if (!MVPlayerCenter.shared.fullPlayerVisible) {
        [MVPlayerCenter shared].inlinePlayerActive = NO;
    }
}

/// Recomputes the card height from the current width. Called on open and again
/// whenever the view resizes, because rotation changes the width and a stale
/// 9:16 height would leave a gap (or clip the transport) after the turn.
- (void)updateCardHeight {
    if (!self.cardOpen) return;
    CGFloat contentW = self.headerView.bounds.size.width - 32.0;
    if (contentW <= 0) contentW = self.view.bounds.size.width - 32.0;
    if (contentW <= 0) contentW = 320.0;
    self.cardHeight.constant = contentW * 9.0 / 16.0 + 148.0;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    for (CALayer *layer in [self.view.layer.sublayers copy]) {
        if ([layer.name isEqualToString:@"MVWallpaperLayer"]) layer.frame = self.view.bounds;
    }

    // A rotation changes the width: resize the card and re-fit the header so the
    // video keeps its 16:9 shape and the transport stays attached to it.
    if (self.cardOpen) {
        CGFloat before = self.cardHeight.constant;
        [self updateCardHeight];
        if (fabs(before - self.cardHeight.constant) > 0.5) {
            [self.headerView layoutIfNeeded];
            [self sizeHeaderToFit];
        }
    }
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
    NSArray *entries = [self visibleEntries];
    self.emptyState.hidden = entries.count > 0;
    return entries.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    MVFileCardCell *cell = [tableView dequeueReusableCellWithIdentifier:@"MVFileCardCell" forIndexPath:indexPath];
    NSArray<NSString *> *entries = [self visibleEntries];
    NSString *path = entries[indexPath.row];
    NSString *name = path.lastPathComponent;
    BOOL isDir = NO;
    [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDir];

    NSString *detail;
    NSString *symbol;
    UIImage *thumbnail = nil;
    if (isDir) {
        detail = [self summaryForFolderAtPath:path];
        symbol = @"folder.fill";
    } else {
        NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
        long long size = [attrs[NSFileSize] longLongValue];
        NSDate *date = attrs[NSFileModificationDate];
        NSString *ext = path.pathExtension.lowercaseString;
        NSString *thumbPath = [self thumbnailForPath:path];
        if (thumbPath) thumbnail = [UIImage imageWithContentsOfFile:thumbPath];
        symbol = [MVFileCardCell symbolForExtension:ext];
        // A kind filter lists files from anywhere in the tree, so the parent
        // folder is the only clue to where the file actually lives.
        NSString *place = self.filterKind == MVFileKindAll
            ? [NSDateFormatter localizedStringFromDate:date dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterShortStyle]
            : [path.stringByDeletingLastPathComponent.lastPathComponent stringByAppendingFormat:@"  \u00b7  %@",
               [NSDateFormatter localizedStringFromDate:date dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterShortStyle]];
        detail = [NSString stringWithFormat:@"%@  \u00b7  %@", [MVPaths formatBytes:size], place];
    }

    [cell configureWithName:name detail:detail symbolName:symbol thumbnail:thumbnail isFolder:isDir];
    __weak typeof(self) weakSelf = self;
    cell.onAction = ^{
        if (isDir) [weakSelf openFolderAtPath:path];
        else [weakSelf showFileMenuForPath:path];
    };
    return cell;
}

- (void)openFolderAtPath:(NSString *)path {
    MVFilesViewController *sub = [MVFilesViewController new];
    sub.rootOverride = path;
    [self.navigationController pushViewController:sub animated:YES];
}

#pragma mark - Reveal

- (void)revealPath:(NSString *)path {
    if (!path.length) return;
    // Not on screen yet (never shown, or being pushed by a tab switch): keep the
    // request for viewWillAppear, where the table is laid out and can scroll.
    if (!self.isViewLoaded || self.view.window == nil) { self.revealTarget = path; return; }

    // Normalise once: the stored download path and the browsed path are built
    // independently, so a stray trailing slash must not defeat the comparison.
    path = path.stringByStandardizingPath;
    NSString *root = [MVPaths downloads].stringByStandardizingPath;
    NSString *parent = path.stringByDeletingLastPathComponent;
    BOOL isRoot = [parent isEqualToString:root];

    // The row must be on screen for a scroll to mean anything, so a file in a
    // subfolder is revealed by opening that folder and letting its own -refresh
    // highlight the row.
    if (!isRoot && ![self.currentDirectory isEqualToString:parent]) {
        MVFilesViewController *sub = [MVFilesViewController new];
        sub.rootOverride = parent;
        sub.revealTarget = path;
        [self.navigationController pushViewController:sub animated:YES];
        return;
    }

    // A kind filter can hide the very file being revealed, so fall back to All.
    NSArray<NSString *> *visible = [self visibleEntries];
    if (self.filterKind != MVFileKindAll && ![visible containsObject:path]) {
        self.filterKind = MVFileKindAll;
        [self refresh];
        visible = [self visibleEntries];
    }
    NSInteger index = [visible indexOfObject:path];
    if (index == NSNotFound) return;
    NSIndexPath *ip = [NSIndexPath indexPathForRow:index inSection:0];
    [self.tableView scrollToRowAtIndexPath:ip atScrollPosition:UITableViewScrollPositionMiddle animated:YES];
    // The row is only dequeued once it is on screen, and scrolling is animated,
    // so wait for the layout pass before reaching for the cell to flash.
    dispatch_async(dispatch_get_main_queue(), ^{ [self flashRowAtIndexPath:ip]; });
}

- (void)flashRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
    if ([cell isKindOfClass:MVFileCardCell.class]) [(MVFileCardCell *)cell flashHighlight];
}

/// Walks the tree under `root` and returns the path of every file whose kind
/// matches the current filter. Filtering by extension (not by folder) means a
/// video is found wherever it sits, including folders the user created. Hidden
/// files and the download index are skipped, and folders are never returned.
- (NSArray<NSString *> *)pathsMatchingKind:(MVFileKind)kind underPath:(NSString *)root {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSDirectoryEnumerator *walk = [fm enumeratorAtURL:[NSURL fileURLWithPath:root]
                           includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                                              options:NSDirectoryEnumerationSkipsHiddenFiles
                                         errorHandler:nil];
    for (NSURL *url in walk) {
        NSNumber *isDir = nil;
        if (![url getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil] || isDir.boolValue) continue;
        NSString *name = url.lastPathComponent;
        if ([name isEqualToString:@"downloads.json"]) continue;
        if (self.filter.length && ![name localizedCaseInsensitiveContainsString:self.filter]) continue;
        NSString *ext = url.pathExtension.lowercaseString;
        BOOL match = kind == MVFileKindOther ? (!MVExtensionIsVideo(ext) && !MVExtensionIsAudio(ext))
                                             : (kind == MVFileKindVideo ? MVExtensionIsVideo(ext)
                                                                        : MVExtensionIsAudio(ext));
        if (match) [out addObject:url.path];
    }
    return [out sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [a.lastPathComponent localizedStandardCompare:b.lastPathComponent];
    }];
}

/// The rows to show, as absolute paths. Kind filters work on the whole tree, so
/// they ignore `rootOverride` and always describe the library as a whole. The
/// result is memoised against the kind/filter/folder triple, because the table
/// asks for it once per row and a kind filter walks the whole tree.
- (NSArray<NSString *> *)visibleEntries {
    NSString *key = [NSString stringWithFormat:@"%ld|%@|%@", (long)self.filterKind,
                     self.filter ?: @"", [self currentDirectory]];
    if (self.rowCache && [self.rowCacheKey isEqualToString:key]) return self.rowCache;

    NSArray<NSString *> *rows;
    if (self.filterKind != MVFileKindAll) {
        rows = [self pathsMatchingKind:self.filterKind underPath:[MVPaths downloads]];
    } else {
        NSString *dir = [self currentDirectory];
        NSMutableArray<NSString *> *paths = [NSMutableArray array];
        for (NSString *name in [self entries]) {
            [paths addObject:[dir stringByAppendingPathComponent:name]];
        }
        rows = paths;
    }
    self.rowCache = rows;
    self.rowCacheKey = key;
    return rows;
}

/// A one-line summary of what a folder holds, so a folder row never claims to
/// be empty when its files are simply nested. Counts the visible files
/// (recursively) and sums their sizes.
- (NSString *)summaryForFolderAtPath:(NSString *)path {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:path error:nil] ?: @[];
    if (!names.count) return [MVLang t:@"Empty folder"];

    NSUInteger files = 0;
    long long bytes = 0;
    NSURL *base = [NSURL fileURLWithPath:path];
    NSDirectoryEnumerator *walk = [fm enumeratorAtURL:base
                           includingPropertiesForKeys:@[NSURLFileSizeKey, NSURLIsDirectoryKey]
                                              options:NSDirectoryEnumerationSkipsHiddenFiles
                                         errorHandler:nil];
    for (NSURL *url in walk) {
        NSNumber *isDir = nil;
        if (![url getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil] || isDir.boolValue) continue;
        files++;
        NSNumber *size = nil;
        if ([url getResourceValue:&size forKey:NSURLFileSizeKey error:nil]) bytes += size.longLongValue;
    }
    if (files == 0) return [MVLang t:@"Empty folder"];

    NSString *count = files == 1 ? [MVLang t:@"1 file"]
                                 : [NSString stringWithFormat:@"%lu %@", (unsigned long)files, [MVLang t:@"files"]];
    return [NSString stringWithFormat:@"%@  ·  %@", count, [MVPaths formatBytes:bytes]];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *path = [self visibleEntries][indexPath.row];
    NSString *name = path.lastPathComponent;
    BOOL isDir = NO;
    [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDir];

    if (isDir) {
        [self openFolderAtPath:path];
        return;
    }

    NSString *ext = path.pathExtension.lowercaseString;
    if ([@[@"mp4", @"mov", @"m4v", @"mp3", @"m4a", @"aac", @"wav"] containsObject:ext]) {
        [self playPathInQueue:path];
    } else if ([@[@"webm", @"mkv"] containsObject:ext]) {
        [self offerConversionForPath:path];
    } else {
        UIActivityViewController *share = [[UIActivityViewController alloc]
            initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
        [self presentViewController:share animated:YES completion:nil];
    }
}

/// iOS cannot decode VP9/AV1/Opus, so a WebM or MKV is offered as a conversion
/// instead of a dead end. The remux copies the tracks without re-encoding, so
/// it is instant and lossless when the codecs are already compatible; when they
/// are not, the file can still be shared or exported.
- (void)offerConversionForPath:(NSString *)path {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:[MVLang t:@"Convert to playable"]
                         message:[MVLang t:@"This file's format isn't supported. Convert it to MP4 to play it here."]
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Convert"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self convertPathToPlayable:path];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Share"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        UIActivityViewController *share = [[UIActivityViewController alloc]
            initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
        [self presentViewController:share animated:YES completion:nil];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)convertPathToPlayable:(NSString *)path {
    NSString *outPath = [[path stringByDeletingPathExtension] stringByAppendingPathExtension:@"mp4"];
    UIAlertController *busy = [UIAlertController alertControllerWithTitle:[MVLang t:@"Converting…"]
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:busy animated:YES completion:nil];
    [MVMediaConverter remuxToMP4:path to:outPath completion:^(BOOL ok, NSString *error) {
        [busy dismissViewControllerAnimated:YES completion:^{
            if (ok) {
                [self refresh];
                [self playPathInQueue:outPath];
            } else {
                UIAlertController *failed = [UIAlertController
                    alertControllerWithTitle:[MVLang t:@"Can't play this file"]
                                     message:error ?: [MVLang t:@"WebM and MKV aren't supported. You can still share or export it."]
                              preferredStyle:UIAlertControllerStyleAlert];
                [failed addAction:[UIAlertAction actionWithTitle:[MVLang t:@"OK"] style:UIAlertActionStyleCancel handler:nil]];
                [self presentViewController:failed animated:YES completion:nil];
            }
        }];
    }];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *path = [self visibleEntries][indexPath.row];
    NSString *name = path.lastPathComponent;
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
/// YES when the file has an audio track, which is what "Convert to MP3" needs.
/// A video with sound qualifies too, so a downloaded clip can be turned into a
/// track without a separate step.
- (BOOL)pathHasAudioTrack:(NSString *)path {
    AVURLAsset *asset = [AVURLAsset assetWithURL:[NSURL fileURLWithPath:path]];
    return [asset tracksWithMediaType:AVMediaTypeAudio].count > 0;
}

- (void)convertPathToMP3:(NSString *)path {
    NSString *outPath = [[path stringByDeletingPathExtension] stringByAppendingPathExtension:@"mp3"];
    UIAlertController *busy = [UIAlertController alertControllerWithTitle:[MVLang t:@"Converting…"]
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:busy animated:YES completion:nil];
    [MVMediaConverter convertToMP3:path to:outPath completion:^(BOOL ok, NSString *error) {
        [busy dismissViewControllerAnimated:YES completion:^{
            if (ok) {
                [self refresh];
                [self playPathInQueue:outPath];
            } else {
                [self alert:[MVLang t:@"Could not convert this file"] message:error];
            }
        }];
    }];
}

/// Moves a file into one of the category folders. The picker lists every
/// category the app knows, so a download can be filed where the user expects it
/// without leaving the Files tab.
- (void)promptMovePath:(NSString *)path {
    NSMutableArray<NSString *> *destinations = [NSMutableArray array];
    for (NSString *category in [MVPaths categories]) {
        NSString *dir = [MVPaths directoryForCategory:category];
        if ([path isEqualToString:dir]) continue;
        if ([path hasPrefix:[dir stringByAppendingString:@"/"]]) continue;   // already there
        [destinations addObject:category];
    }
    if (!destinations.count) {
        [self alert:[MVLang t:@"Nothing to move to"] message:nil];
        return;
    }
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:[MVLang t:@"Move to folder"]
                                                                   message:path.lastPathComponent
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *category in destinations) {
        [sheet addAction:[UIAlertAction actionWithTitle:category style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [self movePath:path toCategory:category];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2,
                                                                self.view.bounds.size.height / 2, 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)movePath:(NSString *)path toCategory:(NSString *)category {
    NSString *dir = [MVPaths directoryForCategory:category];
    NSString *dest = [MVPaths uniquePathInDirectory:dir filename:path.lastPathComponent];
    NSError *error = nil;
    if (![NSFileManager.defaultManager moveItemAtPath:path toPath:dest error:&error]) {
        [self alert:[MVLang t:@"Could not move the file"] message:error.localizedDescription];
        return;
    }
    // A download's record points at the old path; follow the file so the
    // Downloads tab does not show a row for a file that is no longer there.
    for (MVDownloadRecord *r in MVDownloadStore.shared.records) {
        if ([r.path isEqualToString:path]) {
            r.path = dest;
            [MVDownloadStore.shared update:r];
        }
    }
    [self refresh];
}

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
    NSString *path = [self visibleEntries][indexPath.row];
    NSString *name = path.lastPathComponent;
    [self showFileMenuForPath:path];
}

/// The modern long-press menu, matching the Downloads list. The table's own
/// recogniser drives this; the extra gesture above is only a fallback for a
/// press that lands between rows.
- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
    contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point {
    NSString *path = [self visibleEntries][indexPath.row];
    NSString *name = path.lastPathComponent;
    BOOL isDir = NO;
    [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDir];
    __weak typeof(self) weakSelf = self;

    return [UIContextMenuConfiguration configurationWithIdentifier:nil
                                                   previewProvider:nil
                                                    actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];
        NSString *ext = path.pathExtension.lowercaseString;
        BOOL playable = [@[@"mp4", @"mov", @"m4v", @"mp3", @"m4a", @"aac", @"wav"] containsObject:ext];
        BOOL needsConvert = [@[@"webm", @"mkv"] containsObject:ext];
        if (isDir) {
            [actions addObject:[UIAction actionWithTitle:[MVLang t:@"Open"] image:[UIImage systemImageNamed:@"folder"]
                                               identifier:nil handler:^(UIAction *a) { [weakSelf openFolderAtPath:path]; }]];
        } else if (playable) {
            [actions addObject:[UIAction actionWithTitle:[MVLang t:@"Play"] image:[UIImage systemImageNamed:@"play.fill"]
                                               identifier:nil handler:^(UIAction *a) { [weakSelf playPathInQueue:path]; }]];
        } else if (needsConvert) {
            [actions addObject:[UIAction actionWithTitle:[MVLang t:@"Convert"] image:[UIImage systemImageNamed:@"arrow.triangle.2.circlepath"]
                                               identifier:nil handler:^(UIAction *a) { [weakSelf offerConversionForPath:path]; }]];
        }
        if (!isDir && [self pathHasAudioTrack:path]) {
            [actions addObject:[UIAction actionWithTitle:[MVLang t:@"Convert to MP3"] image:[UIImage systemImageNamed:@"music.note"]
                                               identifier:nil handler:^(UIAction *a) { [weakSelf convertPathToMP3:path]; }]];
        }
        if (!isDir) {
            [actions addObject:[UIAction actionWithTitle:[MVLang t:@"Save to Photos"] image:[UIImage systemImageNamed:@"photo.on.rectangle"]
                                               identifier:nil handler:^(UIAction *a) {
                [[MVDownloadEngine shared] saveToPhotos:path completion:^(NSString *fp, NSString *err) {
                    if (fp && !err) [weakSelf alert:@"MoodyVid" message:[MVLang t:@"Saved to Photos"]];
                    else if (err) [weakSelf alert:[MVLang t:@"Failed"] message:err];
                }];
            }]];
            [actions addObject:[UIAction actionWithTitle:[MVLang t:@"Move to folder"] image:[UIImage systemImageNamed:@"folder.badge.plus"]
                                               identifier:nil handler:^(UIAction *a) { [weakSelf promptMovePath:path]; }]];
        }
        [actions addObject:[UIAction actionWithTitle:[MVLang t:@"Share"] image:[UIImage systemImageNamed:@"square.and.arrow.up"]
                                           identifier:nil handler:^(UIAction *a) {
            UIActivityViewController *share = [[UIActivityViewController alloc]
                initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
            share.popoverPresentationController.sourceView = weakSelf.view;
            share.popoverPresentationController.sourceRect = CGRectMake(weakSelf.view.bounds.size.width / 2,
                                                                        weakSelf.view.bounds.size.height / 2, 1, 1);
            [weakSelf presentViewController:share animated:YES completion:nil];
        }]];
        if (!isDir) {
            [actions addObject:[UIAction actionWithTitle:[MVLang t:@"Rename"] image:[UIImage systemImageNamed:@"pencil"]
                                               identifier:nil handler:^(UIAction *a) { [weakSelf promptRenamePath:path]; }]];
        }
        UIAction *del = [UIAction actionWithTitle:[MVLang t:@"Delete"] image:[UIImage systemImageNamed:@"trash"]
                                        identifier:nil handler:^(UIAction *a) { [weakSelf confirmDeletePath:path]; }];
        del.attributes = UIMenuElementAttributesDestructive;
        [actions addObject:del];
        return [UIMenu menuWithChildren:actions];
    }];
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
    // this folder, ignoring subfolders and non-video files. WebM/MKV are
    // deliberately left out: AVPlayer cannot decode them, and swapping onto one
    // makes the player hang while it tries to prepare the item.
    static NSSet<NSString *> *playable;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        playable = [NSSet setWithArray:@[@"mp4", @"mov", @"m4v", @"mp3", @"m4a", @"aac", @"wav"]];
    });

    // Step through whatever the list is currently showing: in a kind filter
    // that is files from across the tree, otherwise the rows of this folder.
    NSArray<NSString *> *visible = [self visibleEntries];
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    NSInteger index = 0;
    for (NSUInteger i = 0; i < visible.count; i++) {
        NSString *p = visible[i];
        NSString *ext = p.pathExtension.lowercaseString;
        if (![playable containsObject:ext]) continue;
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
